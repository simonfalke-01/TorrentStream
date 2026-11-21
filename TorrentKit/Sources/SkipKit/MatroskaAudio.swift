import Foundation

/// Reads `length` bytes at `offset` of the file, or nil if they aren't available (yet).
public typealias ByteReader = @Sendable (_ offset: Int64, _ length: Int) async -> Data?

/// The audio track an episode is fingerprinted from.
public struct AudioTrackInfo: Sendable, Equatable {
    public var number: UInt64
    /// Matroska codec ID, e.g. `A_AAC`, `A_OPUS`, `A_FLAC`, `A_AC3`, `A_EAC3`, `A_PCM/INT/LIT`.
    public var codecID: String
    public var codecPrivate: Data
    public var sampleRate: Double
    public var channels: Int
    public var bitDepth: Int
}

/// One compressed audio frame. Frames laced into one block share the block's time; only the first is marked as
/// starting at it.
public struct AudioPacket: Sendable, Equatable {
    /// Seconds from the start of the file of the block the frame came in.
    public var time: Double
    public var data: Data
    /// Whether the frame starts at `time` (the first of its block), rather than following the one before.
    public var isTimed: Bool = true
}

/// The parts of a Matroska file needed to pull out its audio: the audio track and where the clusters are.
public struct MatroskaAudioLayout: Sendable {
    public var audio: AudioTrackInfo
    /// Length of the file's media in seconds, 0 if not stated.
    public var duration: Double
    /// Nanoseconds per timestamp tick.
    var timestampScale: Double
    /// File offset of the segment's payload, which positions in the file are relative to.
    var segmentStart: Int64
    /// File offset of the first cluster.
    var firstCluster: Int64
    /// Cluster start times and file offsets from the cue index, by time. Empty when the file has none (or they were
    /// not available when the header was read).
    public var cues: [(time: Double, offset: Int64)]
    /// Header stripping applied to the audio track: these bytes were removed from the front of every frame.
    var strippedHeader: Data

    /// File offset of the latest cluster starting at or before `time`, if the cues say.
    public func clusterOffset(before time: Double) -> Int64? {
        var best: Int64?
        for c in cues where c.time <= time { best = c.offset }
        return best ?? cues.first?.offset
    }
}

/// A cluster's audio and where the next cluster starts.
public struct ClusterAudio: Sendable {
    public var offset: Int64
    /// File offset just past this cluster, or nil if its size isn't stated.
    public var end: Int64?
    /// Cluster time in seconds.
    public var time: Double
    public var packets: [AudioPacket]
}

