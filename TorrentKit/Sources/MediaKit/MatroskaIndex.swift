import Foundation

/// Video keyframes of a Matroska/WebM file from its Cues, and the bytes of any one of them, reading only small
/// ranges: the head of the file (EBML header, SeekHead, Info, Tracks), the Cues (often at the end), and per keyframe
/// the start of its cluster plus the block itself.
public struct MatroskaIndex: KeyframeIndex {
    static let maxElementRead: Int64 = 32 * 1024 * 1024
    static let maxFrameSize: Int64 = 16 * 1024 * 1024
    /// Window for scanning a cluster for its first keyframe when the Cues don't say where it is.
    static let scanStep = 64 * 1024
    static let maxScan: Int64 = 8 * 1024 * 1024

    public let video: VideoTrack
    public let trackNumber: Int
    public let duration: Double?
    /// Nanoseconds per timestamp tick.
    public let timestampScale: Double
    public let keyframes: [Keyframe]
    let fileLength: Int64
    let segmentStart: Int64
    let segmentEnd: Int64
    /// Bytes put back in front of every frame (header stripping, ContentCompAlgo 3), in decoding order.
    let stripped: [UInt8]
    let read: ReadBytes

    /// Reads the index. `read` may wait for data (it's called for a few KB at the start, the SeekHead targets and the
    /// Cues). Throws `MediaIndexError`.
    public static func load(fileLength: Int64, read: @escaping ReadBytes) async throws -> MatroskaIndex {
        let r = ByteReader(fileLength: fileLength, read: read)
        guard let ebml = try await r.header(at: 0), ebml.id == MKV.ebml, let ebmlEnd = ebml.end,
              let head = try await r.payload(ebml, limit: 4096) else { throw MediaIndexError.unsupportedContainer }
        let docType = EBML.children(head, in: 0..<head.count).first { $0.id == MKV.docType }.map { EBML.string(head[$0.data]) }
        guard ["matroska", "webm"].contains(docType ?? "matroska") else { throw MediaIndexError.unsupportedContainer }

        var pos = ebmlEnd
        var segment: ElementHeader?
        while pos < fileLength, let h = try await r.header(at: pos) {
            if h.id == MKV.segment { segment = h; break }
            guard let end = h.end else { break }
            pos = end
        }
        guard let seg = segment else { throw MediaIndexError.unsupportedContainer }
        let segStart = seg.dataStart
        let segEnd = min(seg.end ?? fileLength, fileLength)

        var seeks: [UInt32: Int64] = [:]
        var seekHeadsRead = Set<Int64>()
        var infoBytes: [UInt8]?
        var tracksBytes: [UInt8]?
        var cuesOffset: Int64?
        pos = segStart
        // Top-level walk up to the first cluster; stops early once the SeekHead has said where everything is.
        walk: while pos < segEnd, let h = try await r.header(at: pos, window: 4096, limit: segEnd) {
            switch h.id {
            case MKV.seekHead:
                seekHeadsRead.insert(h.offset)
                if let b = try await r.payload(h, limit: maxElementRead) { parseSeekHead(b, segmentStart: segStart, into: &seeks) }
            case MKV.info: infoBytes = try await r.payload(h, limit: maxElementRead)
            case MKV.tracks: tracksBytes = try await r.payload(h, limit: maxElementRead)
            case MKV.cues: cuesOffset = h.offset
            case MKV.cluster: break walk
            default: break
            }
            if infoBytes != nil, tracksBytes != nil, cuesOffset != nil || seeks[MKV.cues] != nil { break }
            guard let end = h.end else { break }
            pos = end
        }
        // A second SeekHead (often written at the end) may hold the Cues entry.
        var pending = seeks[MKV.seekHead].map { [$0] } ?? []
        while cuesOffset == nil, seeks[MKV.cues] == nil || tracksBytes == nil || infoBytes == nil, let p = pending.popLast(),
              !seekHeadsRead.contains(p) {
            seekHeadsRead.insert(p)
            guard let b = try await element(r, at: p, id: MKV.seekHead) else { continue }
            var more: [UInt32: Int64] = [:]
            parseSeekHead(b, segmentStart: segStart, into: &more)
            for (k, v) in more where seeks[k] == nil { seeks[k] = v }
            if let next = more[MKV.seekHead] { pending.append(next) }
        }
        if tracksBytes == nil, let p = seeks[MKV.tracks] { tracksBytes = try await element(r, at: p, id: MKV.tracks) }
        if infoBytes == nil, let p = seeks[MKV.info] { infoBytes = try await element(r, at: p, id: MKV.info) }
        guard let tb = tracksBytes else { throw MediaIndexError.noVideoTrack }

        var scale = 1_000_000.0
        var duration: Double?
        if let b = infoBytes {
            for c in EBML.children(b, in: 0..<b.count) {
                if c.id == MKV.timestampScale {
                    let v = EBML.uint(b[c.data])
                    if v > 0 { scale = Double(v) }
                }
                if c.id == MKV.duration { duration = EBML.float(b[c.data]) }
            }
        }
        duration = duration.map { $0 * scale / 1e9 }.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }

