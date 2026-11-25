import Foundation

/// Matroska element IDs (marker bits included) used by the subtitle reader.
enum MKV {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x1853_8067

    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC

    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2AD7B1

    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let language: UInt32 = 0x22B59C
    static let languageIETF: UInt32 = 0x22B59D
    static let name: UInt32 = 0x536E
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingOrder: UInt32 = 0x5031
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255

    static let cluster: UInt32 = 0x1F43_B675
    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B

    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueClusterPosition: UInt32 = 0xF1

    static let tags: UInt32 = 0x1254_C367
    static let chapters: UInt32 = 0x1043_A770
    static let attachments: UInt32 = 0x1941_A469
    static let attachedFile: UInt32 = 0x61A7
    static let fileName: UInt32 = 0x466E
    static let fileMimeType: UInt32 = 0x4660
    static let fileData: UInt32 = 0x465C

    /// Elements that end an unknown-size cluster when they appear in its place.
    static let segmentChildren: Set<UInt32> = [seekHead, info, tracks, cluster, cues, tags, chapters, attachments, ebml, segment]
}

/// EBML primitives over in-memory bytes.
enum EBML {
    /// Element ID (marker kept) and its encoded length.
    static func id(_ b: [UInt8], at i: Int) -> (id: UInt32, length: Int)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let len = b[i].leadingZeroBitCount + 1
        guard len <= 4, i + len <= b.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<len { v = v << 8 | UInt32(b[i + k]) }
        return (v, len)
    }

    /// Variable-size integer with the marker removed; nil `value` means the reserved "unknown" size.
    static func vint(_ b: [UInt8], at i: Int) -> (value: Int64?, length: Int)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let len = b[i].leadingZeroBitCount + 1
        guard i + len <= b.count else { return nil }
        var v = UInt64(b[i] & (0xFF >> len))
        for k in 1..<len { v = v << 8 | UInt64(b[i + k]) }
        let allOnes = (UInt64(1) << (7 * UInt64(len))) - 1
        if v == allOnes { return (nil, len) }
        return v > UInt64(Int64.max) ? nil : (Int64(v), len)
    }

    static func uint(_ b: ArraySlice<UInt8>) -> UInt64 {
        b.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func string(_ b: ArraySlice<UInt8>) -> String {
        String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Direct children of the master element payload `range`. Unknown sizes run to the end of `range`.
    static func children(_ b: [UInt8], in range: Range<Int>) -> [(id: UInt32, data: Range<Int>)] {
        var out: [(id: UInt32, data: Range<Int>)] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard let (id, il) = id(b, at: i), let (size, sl) = vint(b, at: i + il) else { break }
            let start = i + il + sl
            guard start <= range.upperBound else { break }
            let end = size.map { start + Int(clamping: $0) } ?? range.upperBound
            guard end <= range.upperBound, end >= start else { break }
            out.append((id, start..<end))
            i = end
        }
        return out
    }
}

/// An element located in the file: where it starts, where its payload starts, and its payload size.
struct ElementHeader {
    let id: UInt32
    let offset: Int64
    let dataStart: Int64
    /// Nil for unknown-size elements (live-written segments and clusters).
    let size: Int64?

    var end: Int64? { size.map { dataStart + $0 } }
}

/// A few recently read fixed-size chunks of the file.
struct ChunkCache {
    static let chunkSize = 16 * 1024
    private let capacity: Int
    private var chunks: [(index: Int64, bytes: [UInt8])] = []

    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ index: Int64) -> [UInt8]? {
        guard let i = chunks.firstIndex(where: { $0.index == index }) else { return nil }
        let c = chunks.remove(at: i)
        chunks.append(c)
        return c.bytes
    }

    mutating func put(_ index: Int64, _ bytes: [UInt8]) {
        chunks.removeAll { $0.index == index }
        chunks.append((index, bytes))
        if chunks.count > capacity { chunks.removeFirst() }
    }
}