/// Pulls the audio out of a Matroska (MKV/WebM) file a piece at a time, so that whatever part of a torrent has
/// downloaded can be analysed.
public enum MatroskaAudio {
    enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let flagDefault: UInt32 = 0x88
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let outputSamplingFrequency: UInt32 = 0x78B5
        static let channels: UInt32 = 0x9F
        static let bitDepth: UInt32 = 0x6264
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let cluster: UInt32 = 0x1F43_B675
        static let timestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueClusterPosition: UInt32 = 0xF1
    }

    /// How much of the file start is read to find the track list; less is tried if that much isn't available yet.
    static let headSizes = [256 * 1024, 64 * 1024, 16 * 1024]

    /// Reads the header and, if available, the cue index. Nil if the file isn't Matroska, has no audio track, or its
    /// header hasn't downloaded yet.
    public static func layout(read: ByteReader, fileSize: Int64) async -> MatroskaAudioLayout? {
        var data: Data?
        for size in headSizes {
            if let d = await read(0, Int(min(Int64(size), fileSize))) { data = d; break }
        }
        guard let head = data else { return nil }
        let b = [UInt8](head)
        guard let ebml = Element.parse(b, at: 0), ebml.id == ID.ebml, let ebmlEnd = ebml.end,
              let segment = Element.parse(b, at: Int(ebmlEnd)), segment.id == ID.segment else { return nil }
        let segmentStart = Int64(segment.dataStart)
        var scale = 1_000_000.0, duration = 0.0
        var track: AudioTrackInfo?
        var stripped = Data()
        var cuesPosition: Int64?
        var firstCluster: Int64?
        var i = segment.dataStart
        while i < b.count, let e = Element.parse(b, at: i) {
            if e.id == ID.cluster { firstCluster = Int64(i); break }
            guard let end = e.end else { break }
            if end <= Int64(b.count) {
                let payload = e.dataStart..<Int(end)
                switch e.id {
                case ID.seekHead:
                    for seek in children(b, payload) where seek.id == ID.seek {
                        let fields = children(b, seek.data)
                        if let id = fields.first(where: { $0.id == ID.seekID }), uint(b[id.data]) == UInt64(ID.cues),
                           let pos = fields.first(where: { $0.id == ID.seekPosition }) {
                            cuesPosition = segmentStart + Int64(uint(b[pos.data]))
                        }
                    }
                case ID.info:
                    for f in children(b, payload) {
                        if f.id == ID.timestampScale { scale = Double(uint(b[f.data])) }
                        if f.id == ID.duration { duration = float(b[f.data]) ?? 0 }
                    }
                case ID.tracks:
                    (track, stripped) = audioTrack(b, payload) ?? (nil, Data())
                default:
                    break
                }
            }
            i = Int(end)
        }
        guard let audio = track else { return nil }
        var layout = MatroskaAudioLayout(audio: audio, duration: duration * scale / 1e9, timestampScale: scale,
                                         segmentStart: segmentStart, firstCluster: firstCluster ?? Int64(i), cues: [],
                                         strippedHeader: stripped)
        if let position = cuesPosition, position < fileSize {
            layout.cues = await cues(read: read, at: position, fileSize: fileSize, layout: layout)
        }
        return layout
    }

    /// The default audio track (else the first), and any header stripped from its frames.
    static func audioTrack(_ b: [UInt8], _ range: Range<Int>) -> (AudioTrackInfo, Data)? {
        var found: [(info: AudioTrackInfo, isDefault: Bool, stripped: Data)] = []
        for entry in children(b, range) where entry.id == ID.trackEntry {
            var number: UInt64 = 0, type: UInt64 = 0, isDefault = true, codec = "", priv = Data()
            var rate = 8000.0, outRate: Double?, channels = 1, depth = 0
            var stripped = Data()
            for f in children(b, entry.data) {
                switch f.id {
                case ID.trackNumber: number = uint(b[f.data])
                case ID.trackType: type = uint(b[f.data])
                case ID.flagDefault: isDefault = uint(b[f.data]) != 0
                case ID.codecID: codec = string(b[f.data])
                case ID.codecPrivate: priv = Data(b[f.data])
                case ID.audio:
                    for a in children(b, f.data) {
                        if a.id == ID.samplingFrequency { rate = float(b[a.data]) ?? rate }
                        if a.id == ID.outputSamplingFrequency { outRate = float(b[a.data]) }
                        if a.id == ID.channels { channels = Int(uint(b[a.data])) }
                        if a.id == ID.bitDepth { depth = Int(uint(b[a.data])) }
                    }
                case ID.contentEncodings:
                    for enc in children(b, f.data) where enc.id == ID.contentEncoding {
                        for comp in children(b, enc.data) where comp.id == ID.contentCompression {
                            let fields = children(b, comp.data)
                            let algo = fields.first { $0.id == ID.contentCompAlgo }.map { uint(b[$0.data]) } ?? 0
                            guard algo == 3 else { return nil }
                            if let s = fields.first(where: { $0.id == ID.contentCompSettings }) { stripped = Data(b[s.data]) }
                        }
                    }
                default: break
                }
            }
            guard type == 2, number > 0 else { continue }
            // SBR AAC states its core rate in SamplingFrequency and the decoded rate in OutputSamplingFrequency.
            let info = AudioTrackInfo(number: number, codecID: codec, codecPrivate: priv, sampleRate: outRate ?? rate,
                                      channels: max(1, channels), bitDepth: depth)
            found.append((info, isDefault, stripped))
        }
        guard let pick = found.first(where: \.isDefault) ?? found.first else { return nil }
        return (pick.info, pick.stripped)
    }

    /// Cluster offsets listed in the cue index at `position`.
    static func cues(read: ByteReader, at position: Int64, fileSize: Int64,
                     layout: MatroskaAudioLayout) async -> [(time: Double, offset: Int64)] {
        guard let headData = await read(position, Int(min(12, fileSize - position))),
              let e = Element.parse([UInt8](headData), at: 0), e.id == ID.cues, let size = e.size,
              size < 64 << 20, position + Int64(e.dataStart) + size <= fileSize,
              let data = await read(position + Int64(e.dataStart), Int(size)) else { return [] }
        let b = [UInt8](data)
        var out: [(time: Double, offset: Int64)] = []
        var last: Int64 = -1
        for point in children(b, 0..<b.count) where point.id == ID.cuePoint {
            var time: UInt64?, offset: Int64?
            for f in children(b, point.data) {
                if f.id == ID.cueTime { time = uint(b[f.data]) }
                if f.id == ID.cueTrackPositions, offset == nil,
                   let c = children(b, f.data).first(where: { $0.id == ID.cueClusterPosition }) {
                    offset = layout.segmentStart + Int64(uint(b[c.data]))
                }
            }
            guard let t = time, let o = offset, o != last else { continue }
            out.append((Double(t) * layout.timestampScale / 1e9, o))
            last = o
        }
        return out.sorted { $0.offset < $1.offset }
    }

    /// File offset just past the cluster at `offset`, read from its header alone; nil if unavailable, not a cluster,
    /// or of unknown size.
    public static func clusterEnd(at offset: Int64, read: ByteReader, fileSize: Int64) async -> Int64? {
        guard offset < fileSize, let headData = await read(offset, Int(min(12, fileSize - offset))),
              let e = Element.parse([UInt8](headData), at: 0), e.id == ID.cluster, let end = e.end else { return nil }
        return offset + end
    }

    /// The audio in the cluster at `offset`, or nil if it isn't (all) available or there is no cluster there.
    public static func cluster(at offset: Int64, layout: MatroskaAudioLayout, read: ByteReader,
                               fileSize: Int64) async -> ClusterAudio? {
        guard offset < fileSize, let headData = await read(offset, Int(min(12, fileSize - offset))),
              let e = Element.parse([UInt8](headData), at: 0), e.id == ID.cluster else { return nil }
        let start = offset + Int64(e.dataStart)
        // Clusters of unknown size run to the next cluster; read a bounded window and stop at the next top-level element.
        let size = e.size ?? min(16 << 20, fileSize - start)
        guard size >= 0, size < 64 << 20, start + size <= fileSize, let data = await read(start, Int(size)) else { return nil }
        return parseCluster([UInt8](data), offset: offset, dataStart: start, sized: e.size != nil, layout: layout)
    }

    static func parseCluster(_ b: [UInt8], offset: Int64, dataStart: Int64, sized: Bool,
                             layout: MatroskaAudioLayout) -> ClusterAudio {
        var clusterTime: Int64 = 0
        var packets: [AudioPacket] = []
        var i = 0
        var end: Int64? = sized ? dataStart + Int64(b.count) : nil
        let tick = layout.timestampScale / 1e9
        func block(_ r: Range<Int>) {
            guard let (track, tl) = vint(b, at: r.lowerBound), track == Int64(layout.audio.number),
                  r.lowerBound + tl + 3 <= r.upperBound else { return }
            let p = r.lowerBound + tl
            let relative = Int16(bitPattern: UInt16(b[p]) << 8 | UInt16(b[p + 1]))
            let time = Double(clusterTime + Int64(relative)) * tick
            for (n, frame) in frames(b, from: p + 3, to: r.upperBound, lacing: (b[p + 2] >> 1) & 3).enumerated() {
                var data = layout.strippedHeader
                data.append(contentsOf: b[frame])
                packets.append(AudioPacket(time: time, data: data, isTimed: n == 0))
            }
        }
        while i < b.count, let (id, il) = elementID(b, at: i), let (size, sl) = vint(b, at: i + il) {
            if !sized && (id == ID.cluster || id == ID.cues || id == 0x1254_C367 || id == 0x1043_A770) {
                end = dataStart + Int64(i)
                break
            }
            let s = i + il + sl
            let e = size.map { s + Int($0) } ?? b.count
            guard e <= b.count else { break }
            switch id {
            case ID.timestamp: clusterTime = Int64(uint(b[s..<e]))
            case ID.simpleBlock: block(s..<e)
            case ID.blockGroup:
                for c in children(b, s..<e) where c.id == ID.block { block(c.data) }
            default: break
            }
            i = e
        }
        // Frames laced into one block share its time; the decoded audio of a run of packets is laid out from the
        // first one's time.
        return ClusterAudio(offset: offset, end: end, time: Double(clusterTime) * tick, packets: packets)
    }

    /// Byte ranges of the frames in a block payload starting at `i`.
    static func frames(_ b: [UInt8], from start: Int, to end: Int, lacing: UInt8) -> [Range<Int>] {
        guard lacing != 0 else { return [start..<end] }
        guard start < end else { return [] }
        let count = Int(b[start]) + 1
        var i = start + 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var size = 0
                while i < end { let v = Int(b[i]); i += 1; size += v; if v != 255 { break } }
                sizes.append(size)
            }
        case 3: // EBML
            guard let (first, l) = vint(b, at: i), let f = first else { return [] }
            i += l
            sizes.append(Int(f))
            for _ in 1..<max(1, count - 1) {
                guard let (raw, l) = vint(b, at: i), let r = raw else { return [] }
                // Signed difference: subtract half the range of an l-byte number.
                let bias = (Int64(1) << (7 * Int64(l) - 1)) - 1
                i += l
                sizes.append(sizes.last! + Int(r - bias))
            }
        default: // fixed
            let each = (end - i) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        var out: [Range<Int>] = []
        for size in sizes {
            guard size >= 0, i + size <= end else { return [] }
            out.append(i..<(i + size))
            i += size
        }
        if i <= end { out.append(i..<end) }
        return out
    }

    // MARK: EBML

    struct Element {
        var id: UInt32
        var dataStart: Int
        var size: Int64?
        var end: Int64? { size.map { Int64(dataStart) + $0 } }

        static func parse(_ b: [UInt8], at i: Int) -> Element? {
            guard let (id, il) = elementID(b, at: i), let (size, sl) = vint(b, at: i + il) else { return nil }
            return Element(id: id, dataStart: i + il + sl, size: size)
        }
    }

    static func elementID(_ b: [UInt8], at i: Int) -> (UInt32, Int)? {
        guard i >= 0, i < b.count, b[i] != 0 else { return nil }
        let len = b[i].leadingZeroBitCount + 1
        guard len <= 4, i + len <= b.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<len { v = v << 8 | UInt32(b[i + k]) }
        return (v, len)
    }

    /// Variable-size integer without its marker; nil value for the reserved "unknown size".
    static func vint(_ b: [UInt8], at i: Int) -> (Int64?, Int)? {
        guard i >= 0, i < b.count, b[i] != 0 else { return nil }
        let len = b[i].leadingZeroBitCount + 1
        guard i + len <= b.count else { return nil }
        var v = UInt64(b[i] & (0xFF >> len))
        for k in 1..<len { v = v << 8 | UInt64(b[i + k]) }
        if v == (UInt64(1) << (7 * UInt64(len))) - 1 { return (nil, len) }
        return v > UInt64(Int64.max) ? nil : (Int64(v), len)
    }

    static func children(_ b: [UInt8], _ range: Range<Int>) -> [(id: UInt32, data: Range<Int>)] {
        var out: [(id: UInt32, data: Range<Int>)] = []
        var i = range.lowerBound
        while i < range.upperBound, let (id, il) = elementID(b, at: i), let (size, sl) = vint(b, at: i + il) {
            let s = i + il + sl
            let e = size.map { s + Int(clamping: $0) } ?? range.upperBound
            guard s <= range.upperBound, e <= range.upperBound, e >= s else { break }
            out.append((id, s..<e))
            i = e
        }
        return out
    }

    static func uint(_ b: ArraySlice<UInt8>) -> UInt64 { b.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } }

    static func float(_ b: ArraySlice<UInt8>) -> Double? {
        switch b.count {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(b))))
        case 8: return Double(bitPattern: uint(b))
        default: return nil
        }
    }

    static func string(_ b: ArraySlice<UInt8>) -> String { String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
}
