import Foundation

/// A compact fingerprint of an episode's audio, or of the parts of it decoded so far: one 32-bit code per frame,
/// `frameRate` frames a second, frame `k` describing the sound around `k / frameRate` seconds into the file.
///
/// Each bit says whether the energy difference between two neighbouring frequency bands (300–3000 Hz, log spaced)
/// rose or fell since the previous frame. The same recording gives nearly the same bits however it was encoded or
/// how loud it is, while unrelated sound agrees on about half of them — so the opening song of one episode can be
/// found in another by lining their codes up.
public struct AudioPrint: Sendable, Equatable {
    public static let frameRate: Double = 8

    public enum FrameState: UInt8, Sendable {
        /// Not decoded (yet).
        case unknown = 0
        case known = 1
        /// Decoded, but too quiet to compare.
        case quiet = 2
    }

    public private(set) var codes: [UInt32]
    public private(set) var states: [FrameState]

    public init() {
        codes = []
        states = []
    }

    public init(codes: [UInt32], states: [FrameState]) {
        precondition(codes.count == states.count)
        self.codes = codes
        self.states = states
    }

    public var frameCount: Int { codes.count }

    public static func frame(at seconds: Double) -> Int { Int((seconds * frameRate).rounded()) }
    public static func time(ofFrame frame: Int) -> Double { Double(frame) / frameRate }

    public mutating func set(_ frame: Int, code: UInt32, quiet: Bool) {
        guard frame >= 0 else { return }
        if frame >= codes.count {
            codes += repeatElement(0, count: frame + 1 - codes.count)
            states += repeatElement(.unknown, count: frame + 1 - states.count)
        }
        codes[frame] = code
        states[frame] = quiet ? .quiet : .known
    }

    public func isDecoded(_ frame: Int) -> Bool { frame >= 0 && frame < states.count && states[frame] != .unknown }

    /// Share of the frames between two times that have been decoded, 0...1.
    public func coverage(from start: Double, to end: Double) -> Double {
        let a = max(0, Self.frame(at: start)), b = Self.frame(at: end)
        guard b > a else { return 1 }
        var n = 0
        for f in a..<min(b, states.count) where states[f] != .unknown { n += 1 }
        return Double(n) / Double(b - a)
    }

    /// Seconds of audio decoded so far.
    public var decodedSeconds: Double { Double(states.lazy.filter { $0 != .unknown }.count) / Self.frameRate }

    /// Length in seconds of the longest undecoded stretch between two times. Audio decoded as a torrent downloads
    /// leaves short seams (a fraction of a second) wherever it was picked up out of order.
    public func longestGap(from start: Double, to end: Double) -> Double {
        let a = max(0, Self.frame(at: start)), b = Self.frame(at: end)
        var longest = 0, run = 0
        var f = a
        while f < b {
            if f >= states.count || states[f] == .unknown { run += 1; longest = max(longest, run) } else { run = 0 }
            f += 1
        }
        return Double(longest) / Self.frameRate
    }

    /// Frames from the first decoded one to the last; nil if none are.
    public var decodedRange: Range<Int>? {
        guard let first = states.firstIndex(where: { $0 != .unknown }),
              let last = states.lastIndex(where: { $0 != .unknown }) else { return nil }
        return first..<(last + 1)
    }
}

extension AudioPrint: Codable {
    private enum CodingKeys: String, CodingKey { case codes, states }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(Data.self, forKey: .codes)
        let st = try c.decode(Data.self, forKey: .states)
        guard raw.count == st.count * 4 else {
            throw DecodingError.dataCorruptedError(forKey: .codes, in: c, debugDescription: "codes and states differ in length")
        }
        var codes = [UInt32](repeating: 0, count: st.count)
        raw.withUnsafeBytes { p in
            for i in 0..<codes.count { codes[i] = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        }
        self.codes = codes
        states = st.map { FrameState(rawValue: $0) ?? .unknown }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw = Data(capacity: codes.count * 4)
        for code in codes { withUnsafeBytes(of: code.littleEndian) { raw.append(contentsOf: $0) } }
        try c.encode(raw, forKey: .codes)
        try c.encode(Data(states.map(\.rawValue)), forKey: .states)
    }
}

