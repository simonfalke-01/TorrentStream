import Foundation
@testable import SubtitleKit

/// Minimal EBML/Matroska writer used to synthesize test files.
enum EBMLWriter {
    static func id(_ id: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var v = id
        while v > 0 { out.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return out
    }

    static func size(_ n: Int) -> [UInt8] {
        var len = 1
        while len < 8 && n >= (1 << (7 * len)) - 1 { len += 1 }
        return fixedSize(n, width: len)
    }

    static func fixedSize(_ n: Int, width: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width)
        var v = n
        for i in (0..<width).reversed() { out[i] = UInt8(v & 0xFF); v >>= 8 }
        out[0] |= UInt8(0x80 >> (width - 1))
        return out
    }

    static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    static func element(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] { self.id(id) + size(payload.count) + payload }
    static func master(_ id: UInt32, _ children: [[UInt8]]) -> [UInt8] { element(id, children.flatMap { $0 }) }
    static func string(_ id: UInt32, _ s: String) -> [UInt8] { element(id, Array(s.utf8)) }

    static func uint(_ id: UInt32, _ v: UInt64, width: Int? = nil) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        if let w = width { bytes = [UInt8](repeating: 0, count: max(0, w - bytes.count)) + bytes }
        return element(id, bytes)
    }

    /// Block/SimpleBlock payload: track number, signed relative timestamp, flags, frame.
    static func blockBody(track: Int, relative: Int16, flags: UInt8, frame: [UInt8]) -> [UInt8] {
        let r = UInt16(bitPattern: relative)
        return size(track) + [UInt8(r >> 8), UInt8(r & 0xFF), flags] + frame
    }
}

/// A synthetic Matroska file: a video track, an S_TEXT/UTF8 track (2) and an S_TEXT/ASS track (3), with
/// clusters every 10 s. Cluster k holds, in seconds:
/// - track 2: "Line k\nsecond" at 10k+1...10k+3 (BlockGroup) and "Line k simple" at 10k+6 (SimpleBlock, no duration)
/// - track 3: "Hello k\nworld" at 10k+2...10k+4, plus a duplicate layer and two sign events that are filtered out.
struct MKVFixture {
    var unknownSegmentSize = false
    var unknownClusterSize = false
    var includeCues = true
    var timestampScale: UInt64 = 1_000_000
    var clusterCount = 6
    var videoFrameSize = 40_000
    /// Prefix removed from track 2 frames and declared as ContentCompAlgo 3 settings.
    var strippedHeader: [UInt8]?
    /// Track 3 frames are stored reversed and declared as zlib (ContentCompAlgo 0).
    var fakeZlibASS = false
    var docType = "matroska"

    private(set) var data = Data()
    private(set) var clusterOffsets: [Int] = []
    private(set) var cuesOffset: Int?

    typealias W = EBMLWriter

    init(_ configure: (inout MKVFixture) -> Void = { _ in }) {
        configure(&self)
        build()
    }

    private func ticks(_ ms: Int) -> Int { ms * 1_000_000 / Int(timestampScale) }

    private func seekHead(info: Int, tracks: Int, cues: Int) -> [UInt8] {
        var seeks: [[UInt8]] = [
            W.master(MKV.seek, [W.element(MKV.seekID, W.id(MKV.info)), W.uint(MKV.seekPosition, UInt64(info), width: 8)]),
            W.master(MKV.seek, [W.element(MKV.seekID, W.id(MKV.tracks)), W.uint(MKV.seekPosition, UInt64(tracks), width: 8)]),
        ]
        if includeCues {
            seeks.append(W.master(MKV.seek, [W.element(MKV.seekID, W.id(MKV.cues)), W.uint(MKV.seekPosition, UInt64(cues), width: 8)]))
        }
        return W.master(MKV.seekHead, seeks)
    }

    private func encodings(algo: UInt64, settings: [UInt8]?) -> [UInt8] {
        var compression = [W.uint(MKV.contentCompAlgo, algo)]
        if let s = settings { compression.append(W.element(MKV.contentCompSettings, s)) }
        return W.master(MKV.contentEncodings, [W.master(MKV.contentEncoding, [
            W.uint(MKV.contentEncodingOrder, 0), W.uint(MKV.contentEncodingScope, 1), W.uint(MKV.contentEncodingType, 0),
            W.master(MKV.contentCompression, compression),
        ])])
    }

