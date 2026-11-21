import Foundation
@testable import SkipKit

/// Deterministic pseudo-random numbers (SplitMix64), so fixtures are the same on every run.
struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Builds prints frame by frame: unrelated stretches get fresh random codes, a shared song the same codes with a
/// few bits flipped per frame, as a re-encode would.
struct PrintBuilder {
    var codes: [UInt32] = []
    var rng: Seeded

    init(seed: UInt64) { rng = Seeded(seed) }

    mutating func noise(_ seconds: Double) {
        for _ in 0..<Int(seconds * AudioPrint.frameRate) { codes.append(UInt32(truncatingIfNeeded: rng.next())) }
    }

    mutating func song(_ song: [UInt32], from: Double = 0, to: Double? = nil) {
        let a = Int(from * AudioPrint.frameRate), b = to.map { Int($0 * AudioPrint.frameRate) } ?? song.count
        for c in song[a..<b] {
            var flipped = c
            for _ in 0..<3 { flipped ^= 1 << UInt32(rng.next() % 32) }
            codes.append(flipped)
        }
    }

    func print(decodedUpTo seconds: Double? = nil) -> AudioPrint {
        let n = seconds.map { min(codes.count, Int($0 * AudioPrint.frameRate)) } ?? codes.count
        let states = (0..<codes.count).map { $0 < n ? AudioPrint.FrameState.known : .unknown }
        return AudioPrint(codes: codes, states: states)
    }

    var duration: Double { Double(codes.count) / AudioPrint.frameRate }

    static func song(_ seconds: Double, seed: UInt64) -> [UInt32] {
        var b = PrintBuilder(seed: seed)
        b.noise(seconds)
        return b.codes
    }
}

