import Foundation

/// Video sync samples of a (non-fragmented) MP4/MOV file from its `moov` sample tables, and the bytes of any one of
/// them. Reads the top-level box headers to find `moov` (which may sit after `mdat`), then the whole `moov`.
public struct MP4Index: KeyframeIndex {
    static let maxMoov: Int64 = 64 * 1024 * 1024
    static let maxSample: Int64 = 16 * 1024 * 1024

    public let video: VideoTrack
    public let duration: Double?
    public let keyframes: [Keyframe]
    let fileLength: Int64
    let read: ReadBytes

    public static func load(fileLength: Int64, read: @escaping ReadBytes) async throws -> MP4Index {
        let r = ByteReader(fileLength: fileLength, read: read)
        var pos: Int64 = 0
        var moov: [UInt8]?
        while pos + 8 <= fileLength {
            let h = try await r.bytes(at: pos, count: 16)
            guard h.count >= 8 else { break }
            var size = Int64(be32(h, 0))
            let type = fourCC(h, 4)
            var headerLength: Int64 = 8
            if size == 1 {
                guard h.count >= 16 else { break }
                size = Int64(clamping: be64(h, 8))
                headerLength = 16
            } else if size == 0 {
                size = fileLength - pos
            }
            guard size >= headerLength else { throw MediaIndexError.malformed("box size at \(pos)") }
            if type == "moov" {
                guard size - headerLength <= maxMoov else { throw MediaIndexError.malformed("moov too large") }
                moov = try await r.bytes(at: pos + headerLength, count: Int(size - headerLength))
                break
            }
            pos += size
        }
        guard let m = moov else { throw MediaIndexError.noKeyframeIndex }
        return try parse(moov: m, fileLength: fileLength, read: read)
    }

    // MARK: parsing

