import Foundation

public enum MatroskaError: Error, Equatable, Sendable {
    /// The file doesn't start with an EBML header of DocType "matroska" or "webm", or has no Segment.
    case notMatroska
    /// The bytes needed to read the track list aren't downloaded yet; try again later.
    case dataUnavailable
}

/// Reads text subtitle cues out of a Matroska file that may be only partly downloaded.
public actor MatroskaSubtitleReader {
    /// How far before the requested window reading starts, so cues that began earlier but are still showing are found.
    private static let lookback: Double = 10
    private static let maxElementRead: Int64 = 16 * 1024 * 1024
    private static let maxBlockRead: Int64 = 1024 * 1024
    private static let maxAttachmentsRead: Int64 = 96 * 1024 * 1024
    private static let defaultDuration: Double = 5

    private struct Encoding {
        var order: UInt64 = 0
        var scope: UInt64 = 1
        var type: UInt64 = 0
        var algo: UInt64 = 0
        var settings: [UInt8] = []
    }

    private struct Track {
        let info: SubtitleTrackInfo
        /// Frame encodings in decoding order (highest ContentEncodingOrder first).
        let encodings: [Encoding]
        /// CodecPrivate: for ASS, the script header with the styles.
        let codecPrivate: [UInt8]
    }

    private struct Layout {
        let segmentStart: Int64
        let segmentEnd: Int64
        /// Nanoseconds per timestamp tick.
        let scale: Double
        let tracks: [Int: Track]
        let infos: [SubtitleTrackInfo]
        let cuesOffset: Int64?
        let attachmentsOffset: Int64?
    }

    private struct CueEntry { let offset: Int64; let time: Int64 }
    private struct ClusterLink { let timestamp: Int64; let next: Int64? }
    private struct ClusterScan {
        var cues: [Int: [SubtitleCue]]
        var timestamp: Int64?
        var next: Int64?
        var complete: Bool
    }

    private let fileLength: Int64
    private let decompress: (@Sendable (Data) -> Data?)?
    private let read: @Sendable (Int64, Int) async throws -> Data?

    private var cache = ChunkCache(capacity: 8)
    private var layout: Layout?
    /// First Cluster, or where the top-level walk looking for it stopped.
    private var firstCluster: Int64?
    private var walkPosition: Int64 = 0
    private var cueIndex: [CueEntry]?
    private var cuesUnusable = false
    private var links: [Int64: ClusterLink] = [:]
    /// Cues of every text track for each completely read cluster.
    private var parsed: [Int64: [Int: [SubtitleCue]]] = [:]
    /// Offsets of consecutive clusters starting at the first one, as far as sequential scanning has seen.
    private var chain: [Int64] = []

    /// read(offset, length) returns the bytes, or nil if that range isn't available locally yet (never blocks waiting for download).
    /// decompress: optional zlib inflater for ContentCompAlgo 0; header stripping (algo 3) is handled internally.
    public init(fileLength: Int64, decompress: (@Sendable (Data) -> Data?)? = nil,
                read: @escaping @Sendable (Int64, Int) async throws -> Data?) {
        self.fileLength = fileLength
        self.decompress = decompress
        self.read = read
    }

    /// Text subtitle tracks, from the EBML header, Segment, SeekHead, Info and Tracks. Tracks whose blocks can't be
    /// decoded (encryption, bzip2/LZO, or zlib without a `decompress` closure) are left out. Throws
    /// `MatroskaError.notMatroska` for other files and `MatroskaError.dataUnavailable` while the track list isn't
    /// downloaded. Results are cached.
    public func tracks() async throws -> [SubtitleTrackInfo] {
        try await loadLayout().infos
    }

    /// Cues of one track overlapping [from, to] seconds, sorted by start. Uses the Cues index to start near `from`
    /// and otherwise scans clusters from the first one; stops quietly at data that isn't downloaded yet.
    public func cues(track: Int, from: Double, to: Double) async throws -> [SubtitleCue] {
        let l = try await loadLayout()
        guard let t = l.tracks[track], to >= from else { return [] }
        let startTicks = ticks(from - Self.lookback, l), endTicks = ticks(to, l)
        let found: [SubtitleCue]
        if let index = try await loadCueIndex(l) {
            found = try await scanIndexed(index, track: track, startTicks: startTicks, endTicks: endTicks, l)
        } else {
            found = try await scanSequentially(track: track, startTicks: startTicks, endTicks: endTicks, l)
        }
        var result = found.filter { $0.end > from && $0.start <= to }
        if t.info.format == .ass { result = ASSScript.mergeSimultaneous(result) }
        return SubtitleParser.sorted(result)
    }

    /// The script header of an ASS track (resolution and styles); nil for other tracks.
    public func assHeader(track: Int) async throws -> ASSHeader? {
        let l = try await loadLayout()
        guard let t = l.tracks[track], t.info.format == .ass, !t.codecPrivate.isEmpty else { return nil }
        return ASSHeader.parse(String(decoding: t.codecPrivate, as: UTF8.self))
    }

    /// Fonts attached to the file (TrueType, OpenType and collections), which ASS styles name. Empty when the file
    /// has none; throws `dataUnavailable` while they aren't downloaded.
    public func fonts() async throws -> [(name: String, data: Data)] {
        let l = try await loadLayout()
        guard let offset = l.attachmentsOffset,
              let b = try await element(at: offset, id: MKV.attachments, limit: Self.maxAttachmentsRead) else { return [] }
        var out: [(name: String, data: Data)] = []
        for file in EBML.children(b, in: 0..<b.count) where file.id == MKV.attachedFile {
            var name = "", mime = ""
            var data: Range<Int>?
            for c in EBML.children(b, in: file.data) {
                switch c.id {
                case MKV.fileName: name = EBML.string(b[c.data])
                case MKV.fileMimeType: mime = EBML.string(b[c.data]).lowercased()
                case MKV.fileData: data = c.data
                default: break
                }
            }
            let ext = (name as NSString).pathExtension.lowercased()
            guard let data, mime.contains("font") || ["ttf", "otf", "ttc", "otc"].contains(ext) else { continue }
            out.append((name, Data(b[data])))
        }
        return out
    }

    // MARK: bytes

    /// Up to `count` bytes at `offset` (fewer at the end of the file). Throws `dataUnavailable` when not local.
    private func bytes(at offset: Int64, count: Int) async throws -> [UInt8] {
        let count = Int(max(0, min(Int64(count), fileLength - offset)))
        guard count > 0, offset >= 0 else { return [] }
        let cs = Int64(ChunkCache.chunkSize)
        let first = offset / cs, last = (offset + Int64(count) - 1) / cs
        if last - first <= 1 {
            var out: [UInt8] = []
            out.reserveCapacity(count)
            for index in first...last {
                guard let chunk = try await chunk(index) else { break }
                let base = index * cs
                let lo = Int(max(offset, base) - base), hi = Int(min(offset + Int64(count), base + Int64(chunk.count)) - base)
                guard lo < hi else { break }
                out += chunk[lo..<hi]
            }
            if out.count == count { return out }
        }
        guard let data = try await read(offset, count) else { throw MatroskaError.dataUnavailable }
        return [UInt8](data.prefix(count))
    }

    private func chunk(_ index: Int64) async throws -> [UInt8]? {
        if let c = cache.get(index) { return c }
        let start = index * Int64(ChunkCache.chunkSize)
        let length = Int(min(Int64(ChunkCache.chunkSize), fileLength - start))
        guard length > 0, let data = try await read(start, length) else { return nil }
        let c = [UInt8](data)
        cache.put(index, c)
        return c
    }

    /// The element starting at `offset`, or nil if the bytes there aren't a valid element header.
    private func header(at offset: Int64) async throws -> ElementHeader? {
        let b = try await bytes(at: offset, count: 12)
        guard let (id, il) = EBML.id(b, at: 0), let (size, sl) = EBML.vint(b, at: il) else { return nil }
        return ElementHeader(id: id, offset: offset, dataStart: offset + Int64(il + sl), size: size)
    }

    private func payload(_ h: ElementHeader, limit: Int64) async throws -> [UInt8]? {
        guard let size = h.size, size <= limit else { return nil }
        return try await bytes(at: h.dataStart, count: Int(size))
    }

    // MARK: layout

    private func loadLayout() async throws -> Layout {
        if let l = layout { return l }
        guard let ebml = try await header(at: 0), ebml.id == MKV.ebml,
              let head = try await payload(ebml, limit: 4096), let ebmlEnd = ebml.end else { throw MatroskaError.notMatroska }
        let docType = EBML.children(head, in: 0..<head.count).first { $0.id == MKV.docType }.map { EBML.string(head[$0.data]) }
        guard ["matroska", "webm"].contains(docType ?? "matroska") else { throw MatroskaError.notMatroska }

        var pos = ebmlEnd
        var segment: ElementHeader?
        while pos < fileLength, let h = try await header(at: pos) {
            if h.id == MKV.segment { segment = h; break }
            guard let end = h.end else { break }
            pos = end
        }
        guard let seg = segment else { throw MatroskaError.notMatroska }
        let segStart = seg.dataStart
        let segEnd = min(seg.end ?? fileLength, fileLength)

        var seeks: [UInt32: Int64] = [:]
        var seekHeadsRead = Set<Int64>()
        var infoBytes: [UInt8]?
        var tracksBytes: [UInt8]?
        var cuesOffset: Int64?
        var attachmentsOffset: Int64?
        // True once the walk reached the first Cluster or the end of what can be walked.
        var walkComplete = true
        pos = segStart
        do {
            walk: while pos < segEnd, let h = try await header(at: pos) {
                switch h.id {
                case MKV.seekHead:
                    seekHeadsRead.insert(h.offset)
                    if let b = try await payload(h, limit: Self.maxElementRead) { Self.parseSeekHead(b, segmentStart: segStart, into: &seeks) }
                case MKV.info: infoBytes = try await payload(h, limit: Self.maxElementRead)
                case MKV.tracks: tracksBytes = try await payload(h, limit: Self.maxElementRead)
                case MKV.cues: cuesOffset = h.offset
                case MKV.attachments: attachmentsOffset = h.offset
                case MKV.cluster: firstCluster = h.offset; break walk
                default: break
                }
                guard let end = h.end else { break }
                pos = end
            }
        } catch MatroskaError.dataUnavailable {
            walkComplete = false
        }
        walkPosition = pos

        if let other = seeks[MKV.seekHead], !seekHeadsRead.contains(other),
           let b = try await availableOrNil({ try await self.element(at: other, id: MKV.seekHead) }) {
            Self.parseSeekHead(b, segmentStart: segStart, into: &seeks)
        }
        if tracksBytes == nil, let p = seeks[MKV.tracks] { tracksBytes = try await element(at: p, id: MKV.tracks) }
        if infoBytes == nil, let p = seeks[MKV.info] { infoBytes = try await element(at: p, id: MKV.info) }
        guard tracksBytes != nil || walkComplete, infoBytes != nil || walkComplete else { throw MatroskaError.dataUnavailable }

        let tracks = tracksBytes.map { parseTracks($0) } ?? []
        var scale = 1_000_000.0
        if let b = infoBytes, let ts = EBML.children(b, in: 0..<b.count).first(where: { $0.id == MKV.timestampScale }) {
            let v = EBML.uint(b[ts.data])
            if v > 0 { scale = Double(v) }
        }
        let l = Layout(segmentStart: segStart, segmentEnd: segEnd, scale: scale,
                       tracks: Dictionary(tracks.map { ($0.info.number, $0) }, uniquingKeysWith: { a, _ in a }),
                       infos: tracks.map(\.info), cuesOffset: cuesOffset ?? seeks[MKV.cues],
                       attachmentsOffset: attachmentsOffset ?? seeks[MKV.attachments])
        layout = l
        return l
    }

    /// Runs `body`, turning missing data into nil while passing other errors on.
    private func availableOrNil<T>(_ body: () async throws -> T?) async throws -> T? {
        do { return try await body() } catch MatroskaError.dataUnavailable { return nil }
    }

    /// Payload of the element with `id` at an absolute offset; nil if something else is there.
    private func element(at offset: Int64, id: UInt32, limit: Int64 = MatroskaSubtitleReader.maxElementRead) async throws -> [UInt8]? {
        guard let h = try await header(at: offset), h.id == id else { return nil }
        return try await payload(h, limit: limit)
    }

    private static func parseSeekHead(_ b: [UInt8], segmentStart: Int64, into seeks: inout [UInt32: Int64]) {
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

    private func parseTracks(_ b: [UInt8]) -> [Track] {
        var out: [Track] = []
        for entry in EBML.children(b, in: 0..<b.count) where entry.id == MKV.trackEntry {
            var number = 0, codec = "", isDefault = true, isForced = false
            var language: String?, ietf: String?, name: String?
            var encodings: [Encoding] = []
            var codecPrivate: [UInt8] = []
            for c in EBML.children(b, in: entry.data) {
                switch c.id {
                case MKV.trackNumber: number = Int(clamping: EBML.uint(b[c.data]))
                case MKV.codecID: codec = EBML.string(b[c.data])
                case MKV.language: language = EBML.string(b[c.data])
                case MKV.languageIETF: ietf = EBML.string(b[c.data])
                case MKV.name: name = EBML.string(b[c.data])
                case MKV.flagDefault: isDefault = EBML.uint(b[c.data]) != 0
                case MKV.flagForced: isForced = EBML.uint(b[c.data]) != 0
                case MKV.contentEncodings: encodings = Self.parseEncodings(b, c.data)
                case MKV.codecPrivate: codecPrivate = Array(b[c.data])
                default: break
                }
            }
            guard number > 0, let format = SubtitleFormat(codecID: codec) else { continue }
            let frameEncodings = encodings.filter { $0.scope & 1 != 0 }.sorted { $0.order > $1.order }
            let decodable = frameEncodings.allSatisfy { $0.type == 0 && ($0.algo == 3 || ($0.algo == 0 && decompress != nil)) }
            guard decodable else { continue }
            let lang = [ietf, language].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? "eng"
            let info = SubtitleTrackInfo(number: number, codecID: codec, format: format, language: lang,
                                         name: name.flatMap { $0.isEmpty ? nil : $0 }, isDefault: isDefault, isForced: isForced)
            // CodecPrivate may be compressed too (ContentEncodingScope bit 2).
            let privateEncodings = encodings.filter { $0.scope & 2 != 0 }.sorted { $0.order > $1.order }
            let header = privateEncodings.isEmpty ? codecPrivate : (decode(codecPrivate, privateEncodings) ?? [])
            out.append(Track(info: info, encodings: frameEncodings, codecPrivate: header))
        }
        return out
    }

    private static func parseEncodings(_ b: [UInt8], _ range: Range<Int>) -> [Encoding] {
        EBML.children(b, in: range).filter { $0.id == MKV.contentEncoding }.map { enc in
            var e = Encoding()
            for c in EBML.children(b, in: enc.data) {
                switch c.id {
                case MKV.contentEncodingOrder: e.order = EBML.uint(b[c.data])
                case MKV.contentEncodingScope: e.scope = EBML.uint(b[c.data])
                case MKV.contentEncodingType: e.type = EBML.uint(b[c.data])
                case MKV.contentCompression:
                    for cc in EBML.children(b, in: c.data) {
                        if cc.id == MKV.contentCompAlgo { e.algo = EBML.uint(b[cc.data]) }
                        if cc.id == MKV.contentCompSettings { e.settings = Array(b[cc.data]) }
                    }
                default: break
                }
            }
            return e
        }
    }

    private func ticks(_ seconds: Double, _ l: Layout) -> Int64 {
        Int64(max(-1e15, min(1e15, (seconds * 1e9 / l.scale).rounded(.down))))
    }

    // MARK: cue index

    private func loadCueIndex(_ l: Layout) async throws -> [CueEntry]? {
        if let index = cueIndex { return index }
        guard !cuesUnusable, let offset = l.cuesOffset else { return nil }
        let b: [UInt8]
        do {
            guard let h = try await header(at: offset), h.id == MKV.cues,
                  let p = try await payload(h, limit: Self.maxElementRead) else { cuesUnusable = true; return nil }
            b = p
        } catch MatroskaError.dataUnavailable {
            return nil
        }
        var entries: [CueEntry] = []
        for point in EBML.children(b, in: 0..<b.count) where point.id == MKV.cuePoint {
            var time: Int64?
            var positions: [Int64] = []
            for c in EBML.children(b, in: point.data) {
                if c.id == MKV.cueTime { time = Int64(clamping: EBML.uint(b[c.data])) }
                if c.id == MKV.cueTrackPositions {
                    for p in EBML.children(b, in: c.data) where p.id == MKV.cueClusterPosition {
                        positions.append(l.segmentStart + Int64(clamping: EBML.uint(b[p.data])))
                    }
                }
            }
            if let t = time { entries += positions.map { CueEntry(offset: $0, time: t) } }
        }
        entries.sort { $0.offset != $1.offset ? $0.offset < $1.offset : $0.time < $1.time }
        var unique: [CueEntry] = []
        for e in entries where unique.last?.offset != e.offset { unique.append(e) }
        guard !unique.isEmpty else { cuesUnusable = true; return nil }
        cueIndex = unique
        return unique
    }

    // MARK: scanning

    private func scanIndexed(_ index: [CueEntry], track: Int, startTicks: Int64, endTicks: Int64, _ l: Layout) async throws -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var i = max(0, partition(index.count) { index[$0].time > startTicks } - 1)
        var pos = index[i].offset
        var visited = Set<Int64>()
        while true {
            let scan = try await scanCluster(from: pos, stopAfter: endTicks, l)
            if let s = scan.value, let ts = s.timestamp, !visited.contains(scan.offset) {
                visited.insert(scan.offset)
                if ts > endTicks { break }
                out += s.cues[track] ?? []
                if s.complete, let next = s.next {
                    pos = next
                    continue
                }
            } else if scan.atEnd {
                break
            }
            // Resume at the next indexed cluster past the gap.
            let resumeAfter = max(pos, scan.offset)
            i = partition(index.count) { index[$0].offset > resumeAfter }
            guard i < index.count, index[i].time <= endTicks else { break }
            pos = index[i].offset
        }
        return out
    }

    private func scanSequentially(track: Int, startTicks: Int64, endTicks: Int64, _ l: Layout) async throws -> [SubtitleCue] {
        if chain.isEmpty {
            guard let first = try await locateFirstCluster(l) else { return [] }
            if chain.isEmpty { chain = [first] }
        }
        // Follow cluster sizes (cheap: a header and a timestamp each) until passing the window start.
        while let last = chain.last, let link = try await linkOrNil(last, l), link.timestamp <= startTicks {
            var next = link.next
            if next == nil {
                let s = try await scanCluster(from: last, stopAfter: .max, l)
                guard s.value?.complete == true else { break }
                next = s.value?.next
            }
            guard let n = next, let h = try await availableOrNil({ try await self.clusterHeader(from: n, l) }),
                  h.offset > (chain.last ?? -1) else { break }
            chain.append(h.offset)
        }
        var k = chain.lastIndex { (links[$0]?.timestamp ?? .max) <= startTicks } ?? 0
        var out: [SubtitleCue] = []
        while k < chain.count {
            let scan = try await scanCluster(from: chain[k], stopAfter: endTicks, l)
            guard let s = scan.value, let ts = s.timestamp, ts <= endTicks else { break }
            out += s.cues[track] ?? []
            guard s.complete, let next = s.next else { break }
            if k + 1 >= chain.count {
                guard let h = try await availableOrNil({ try await self.clusterHeader(from: next, l) }),
                      h.offset > (chain.last ?? -1) else { break }
                chain.append(h.offset)
            }
            k += 1
        }
        return out
    }

    /// Index of the first element for which `pred` holds, given it is false then true across 0..<count.
    private func partition(_ count: Int, _ pred: (Int) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    private func locateFirstCluster(_ l: Layout) async throws -> Int64? {
        if let f = firstCluster { return f }
        var pos = max(walkPosition, l.segmentStart)
        do {
            while pos < l.segmentEnd, let h = try await header(at: pos) {
                if h.id == MKV.cluster { firstCluster = h.offset; return h.offset }
                guard let end = h.end else { break }
                pos = end
                walkPosition = pos
            }
        } catch MatroskaError.dataUnavailable {}
        return nil
    }

    /// The next Cluster at or after `offset`, skipping Void, Tags, Cues and other elements in between.
    private func clusterHeader(from offset: Int64, _ l: Layout) async throws -> ElementHeader? {
        var pos = offset
        while pos < l.segmentEnd {
            guard let h = try await header(at: pos) else { return nil }
            if h.id == MKV.cluster { return h }
            guard let end = h.end, end > pos else { return nil }
            pos = end
        }
        return nil
    }

    private func linkOrNil(_ offset: Int64, _ l: Layout) async throws -> ClusterLink? {
        if let link = links[offset] { return link }
        do {
            guard let h = try await header(at: offset), h.id == MKV.cluster else { return nil }
            let limit = min(h.end ?? l.segmentEnd, l.segmentEnd)
            var pos = h.dataStart
            while pos < limit, let c = try await header(at: pos) {
                if c.id == MKV.timestamp {
                    let link = ClusterLink(timestamp: Int64(clamping: EBML.uint(ArraySlice(try await payload(c, limit: 8) ?? []))), next: h.end)
                    links[offset] = link
                    return link
                }
                if c.id == MKV.simpleBlock || c.id == MKV.blockGroup || MKV.segmentChildren.contains(c.id) { return nil }
                guard let end = c.end else { return nil }
                pos = end
            }
        } catch MatroskaError.dataUnavailable {}
        return nil
    }

    /// Reads the cluster at or after `offset`. `value` is nil when no cluster could be read there; `atEnd` is true
    /// when that is because the segment ended rather than because data is missing. A cluster starting after
    /// `stopAfter` ticks is returned with its timestamp only.
    private func scanCluster(from offset: Int64, stopAfter: Int64, _ l: Layout) async throws -> (value: ClusterScan?, offset: Int64, atEnd: Bool) {
        if let cues = parsed[offset], let link = links[offset] {
            return (ClusterScan(cues: cues, timestamp: link.timestamp, next: link.next, complete: true), offset, false)
        }
        if let link = links[offset], link.timestamp > stopAfter {
            return (ClusterScan(cues: [:], timestamp: link.timestamp, next: link.next, complete: false), offset, false)
        }
        let h: ElementHeader
        do {
            guard let found = try await clusterHeader(from: offset, l) else { return (nil, offset, true) }
            h = found
        } catch MatroskaError.dataUnavailable {
            return (nil, offset, false)
        }
        if let cues = parsed[h.offset], let link = links[h.offset] {
            return (ClusterScan(cues: cues, timestamp: link.timestamp, next: link.next, complete: true), h.offset, false)
        }
        return (try await parseCluster(h, stopAfter: stopAfter, l), h.offset, false)
    }

    private func parseCluster(_ h: ElementHeader, stopAfter: Int64, _ l: Layout) async throws -> ClusterScan {
        var scan = ClusterScan(cues: [:], timestamp: links[h.offset]?.timestamp, next: h.end, complete: false)
        let limit = min(h.end ?? l.segmentEnd, l.segmentEnd)
        var pos = h.dataStart
        do {
            while pos < limit {
                guard let c = try await header(at: pos) else { break }
                if h.size == nil && MKV.segmentChildren.contains(c.id) {
                    scan.next = pos
                    break
                }
                switch c.id {
                case MKV.timestamp:
                    let ts = Int64(clamping: EBML.uint(ArraySlice(try await payload(c, limit: 8) ?? [])))
                    scan.timestamp = ts
                    if ts > stopAfter {
                        links[h.offset] = ClusterLink(timestamp: ts, next: h.end)
                        return scan
                    }
                case MKV.simpleBlock:
                    if let ts = scan.timestamp, let (track, cue) = try await blockCue(c, clusterTime: ts, duration: nil, l) {
                        scan.cues[track, default: []].append(cue)
                    }
                case MKV.blockGroup:
                    if let ts = scan.timestamp, let (track, cue) = try await groupCue(c, clusterTime: ts, l) {
                        scan.cues[track, default: []].append(cue)
                    }
                default: break
                }
                guard let end = c.end else { break }
                pos = end
            }
            if pos >= limit {
                scan.next = scan.next ?? limit
                scan.complete = true
            } else if scan.next != nil && h.size == nil {
                scan.complete = true
            }
        } catch MatroskaError.dataUnavailable {
            scan.complete = false
        }
        if let ts = scan.timestamp {
            links[h.offset] = ClusterLink(timestamp: ts, next: scan.complete ? scan.next : h.end)
            if scan.complete { parsed[h.offset] = scan.cues }
        }
        return scan
    }

    private func groupCue(_ g: ElementHeader, clusterTime: Int64, _ l: Layout) async throws -> (Int, SubtitleCue)? {
        guard let end = g.end else { return nil }
        var block: ElementHeader?
        var duration: Int64?
        var pos = g.dataStart
        while pos < end, let c = try await header(at: pos) {
            if c.id == MKV.block {
                guard try await blockTrack(c, l) != nil else { return nil }
                block = c
            } else if c.id == MKV.blockDuration {
                duration = Int64(clamping: EBML.uint(ArraySlice(try await payload(c, limit: 8) ?? [])))
            }
            guard let e = c.end else { break }
            pos = e
        }
        guard let b = block else { return nil }
        return try await blockCue(b, clusterTime: clusterTime, duration: duration, l)
    }

    /// The text track a Block/SimpleBlock belongs to, read from its first bytes only.
    private func blockTrack(_ e: ElementHeader, _ l: Layout) async throws -> Track? {
        guard let size = e.size, size > 0 else { return nil }
        let head = try await bytes(at: e.dataStart, count: Int(min(size, 8)))
        guard let (number, _) = EBML.vint(head, at: 0), let n = number else { return nil }
        return l.tracks[Int(clamping: n)]
    }

    private func blockCue(_ e: ElementHeader, clusterTime: Int64, duration: Int64?, _ l: Layout) async throws -> (Int, SubtitleCue)? {
        guard let track = try await blockTrack(e, l), let b = try await payload(e, limit: Self.maxBlockRead),
              let (_, tl) = EBML.vint(b, at: 0), b.count >= tl + 3 else { return nil }
        let relative = Int16(bitPattern: UInt16(b[tl]) << 8 | UInt16(b[tl + 1]))
        guard b[tl + 2] & 0x06 == 0, let frame = decode(Array(b[(tl + 3)...]), track) else { return nil }
        let start = Double(clusterTime + Int64(relative)) * l.scale / 1e9
        let end = duration.map { start + Double($0) * l.scale / 1e9 } ?? start + Self.defaultDuration
        let text = SubtitleText.normalizeNewlines(String(decoding: frame, as: UTF8.self))
        let cue: SubtitleCue?
        switch track.info.format {
        case .srt: cue = SubtitleCue(start: start, end: end, text: SubtitleMarkup.plainSRT(text))
        case .vtt: cue = SubtitleCue(start: start, end: end, text: SubtitleMarkup.plainVTT(text))
        case .ass:
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if fields.count == 9 {
                cue = ASSScript.cue(start: start, end: end, style: fields[2], text: fields[8])
            } else {
                cue = SubtitleCue(start: start, end: end, text: SubtitleMarkup.plainASS(text))
            }
        }
        guard let c = cue, !c.text.isEmpty else { return nil }
        return (track.info.number, c)
    }

    private func decode(_ frame: [UInt8], _ track: Track) -> [UInt8]? {
        decode(frame, track.encodings)
    }

    private func decode(_ frame: [UInt8], _ encodings: [Encoding]) -> [UInt8]? {
        var data = frame
        for e in encodings {
            switch e.algo {
            case 3: data = e.settings + data
            case 0:
                guard let inflate = decompress, let out = inflate(Data(data)) else { return nil }
                data = [UInt8](out)
            default: return nil
            }
        }
        return data
    }
}