/// Turns decoded audio into `AudioPrint` frames.
public enum Fingerprinter {
    /// Audio is resampled to this rate before analysis.
    static let rate: Double = 8000
    static let window = 2048
    static let hop = Int(rate / AudioPrint.frameRate)
    static let bandCount = 33
    static let lowFrequency: Double = 300
    static let highFrequency: Double = 3000
    /// Frames whose summed band power is below this (about -80 dBFS) carry no usable bits.
    static let quietPower: Float = 1e-3

    /// Adds every frame that the mono `samples` (at `sampleRate`, the first one `startTime` seconds into the file)
    /// cover completely, along with the frame before it. Frames already in `print` are recomputed.
    public static func add(_ samples: [Float], sampleRate: Double, startTime: Double, to print: inout AudioPrint) {
        guard sampleRate > 0, !samples.isEmpty else { return }
        let x = resample(samples, from: sampleRate)
        let analyzer = BandAnalyzer.shared
        let half = Double(window / 2)
        // First and last frames whose window lies inside x.
        let first = Int(((startTime * rate + half) / Double(hop)).rounded(.up))
        let last = Int(((startTime * rate + Double(x.count) - half) / Double(hop)).rounded(.down))
        guard last > first else { return }
        var previous: [Float]?
        var scratch = BandAnalyzer.Scratch()
        x.withUnsafeBufferPointer { xp in
            for f in first...last {
                let begin = Int((Double(f * hop) - startTime * rate - half).rounded())
                guard begin >= 0, begin + window <= xp.count else { previous = nil; continue }
                let bands = analyzer.bands(xp, from: begin, scratch: &scratch)
                if let p = previous {
                    let quiet = bands.reduce(0, +) < quietPower || p.reduce(0, +) < quietPower
                    print.set(f, code: code(bands, previous: p), quiet: quiet)
                }
                previous = bands
            }
        }
    }

    static func code(_ e: [Float], previous p: [Float]) -> UInt32 {
        var c: UInt32 = 0
        for b in 0..<(bandCount - 1) where (e[b] - e[b + 1]) - (p[b] - p[b + 1]) > 0 {
            c |= 1 << UInt32(b)
        }
        return c
    }

    /// Mixes interleaved channels down to mono.
    public static func mono(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let n = interleaved.count / channels
        var out = [Float](repeating: 0, count: n)
        let scale = 1 / Float(channels)
        interleaved.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += p[i * channels + c] }
                out[i] = s * scale
            }
        }
        return out
    }

    /// `samples` at `rate`, low-pass filtered below 3.6 kHz first so higher sound doesn't fold into the bands.
    static func resample(_ samples: [Float], from inputRate: Double) -> [Float] {
        if abs(inputRate - rate) < 1 { return samples }
        let ratio = inputRate / rate
        let count = Int(Double(samples.count) / ratio)
        guard count > 0 else { return [] }
        let taps = lowPass(ratio: ratio)
        let half = taps.count / 2
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { x in
            taps.withUnsafeBufferPointer { h in
                for n in 0..<count {
                    let center = Int((Double(n) * ratio).rounded())
                    var acc: Float = 0
                    let lo = center - half
                    if lo >= 0 && lo + h.count <= x.count {
                        for k in 0..<h.count { acc += h[k] * x[lo + k] }
                    } else {
                        for k in 0..<h.count {
                            let i = lo + k
                            if i >= 0 && i < x.count { acc += h[k] * x[i] }
                        }
                    }
                    out[n] = acc
                }
            }
        }
        return out
    }

    /// Windowed-sinc low-pass for decimating by `ratio`, cutting off at 3.6 kHz.
    static func lowPass(ratio: Double) -> [Float] {
        let half = max(8, Int((4 * ratio).rounded(.up)))
        let cutoff = 3600 / (rate * ratio)
        var h = [Float](repeating: 0, count: 2 * half + 1)
        var sum: Double = 0
        for i in 0..<h.count {
            let m = Double(i - half)
            let sinc = m == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * m) / (.pi * m)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(h.count - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(h.count - 1))
            h[i] = Float(sinc * w)
            sum += sinc * w
        }
        for i in h.indices { h[i] = Float(Double(h[i]) / sum) }
        return h
    }
}