    private func tracks() -> [UInt8] {
        let video = W.master(MKV.trackEntry, [
            W.uint(MKV.trackNumber, 1), W.uint(0x73C5, 101), W.uint(0x83, 1), W.string(MKV.codecID, "V_MPEG4/ISO/AVC"),
            W.string(MKV.language, "und"),
        ])
        var srt: [[UInt8]] = [
            W.uint(MKV.trackNumber, 2), W.uint(0x73C5, 102), W.uint(0x83, 0x11), W.string(MKV.codecID, "S_TEXT/UTF8"),
            W.string(MKV.language, "eng"), W.string(MKV.name, "Full"),
        ]
        if let h = strippedHeader { srt.append(encodings(algo: 3, settings: h)) }
        var ass: [[UInt8]] = [
            W.uint(MKV.trackNumber, 3), W.uint(0x73C5, 103), W.uint(0x83, 0x11), W.string(MKV.codecID, "S_TEXT/ASS"),
            W.string(MKV.language, "jpn"), W.string(MKV.languageIETF, "ja-JP"), W.string(MKV.name, "Signs & Songs"),
            W.uint(MKV.flagDefault, 0), W.uint(MKV.flagForced, 1),
            W.string(0x63A2, "[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: Default,Arial\n\n[Events]\nFormat: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"),
        ]
        if fakeZlibASS { ass.append(encodings(algo: 0, settings: nil)) }
        return W.master(MKV.tracks, [video, W.master(MKV.trackEntry, srt), W.master(MKV.trackEntry, ass)])
    }

    private func blockGroup(track: Int, relativeMs: Int, durationMs: Int, frame: [UInt8]) -> [UInt8] {
        W.master(MKV.blockGroup, [
            W.element(MKV.block, W.blockBody(track: track, relative: Int16(ticks(relativeMs)), flags: 0, frame: frame)),
            W.uint(MKV.blockDuration, UInt64(ticks(durationMs))),
        ])
    }

    private func simpleBlock(track: Int, relativeMs: Int, flags: UInt8 = 0x80, frame: [UInt8]) -> [UInt8] {
        W.element(MKV.simpleBlock, W.blockBody(track: track, relative: Int16(ticks(relativeMs)), flags: flags, frame: frame))
    }

    private func srtFrame(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard let h = strippedHeader else { return bytes }
        precondition(bytes.starts(with: h))
        return Array(bytes.dropFirst(h.count))
    }

    private func assFrame(_ text: String) -> [UInt8] {
        fakeZlibASS ? Array(text.utf8).reversed() : Array(text.utf8)
    }

    private func cluster(_ k: Int) -> [UInt8] {
        let video = { (seed: Int) in [UInt8]((0..<videoFrameSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }) }
        var children: [[UInt8]] = [
            W.element(0xBF, [1, 2, 3, 4]),
            W.uint(MKV.timestamp, UInt64(ticks(k * 10_000))),
            simpleBlock(track: 1, relativeMs: 0, frame: video(k)),
            blockGroup(track: 2, relativeMs: 1000, durationMs: 2000, frame: srtFrame("<i>Line \(k)</i>\r\nsecond")),
            simpleBlock(track: 1, relativeMs: 2000, flags: 0, frame: video(k + 1)),
            blockGroup(track: 3, relativeMs: 2000, durationMs: 2000, frame: assFrame("\(4 * k),0,Default,,0,0,0,,Hello {\\i1}\(k){\\i0}\\Nworld")),
            blockGroup(track: 3, relativeMs: 2000, durationMs: 2000, frame: assFrame("\(4 * k + 1),1,Default,,0,0,0,,Hello \(k)\\Nworld")),
            blockGroup(track: 3, relativeMs: 2000, durationMs: 2000, frame: assFrame("\(4 * k + 2),0,Signs,,0,0,0,,Sign text")),
            blockGroup(track: 3, relativeMs: 2000, durationMs: 2000, frame: assFrame("\(4 * k + 3),0,Default,,0,0,0,,{\\pos(10,10)}Positioned")),
            W.element(0xEC, [UInt8](repeating: 0, count: 7)),
            simpleBlock(track: 1, relativeMs: 5000, flags: 0, frame: video(k + 2)),
            simpleBlock(track: 2, relativeMs: 6000, frame: srtFrame("<i>Line \(k)</i> simple")),
        ]
        if k == 0 {
            // Xiph-laced block on a subtitle track: skipped, must not crash.
            children.append(simpleBlock(track: 2, relativeMs: 7000, flags: 0x82, frame: [1, 3, 0x41, 0x42, 0x43, 0x44]))
        }
        let payload = children.flatMap { $0 }
        return W.id(MKV.cluster) + (unknownClusterSize ? W.unknownSize : W.size(payload.count)) + payload
    }