/// Writes just enough Matroska for the audio demuxer: header, info, tracks, cues and clusters.
enum MKVWriter {
    static func id(_ v: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var x = v
        while x > 0 { out.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return out
    }

    static func size(_ n: Int) -> [UInt8] {
        // Always 8 bytes, so offsets are easy to predict.
        var out: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { out.append(UInt8((n >> shift) & 0xFF)) }
        return out
    }

    static func element(_ i: UInt32, _ payload: [UInt8]) -> [UInt8] { id(i) + size(payload.count) + payload }

    static func uint(_ i: UInt32, _ v: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return element(i, bytes)
    }

    static func float(_ i: UInt32, _ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return element(i, (0..<8).map { UInt8((bits >> (56 - 8 * UInt64($0))) & 0xFF) })
    }

    static func string(_ i: UInt32, _ s: String) -> [UInt8] { element(i, Array(s.utf8)) }

    typealias ID = MatroskaAudio.ID

    /// A file with a video track (1) and a 16-bit little-endian PCM track (2) at `rate`, mono. Audio goes in
    /// clusters of `clusterSeconds`, as one block of `lacedFrames` frames laced the given way (0 none, 1 Xiph,
    /// 2 fixed, 3 EBML), with a video block in between. Returns the bytes and the cluster offsets.
    static func file(samples: [Int16], rate: Int, clusterSeconds: Double = 1, lacing: UInt8 = 0,
                     lacedFrames: Int = 4, withCues: Bool = true) -> (bytes: [UInt8], clusters: [Int]) {
        let header = element(ID.ebml, string(0x4282, "matroska"))
        let info = element(ID.info, uint(ID.timestampScale, 1_000_000) + float(ID.duration, Double(samples.count) / Double(rate) * 1000))
        let video = element(ID.trackEntry, uint(ID.trackNumber, 1) + uint(ID.trackType, 1) + string(ID.codecID, "V_MPEG4/ISO/AVC"))
        let audio = element(ID.trackEntry, uint(ID.trackNumber, 2) + uint(ID.trackType, 2) + string(ID.codecID, "A_PCM/INT/LIT")
            + element(ID.audio, float(ID.samplingFrequency, Double(rate)) + uint(ID.channels, 1) + uint(ID.bitDepth, 16)))
        let tracks = element(ID.tracks, video + audio)

        let perCluster = Int(clusterSeconds * Double(rate))
        var clusters: [[UInt8]] = []
        var times: [UInt64] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + perCluster)
            let ms = UInt64(Double(start) / Double(rate) * 1000)
            times.append(ms)
            var body = uint(ID.timestamp, ms)
            body += element(ID.simpleBlock, [0x81, 0, 0, 0x80, 0xAA, 0xBB])   // video, track 1
            let chunk = Array(samples[start..<end])
            body += element(ID.simpleBlock, audioBlock(chunk, lacing: lacing, frames: lacedFrames))
            clusters.append(element(ID.cluster, body))
            start = end
        }
        // Layout: header, segment { seekhead, info, tracks, clusters..., cues }.
        func seekHead(cuesAt: Int) -> [UInt8] {
            element(ID.seekHead, element(ID.seek, element(ID.seekID, id(ID.cues)) + element(ID.seekPosition, be64(cuesAt))))
        }
        let pre = seekHead(cuesAt: 0).count + info.count + tracks.count
        var clusterOffsets: [Int] = []
        var position = pre
        for c in clusters { clusterOffsets.append(position); position += c.count }
        let cuesAt = position
        var cuePoints: [UInt8] = []
        for (t, o) in zip(times, clusterOffsets) {
            cuePoints += element(ID.cuePoint, uint(ID.cueTime, t) + element(ID.cueTrackPositions, uint(0xF7, 1) + uint(ID.cueClusterPosition, UInt64(o))))
        }
        let cues = element(ID.cues, cuePoints)
        var segmentBody = (withCues ? seekHead(cuesAt: cuesAt) : element(0xEC, [UInt8](repeating: 0, count: seekHead(cuesAt: 0).count - 9))) + info + tracks
        for c in clusters { segmentBody += c }
        if withCues { segmentBody += cues }
        let segmentHeader = id(ID.segment) + size(segmentBody.count)
        let base = header.count + segmentHeader.count
        return (header + segmentHeader + segmentBody, clusterOffsets.map { $0 + base })
    }

    static func be64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - 8 * $0)) & 0xFF) } }

    static func audioBlock(_ samples: [Int16], lacing: UInt8, frames: Int) -> [UInt8] {
        let bytes = samples.flatMap { [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)] }
        var head: [UInt8] = [0x82, 0, 0, 0x80 | (lacing << 1)]
        guard lacing != 0 else { return head + bytes }
        // Split into `frames` frames of whole samples; fixed lacing needs equal sizes.
        let n = frames
        var sizes: [Int] = []
        let total = samples.count
        for k in 0..<n {
            let a = lacing == 2 ? total / n * k : total * k / n
            let b = lacing == 2 ? (k == n - 1 ? total : total / n * (k + 1)) : total * (k + 1) / n
            sizes.append((b - a) * 2)
        }
        if lacing == 2 && Set(sizes).count > 1 { fatalError("fixed lacing needs equal frames") }
        head.append(UInt8(n - 1))
        switch lacing {
        case 1:
            for s in sizes.dropLast() {
                var r = s
                while r >= 255 { head.append(255); r -= 255 }
                head.append(UInt8(r))
            }
        case 3:
            head += vint(UInt64(sizes[0]))
            for k in 1..<(n - 1) {
                let diff = sizes[k] - sizes[k - 1]
                // Two-byte signed vint: bias 2^13 - 1.
                let raw = UInt64(diff + 8191)
                head += [0x40 | UInt8(raw >> 8), UInt8(raw & 0xFF)]
            }
        default:
            break
        }
        return head + bytes
    }

    static func vint(_ v: UInt64) -> [UInt8] {
        // Four-byte vint.
        [0x10 | UInt8((v >> 24) & 0x0F), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}

/// Audio that fingerprints like music: a new random chord every quarter second over a little noise.
func music(seconds: Double, rate: Int, seed: UInt64) -> [Float] {
    var rng = Seeded(seed)
    let n = Int(seconds * Double(rate))
    var out = [Float](repeating: 0, count: n)
    let step = rate / 4
    var i = 0
    while i < n {
        let tones = (0..<3).map { _ in 300 + rng.unit() * 2500 }
        for k in i..<min(n, i + step) {
            var s = 0.0
            for f in tones { s += sin(2 * .pi * f * Double(k) / Double(rate)) }
            out[k] = Float(s / 3 * 0.5 + (rng.unit() - 0.5) * 0.1)
        }
        i += step
    }
    return out
}

/// Reads from an in-memory file, with only the byte ranges in `available` readable.
final class FakeFile: @unchecked Sendable {
    let bytes: [UInt8]
    private let lock = NSLock()
    private var available: [Range<Int>]

    init(_ bytes: [UInt8], available: [Range<Int>]? = nil) {
        self.bytes = bytes
        self.available = available ?? [0..<bytes.count]
    }

    func make(available ranges: [Range<Int>]) { lock.withLock { available = ranges } }

    var reader: ByteReader {
        { [self] offset, length in
            let r = Int(offset)..<(Int(offset) + length)
            let ok = lock.withLock { available.contains { $0.lowerBound <= r.lowerBound && r.upperBound <= $0.upperBound } }
            guard ok, r.upperBound <= bytes.count else { return nil }
            return Data(bytes[r])
        }
    }
}