/// Band powers of one Hann-windowed frame.
final class BandAnalyzer: @unchecked Sendable {
    static let shared = BandAnalyzer()

    struct Scratch {
        var re = [Float](repeating: 0, count: Fingerprinter.window)
        var im = [Float](repeating: 0, count: Fingerprinter.window)
    }

    let n = Fingerprinter.window
    private let hann: [Float]
    private let fft: FFT
    /// First and one-past-last FFT bin of each band.
    private let bandBins: [(Int, Int)]

    init() {
        let n = Fingerprinter.window
        hann = (0..<n).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1))) }
        fft = FFT(size: n)
        let edges = (0...Fingerprinter.bandCount).map {
            Fingerprinter.lowFrequency * pow(Fingerprinter.highFrequency / Fingerprinter.lowFrequency,
                                              Double($0) / Double(Fingerprinter.bandCount))
        }
        let binHz = Fingerprinter.rate / Double(n)
        bandBins = (0..<Fingerprinter.bandCount).map { b in
            (Int((edges[b] / binHz).rounded(.up)), max(Int((edges[b] / binHz).rounded(.up)) + 1, Int((edges[b + 1] / binHz).rounded(.up))))
        }
    }

    func bands(_ x: UnsafeBufferPointer<Float>, from start: Int, scratch s: inout Scratch) -> [Float] {
        for i in 0..<n {
            s.re[i] = x[start + i] * hann[i]
            s.im[i] = 0
        }
        fft.transform(&s.re, &s.im)
        var out = [Float](repeating: 0, count: bandBins.count)
        for (b, (lo, hi)) in bandBins.enumerated() {
            var p: Float = 0
            for k in lo..<hi { p += s.re[k] * s.re[k] + s.im[k] * s.im[k] }
            out[b] = p
        }
        return out
    }
}

/// In-place iterative radix-2 complex FFT.
struct FFT {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0)
        self.size = size
        cosTable = (0..<size / 2).map { Float(cos(2 * .pi * Double($0) / Double(size))) }
        sinTable = (0..<size / 2).map { Float(-sin(2 * .pi * Double($0) / Double(size))) }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { i in
            var r = 0
            for b in 0..<bits where i & (1 << b) != 0 { r |= 1 << (bits - 1 - b) }
            return r
        }
    }

    func transform(_ re: inout [Float], _ im: inout [Float]) {
        let n = size
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { m in
                for i in 0..<n {
                    let j = reversed[i]
                    if j > i {
                        r.swapAt(i, j)
                        m.swapAt(i, j)
                    }
                }
                cosTable.withUnsafeBufferPointer { ct in
                    sinTable.withUnsafeBufferPointer { st in
                        var len = 2
                        while len <= n {
                            let half = len / 2, step = n / len
                            var start = 0
                            while start < n {
                                var k = 0
                                for j in start..<(start + half) {
                                    let wr = ct[k], wi = st[k]
                                    let xr = r[j + half], xi = m[j + half]
                                    let tr = xr * wr - xi * wi, ti = xr * wi + xi * wr
                                    r[j + half] = r[j] - tr
                                    m[j + half] = m[j] - ti
                                    r[j] += tr
                                    m[j] += ti
                                    k += step
                                }
                                start += len
                            }
                            len <<= 1
                        }
                    }
                }
            }
        }
    }
}