    static func parse(moov m: [UInt8], fileLength: Int64, read: @escaping ReadBytes) throws -> MP4Index {
        var movieTimescale: UInt32 = 0
        if let mvhd = child(m, 0..<m.count, "mvhd"), mvhd.count >= 20 {
            movieTimescale = m[mvhd.lowerBound] == 1 ? be32(m, mvhd.lowerBound + 20) : be32(m, mvhd.lowerBound + 12)
        }
        for trak in children(m, 0..<m.count) where trak.type == "trak" {
            let t = trak.range
            guard let mdia = child(m, t, "mdia"), let hdlr = child(m, mdia, "hdlr"), hdlr.count >= 12,
                  fourCC(m, hdlr.lowerBound + 8) == "vide",
                  let mdhd = child(m, mdia, "mdhd"), let minf = child(m, mdia, "minf"), let stbl = child(m, minf, "stbl"),
                  let stsd = child(m, stbl, "stsd") else { continue }
            let v1 = m[mdhd.lowerBound] == 1
            let timescale = v1 ? be32(m, mdhd.lowerBound + 20) : be32(m, mdhd.lowerBound + 12)
            let mediaDuration = v1 ? be64(m, mdhd.lowerBound + 24) : UInt64(be32(m, mdhd.lowerBound + 16))
            guard timescale > 0, let video = sampleEntry(m, stsd) else { continue }
            let duration = Double(mediaDuration) / Double(timescale)

            // Sample tables.
            guard let stts = child(m, stbl, "stts"), let stsc = child(m, stbl, "stsc") else { throw MediaIndexError.noKeyframeIndex }
            let deltas = entries(m, stts, width: 2).map { (count: Int($0[0]), delta: Int64($0[1])) }
            let compositions = child(m, stbl, "ctts").map { r in
                entries(m, r, width: 2).map { (count: Int($0[0]), offset: Int64(Int32(bitPattern: $0[1]))) }
            } ?? []
            let chunks = entries(m, stsc, width: 3).map { (first: Int($0[0]), perChunk: Int($0[1])) }
            var chunkOffsets: [Int64] = []
            if let stco = child(m, stbl, "stco") {
                chunkOffsets = entries(m, stco, width: 1).map { Int64($0[0]) }
            } else if let co64 = child(m, stbl, "co64") {
                let n = Int(be32(m, co64.lowerBound + 4))
                chunkOffsets = (0..<n).compactMap { i in
                    let at = co64.lowerBound + 8 + i * 8
                    return at + 8 <= co64.upperBound ? Int64(clamping: be64(m, at)) : nil
                }
            }
            var sizes: [Int64] = []
            var uniformSize: Int64 = 0
            var sampleCount = 0
            if let stsz = child(m, stbl, "stsz"), stsz.count >= 12 {
                uniformSize = Int64(be32(m, stsz.lowerBound + 4))
                sampleCount = Int(be32(m, stsz.lowerBound + 8))
                if uniformSize == 0 {
                    let n = min(sampleCount, (stsz.count - 12) / 4)
                    sizes = (0..<n).map { Int64(be32(m, stsz.lowerBound + 12 + $0 * 4)) }
                    sampleCount = n
                }
            }
            guard sampleCount > 0, !chunkOffsets.isEmpty, !chunks.isEmpty else { throw MediaIndexError.noKeyframeIndex }
            // 1-based sync sample numbers; every sample is one when there's no stss.
            let sync: [Int] = child(m, stbl, "stss").map { r in entries(m, r, width: 1).map { Int($0[0]) } }
                ?? Array(1...sampleCount)
            guard !sync.isEmpty else { throw MediaIndexError.noKeyframeIndex }

            // Presentation shift from the edit list: the first edit's media time, plus any leading empty edit.
            var shift: Int64 = 0
            var delay = 0.0
            if let edts = child(m, t, "edts"), let elst = child(m, edts, "elst"), elst.count >= 8 {
                let v = m[elst.lowerBound]
                let n = Int(be32(m, elst.lowerBound + 4))
                var at = elst.lowerBound + 8
                for _ in 0..<n {
                    let entrySize = v == 1 ? 20 : 12
                    guard at + entrySize <= elst.upperBound else { break }
                    let segmentDuration = v == 1 ? Int64(clamping: be64(m, at)) : Int64(be32(m, at))
                    let mediaTime = v == 1 ? Int64(bitPattern: be64(m, at + 8)) : Int64(Int32(bitPattern: be32(m, at + 4)))
                    at += entrySize
                    if mediaTime == -1 {
                        if movieTimescale > 0 { delay += Double(segmentDuration) / Double(movieTimescale) }
                        continue
                    }
                    shift = mediaTime
                    break
                }
            }

            let wanted = Set(sync)
            var keyframes: [Keyframe] = []
            keyframes.reserveCapacity(sync.count)
            var sample = 1
            var decodeTime: Int64 = 0
            var sttsEntry = 0, sttsLeft = deltas.first?.count ?? 0
            var cttsEntry = 0, cttsLeft = compositions.first?.count ?? 0
            var chunkEntry = 0
            chunkLoop: for chunk in 1...chunkOffsets.count {
                while chunkEntry + 1 < chunks.count, chunks[chunkEntry + 1].first <= chunk { chunkEntry += 1 }
                var offset = chunkOffsets[chunk - 1]
                for _ in 0..<chunks[chunkEntry].perChunk {
                    guard sample <= sampleCount else { break chunkLoop }
                    let size = uniformSize > 0 ? uniformSize : sizes[sample - 1]
                    if wanted.contains(sample) {
                        let cts = decodeTime + (cttsEntry < compositions.count ? compositions[cttsEntry].offset : 0)
                        let time = Double(cts - shift) / Double(timescale) + delay
                        keyframes.append(Keyframe(time: time, clusterOffset: offset, relativeOffset: nil, size: size))
                    }
                    offset += size
                    // Advance the time tables.
                    while sttsLeft == 0, sttsEntry + 1 < deltas.count { sttsEntry += 1; sttsLeft = deltas[sttsEntry].count }
                    if sttsEntry < deltas.count { decodeTime += deltas[sttsEntry].delta; sttsLeft -= 1 }
                    if cttsEntry < compositions.count {
                        cttsLeft -= 1
                        while cttsLeft <= 0, cttsEntry + 1 < compositions.count { cttsEntry += 1; cttsLeft = compositions[cttsEntry].count }
                        if cttsLeft <= 0 { cttsEntry = compositions.count }
                    }
                    sample += 1
                }
            }
            keyframes = keyframes.filter { $0.clusterOffset >= 0 && $0.clusterOffset + ($0.size ?? 0) <= fileLength }
            keyframes.sort { $0.time < $1.time }
            guard !keyframes.isEmpty else { throw MediaIndexError.noKeyframeIndex }
            return MP4Index(video: video, duration: duration > 0 ? duration : nil, keyframes: keyframes,
                            fileLength: fileLength, read: read)
        }
        throw MediaIndexError.noVideoTrack
    }