    private mutating func build() {
        let ebmlHeader = W.master(MKV.ebml, [
            W.uint(0x4286, 1), W.uint(0x42F7, 1), W.uint(0x42F2, 4), W.uint(0x42F3, 8),
            W.string(MKV.docType, docType), W.uint(0x4287, 4), W.uint(0x4285, 2),
        ])
        let void = W.element(0xEC, [UInt8](repeating: 0, count: 20))
        let info = W.master(MKV.info, [W.uint(MKV.timestampScale, timestampScale), W.string(0x4D80, "fixture")])
        let tracks = tracks()
        let headSize = seekHead(info: 0, tracks: 0, cues: 0).count + void.count
        let infoPos = headSize
        let tracksPos = infoPos + info.count
        var pos = tracksPos + tracks.count
        var clusters: [UInt8] = []
        var relativeClusters: [Int] = []
        for k in 0..<clusterCount {
            relativeClusters.append(pos)
            let c = cluster(k)
            clusters += c
            pos += c.count
        }
        let cuesPos = pos
        let cuePoints = relativeClusters.enumerated().map { k, p in
            W.master(MKV.cuePoint, [
                W.uint(MKV.cueTime, UInt64(ticks(k * 10_000))),
                W.master(MKV.cueTrackPositions, [W.uint(0xF7, 1), W.uint(MKV.cueClusterPosition, UInt64(p))]),
            ])
        }
        var segment = seekHead(info: infoPos, tracks: tracksPos, cues: cuesPos) + void + info + tracks + clusters
        if includeCues { segment += W.master(MKV.cues, cuePoints) }
        segment += W.master(MKV.tags, [W.master(0x7373, [W.string(0x45A3, "x")])])
        let segmentHeader = W.id(MKV.segment) + (unknownSegmentSize ? W.unknownSize : W.fixedSize(segment.count, width: 8))
        let segmentStart = ebmlHeader.count + segmentHeader.count
        data = Data(ebmlHeader + segmentHeader + segment)
        clusterOffsets = relativeClusters.map { segmentStart + $0 }
        cuesOffset = includeCues ? segmentStart + cuesPos : nil
    }
}

/// Serves fixture bytes for the ranges marked downloaded and records every request.
final class FixtureSource: @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var available: [Range<Int>]
    private(set) var requests: [(offset: Int64, length: Int)] = []

    init(_ data: Data, available: [Range<Int>]? = nil) {
        self.data = data
        self.available = available ?? [0..<data.count]
    }

    func setAvailable(_ ranges: [Range<Int>]) {
        lock.lock(); defer { lock.unlock() }
        available = ranges
    }

    var maxRequest: Int { lock.lock(); defer { lock.unlock() }; return requests.map(\.length).max() ?? 0 }
    var totalRequested: Int { lock.lock(); defer { lock.unlock() }; return requests.map(\.length).reduce(0, +) }

    func read(_ offset: Int64, _ length: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        requests.append((offset, length))
        let r = Int(offset)..<Int(offset) + length
        guard r.lowerBound >= 0, r.upperBound <= data.count,
              available.contains(where: { $0.lowerBound <= r.lowerBound && r.upperBound <= $0.upperBound }) else { return nil }
        return data.subdata(in: r)
    }

    func reader(decompress: (@Sendable (Data) -> Data?)? = nil) -> MatroskaSubtitleReader {
        MatroskaSubtitleReader(fileLength: Int64(data.count), decompress: decompress) { [self] offset, length in
            read(offset, length)
        }
    }
}