        guard let track = try parseVideoTrack(tb) else { throw MediaIndexError.noVideoTrack }

        guard let cuesAt = cuesOffset ?? seeks[MKV.cues], let ch = try await r.header(at: cuesAt), ch.id == MKV.cues,
              let cb = try await r.payload(ch, limit: maxElementRead) else { throw MediaIndexError.noKeyframeIndex }
        let keyframes = parseCues(cb, track: track.number, scale: scale, segmentStart: segStart)
        guard !keyframes.isEmpty else { throw MediaIndexError.noKeyframeIndex }

        return MatroskaIndex(video: track.video, trackNumber: track.number, duration: duration, timestampScale: scale,
                             keyframes: keyframes, fileLength: fileLength, segmentStart: segStart, segmentEnd: segEnd,
                             stripped: track.stripped, read: read)
    }

    // MARK: index parsing

    private static func element(_ r: ByteReader, at offset: Int64, id: UInt32) async throws -> [UInt8]? {
        guard let h = try await r.header(at: offset), h.id == id else { return nil }
        return try await r.payload(h, limit: maxElementRead)
    }

    static func parseSeekHead(_ b: [UInt8], segmentStart: Int64, into seeks: inout [UInt32: Int64]) {
        for seek in EBML.children(b, in: 0..<b.count) where seek.id == MKV.seek {
            var id: UInt32?
            var position: Int64?
            for c in EBML.children(b, in: seek.data) {
                if c.id == MKV.seekID { id = UInt32(truncatingIfNeeded: EBML.uint(b[c.data])) }
                if c.id == MKV.seekPosition { position = Int64(clamping: EBML.uint(b[c.data])) }
            }
            if let id = id, let p = position, seeks[id] == nil { seeks[id] = segmentStart + p }
        }
    }

    struct ParsedTrack {
        let number: Int
        let video: VideoTrack
        let stripped: [UInt8]
    }

    /// The first enabled video track (the default one if several). Throws `unsupportedEncoding` for encrypted or
    /// compressed frames.
    static func parseVideoTrack(_ b: [UInt8]) throws -> ParsedTrack? {
        var candidates: [(track: ParsedTrack, isDefault: Bool, encodingOK: Bool)] = []
        for entry in EBML.children(b, in: 0..<b.count) where entry.id == MKV.trackEntry {
            var number = 0, type: UInt64 = 0, codecID = "", enabled = true, isDefault = true
            var priv = Data(), width = 0, height = 0
            var encodingOK = true
            var encodings: [(order: UInt64, settings: [UInt8])] = []
            for c in EBML.children(b, in: entry.data) {
                switch c.id {
                case MKV.trackNumber: number = Int(clamping: EBML.uint(b[c.data]))
                case MKV.trackType: type = EBML.uint(b[c.data])
                case MKV.codecID: codecID = EBML.string(b[c.data])
                case MKV.codecPrivate: priv = Data(b[c.data])
                case MKV.flagEnabled: enabled = EBML.uint(b[c.data]) != 0
                case MKV.flagDefault: isDefault = EBML.uint(b[c.data]) != 0
                case MKV.video:
                    for v in EBML.children(b, in: c.data) {
                        if v.id == MKV.pixelWidth { width = Int(clamping: EBML.uint(b[v.data])) }
                        if v.id == MKV.pixelHeight { height = Int(clamping: EBML.uint(b[v.data])) }
                    }
                case MKV.contentEncodings:
                    for enc in EBML.children(b, in: c.data) where enc.id == MKV.contentEncoding {
                        var order: UInt64 = 0, scope: UInt64 = 1, encType: UInt64 = 0, algo: UInt64 = 0
                        var settings: [UInt8] = []
                        for e in EBML.children(b, in: enc.data) {
                            switch e.id {
                            case MKV.contentEncodingOrder: order = EBML.uint(b[e.data])
                            case MKV.contentEncodingScope: scope = EBML.uint(b[e.data])
                            case MKV.contentEncodingType: encType = EBML.uint(b[e.data])
                            case MKV.contentCompression:
                                for cc in EBML.children(b, in: e.data) {
                                    if cc.id == MKV.contentCompAlgo { algo = EBML.uint(b[cc.data]) }
                                    if cc.id == MKV.contentCompSettings { settings = Array(b[cc.data]) }
                                }
                            default: break
                            }
                        }
                        guard scope & 1 != 0 else { continue }
                        if encType != 0 || algo != 3 { encodingOK = false }
                        encodings.append((order, settings))
                    }
                default: break
                }
            }
            guard type == 1, number > 0, enabled else { continue }
            let codec: VideoCodec
            switch codecID {
            case "V_MPEG4/ISO/AVC": codec = .h264
            case "V_MPEGH/ISO/HEVC": codec = .hevc
            case "V_AV1": codec = .av1
            case "V_VP9": codec = .vp9
            default: codec = .other
            }
            // Decoding applies the highest order first, so each prefix lands in front of the previous result.
            let stripped = encodings.sorted { $0.order > $1.order }.reduce([UInt8]()) { $1.settings + $0 }
            let track = ParsedTrack(number: number,
                                    video: VideoTrack(codec: codec, codecID: codecID, configuration: priv, width: width, height: height),
                                    stripped: stripped)
            candidates.append((track, isDefault, encodingOK))
        }
        guard let pick = candidates.first(where: { $0.isDefault }) ?? candidates.first else { return nil }
        guard pick.encodingOK else { throw MediaIndexError.unsupportedEncoding }
        return pick.track
    }

    static func parseCues(_ b: [UInt8], track: Int, scale: Double, segmentStart: Int64) -> [Keyframe] {
        var out: [Keyframe] = []
        for point in EBML.children(b, in: 0..<b.count) where point.id == MKV.cuePoint {
            var time: UInt64?
            var positions: [(cluster: Int64, relative: Int64?)] = []
            for c in EBML.children(b, in: point.data) {
                if c.id == MKV.cueTime { time = EBML.uint(b[c.data]) }
                guard c.id == MKV.cueTrackPositions else { continue }
                var t: Int?, cluster: Int64?, relative: Int64?
                for p in EBML.children(b, in: c.data) {
                    switch p.id {
                    case MKV.cueTrack: t = Int(clamping: EBML.uint(b[p.data]))
                    case MKV.cueClusterPosition: cluster = Int64(clamping: EBML.uint(b[p.data]))
                    case MKV.cueRelativePosition: relative = Int64(clamping: EBML.uint(b[p.data]))
                    default: break
                    }
                }
                if t == track, let cl = cluster { positions.append((segmentStart + cl, relative)) }
            }
            guard let ticks = time, let p = positions.first else { continue }
            out.append(Keyframe(time: Double(ticks) * scale / 1e9, clusterOffset: p.cluster, relativeOffset: p.relative))
        }
        out.sort { $0.time != $1.time ? $0.time < $1.time : $0.clusterOffset < $1.clusterOffset }
        var unique: [Keyframe] = []
        for k in out where unique.last.map({ $0.time != k.time }) ?? true { unique.append(k) }
        return unique
    }

    // MARK: frames

    public func estimatedRange(ofKeyframe index: Int) -> Range<Int64> {
        let k = keyframes[index]
        // Keyframes of typical encodes run 0.5-1 s worth of the average bitrate.
        let rate = duration.map { Double(fileLength) / max($0, 1) } ?? 1_000_000
        let frame = Int64(min(2 * 1024 * 1024, max(128 * 1024, rate * 0.75)))
        var end = k.clusterOffset + 12 + (k.relativeOffset ?? 0) + frame
        if let next = keyframes.dropFirst(index + 1).first(where: { $0.clusterOffset > k.clusterOffset }) {
            end = min(end, next.clusterOffset)
        }
        return k.clusterOffset..<max(k.clusterOffset + 1, min(end, fileLength))
    }

    public func keyframeData(at index: Int, read override: ReadBytes?) async throws -> (time: Double, data: Data) {
        guard keyframes.indices.contains(index) else { throw MediaIndexError.noKeyframeIndex }
        let k = keyframes[index]
        let r = ByteReader(fileLength: fileLength, read: override ?? read)
        // One read covers the cluster header, its timestamp and (usually) the block header.
        let lead = Int(min(Int64(32 * 1024), 64 + (k.relativeOffset ?? 0)))
        guard let cluster = try await r.header(at: k.clusterOffset, window: lead, limit: segmentEnd), cluster.id == MKV.cluster else {
            throw MediaIndexError.malformed("no cluster at \(k.clusterOffset)")
        }
        let clusterEnd = min(cluster.end ?? segmentEnd, segmentEnd)
        if let rel = k.relativeOffset, let block = try await r.header(at: cluster.dataStart + rel, window: 64, limit: clusterEnd),
           let found = try await frame(in: block, r, keyframeOnly: true) {
            let ts = try await clusterTimestamp(cluster, r, limit: clusterEnd)
            return (time(ts, found.relative), Data(found.frame))
        }
        return try await scan(cluster, r, limit: clusterEnd)
    }

    private func time(_ cluster: Int64, _ relative: Int16) -> Double {
        Double(cluster + Int64(relative)) * timestampScale / 1e9
    }

    private func clusterTimestamp(_ cluster: ElementHeader, _ r: ByteReader, limit: Int64) async throws -> Int64 {
        var pos = cluster.dataStart
        for _ in 0..<16 {
            guard pos < limit, let c = try await r.header(at: pos, window: 64, limit: limit) else { break }
            if c.id == MKV.timestamp, let p = try await r.payload(c, limit: 8) { return Int64(clamping: EBML.uint(p[...])) }
            if c.id == MKV.simpleBlock || c.id == MKV.blockGroup { break }
            guard let end = c.end else { break }
            pos = end
        }
        throw MediaIndexError.malformed("cluster at \(cluster.offset) has no timestamp")
    }

    /// Walks the cluster from its start to the first keyframe block of the video track.
    private func scan(_ cluster: ElementHeader, _ r: ByteReader, limit: Int64) async throws -> (time: Double, data: Data) {
        var timestamp: Int64?
        var pos = cluster.dataStart
        let stop = min(limit, cluster.dataStart + Self.maxScan)
        while pos < stop {
            guard let c = try await r.header(at: pos, window: Self.scanStep, limit: stop) else { break }
            if cluster.size == nil, MKV.segmentChildren.contains(c.id) { break }
            switch c.id {
            case MKV.timestamp:
                if let p = try await r.payload(c, limit: 8) { timestamp = Int64(clamping: EBML.uint(p[...])) }
            case MKV.simpleBlock, MKV.blockGroup:
                if let found = try await frame(in: c, r, keyframeOnly: true) {
                    guard let ts = timestamp else { throw MediaIndexError.malformed("block before cluster timestamp") }
                    return (time(ts, found.relative), Data(found.frame))
                }
            default: break
            }
            guard let end = c.end, end > pos else { break }
            pos = end
        }
        throw MediaIndexError.malformed("no video keyframe in cluster at \(cluster.offset)")
    }

    /// The video frame in a SimpleBlock or BlockGroup; nil if the element belongs to another track (or, with
    /// `keyframeOnly`, isn't a keyframe).
    private func frame(in e: ElementHeader, _ r: ByteReader, keyframeOnly: Bool) async throws -> (relative: Int16, frame: [UInt8])? {
        switch e.id {
        case MKV.simpleBlock:
            guard let head = try await blockHead(e, r) else { return nil }
            if keyframeOnly && head.flags & 0x80 == 0 { return nil }
            return (head.relative, try await blockFrame(e, r, headerLength: head.length, flags: head.flags))
        case MKV.blockGroup:
            guard let end = e.end else { return nil }
            var block: (ElementHeader, (relative: Int16, flags: UInt8, length: Int))?
            var referenced = false
            var pos = e.dataStart
            while pos < end, let c = try await r.header(at: pos, window: 64, limit: end) {
                if c.id == MKV.block {
                    guard let head = try await blockHead(c, r) else { return nil }
                    block = (c, head)
                } else if c.id == MKV.referenceBlock {
                    referenced = true
                }
                guard let ce = c.end, ce > pos else { break }
                pos = ce
            }
            guard let (b, head) = block, !(keyframeOnly && referenced) else { return nil }
            return (head.relative, try await blockFrame(b, r, headerLength: head.length, flags: head.flags))
        default:
            return nil
        }
    }

    /// Track check and the fixed part of a (Simple)Block: relative timestamp, flags, header length.
    private func blockHead(_ e: ElementHeader, _ r: ByteReader) async throws -> (relative: Int16, flags: UInt8, length: Int)? {
        guard let size = e.size, size >= 4 else { return nil }
        let b = try await r.bytes(at: e.dataStart, count: Int(min(size, 12)))
        guard let (number, tl) = EBML.vint(b, at: 0), let n = number, n == Int64(trackNumber), b.count >= tl + 3 else { return nil }
        let relative = Int16(bitPattern: UInt16(b[tl]) << 8 | UInt16(b[tl + 1]))
        return (relative, b[tl + 2], tl + 3)
    }

    private func blockFrame(_ e: ElementHeader, _ r: ByteReader, headerLength: Int, flags: UInt8) async throws -> [UInt8] {
        guard flags & 0x06 == 0 else { throw MediaIndexError.unsupportedEncoding }
        guard let size = e.size, size <= Self.maxFrameSize else { throw MediaIndexError.malformed("block too large") }
        let count = Int(size) - headerLength
        let body = try await r.bytes(at: e.dataStart + Int64(headerLength), count: count)
        guard body.count == count else { throw MediaIndexError.dataUnavailable }
        return stripped.isEmpty ? body : stripped + body
    }
}