    /// The first sample entry of `stsd`: codec, size and decoder configuration.
    static func sampleEntry(_ m: [UInt8], _ stsd: Range<Int>) -> VideoTrack? {
        let start = stsd.lowerBound + 8
        guard start + 8 <= stsd.upperBound else { return nil }
        let size = Int(be32(m, start))
        let type = fourCC(m, start + 4)
        let end = min(stsd.upperBound, start + size)
        // Box header 8, SampleEntry 8, VisualSampleEntry 70.
        guard size >= 86, end - start >= 86 else { return nil }
        let width = Int(be16(m, start + 32)), height = Int(be16(m, start + 34))
        let codec: VideoCodec
        let configType: String
        switch type {
        case "avc1", "avc3": codec = .h264; configType = "avcC"
        case "hvc1", "hev1": codec = .hevc; configType = "hvcC"
        case "av01": codec = .av1; configType = "av1C"
        case "vp09": codec = .vp9; configType = "vpcC"
        default: codec = .other; configType = ""
        }
        let config = child(m, (start + 86)..<end, configType).map { Data(m[$0]) } ?? Data()
        return VideoTrack(codec: codec, codecID: type, configuration: config, width: width, height: height)
    }

    // MARK: frames

    public func estimatedRange(ofKeyframe index: Int) -> Range<Int64> {
        let k = keyframes[index]
        return k.clusterOffset..<(k.clusterOffset + max(1, k.size ?? 1))
    }

    public func keyframeData(at index: Int, read override: ReadBytes?) async throws -> (time: Double, data: Data) {
        guard keyframes.indices.contains(index) else { throw MediaIndexError.noKeyframeIndex }
        let k = keyframes[index]
        guard let size = k.size, size > 0, size <= Self.maxSample else { throw MediaIndexError.malformed("sample size") }
        let r = ByteReader(fileLength: fileLength, read: override ?? read)
        let b = try await r.bytes(at: k.clusterOffset, count: Int(size))
        guard b.count == Int(size) else { throw MediaIndexError.dataUnavailable }
        return (k.time, Data(b))
    }

    // MARK: box helpers

    static func children(_ b: [UInt8], _ range: Range<Int>) -> [(type: String, range: Range<Int>)] {
        var out: [(type: String, range: Range<Int>)] = []
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = Int(be32(b, i))
            var header = 8
            if size == 1 {
                guard i + 16 <= range.upperBound else { break }
                size = Int(clamping: be64(b, i + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, i + size <= range.upperBound else { break }
            out.append((fourCC(b, i + 4), (i + header)..<(i + size)))
            i += size
        }
        return out
    }

    static func child(_ b: [UInt8], _ range: Range<Int>, _ type: String) -> Range<Int>? {
        children(b, range).first { $0.type == type }?.range
    }

    /// Full-box table: version/flags, entry count, then `width` 32-bit fields per entry.
    static func entries(_ b: [UInt8], _ r: Range<Int>, width: Int) -> [[UInt32]] {
        guard r.count >= 8 else { return [] }
        let n = Int(be32(b, r.lowerBound + 4))
        let available = (r.count - 8) / (4 * width)
        return (0..<min(n, available)).map { i in
            (0..<width).map { be32(b, r.lowerBound + 8 + (i * width + $0) * 4) }
        }
    }

    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
    }

    static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }
}
