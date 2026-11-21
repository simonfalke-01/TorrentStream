import Foundation

/// A stretch of audio two episodes have in common.
public struct SharedStretch: Sendable, Equatable {
    /// Seconds into the first episode.
    public var start: Double
    public var end: Double
    /// Seconds into the other episode where the stretch starts.
    public var otherStart: Double
    /// Mean number of agreeing bits per frame: 16 is chance, 32 identical.
    public var similarity: Double

    public init(start: Double, end: Double, otherStart: Double, similarity: Double) {
        self.start = start
        self.end = end
        self.otherStart = otherStart
        self.similarity = similarity
    }

    public var length: Double { end - start }
    public var otherEnd: Double { otherStart + length }
}

/// Finds the audio two fingerprints share by sliding one along the other.
public enum PrintMatcher {
    /// Frames averaged when deciding whether two prints agree at a spot.
    static let smoothing = 16
    /// Mean agreeing bits over `smoothing` frames that counts as the same audio. Unrelated audio averages 16 with a
    /// spread of under 1 over that many frames; the same recording re-encoded stays above 24.
    static let threshold = 21
    /// Dips this long inside a shared stretch (a sound effect over the song, a quiet beat) don't split it.
    static let maxGap = 16

    /// Stretches of at least `minLength` seconds that `a` and `b` share, by start in `a`. Where one part of `a`
    /// lines up with `b` at several offsets (a chorus that repeats), the best alignment wins.
    public static func shared(_ a: AudioPrint, _ b: AudioPrint, minLength: Double) -> [SharedStretch] {
        // Only the decoded parts can match; leaving out the rest saves most of the work while a file downloads.
        guard let ra = a.decodedRange, let rb = b.decodedRange else { return [] }
        if ra.count < a.frameCount || rb.count < b.frameCount {
            let sa = AudioPrint(codes: Array(a.codes[ra]), states: Array(a.states[ra]))
            let sb = AudioPrint(codes: Array(b.codes[rb]), states: Array(b.states[rb]))
            let da = AudioPrint.time(ofFrame: ra.lowerBound), db = AudioPrint.time(ofFrame: rb.lowerBound)
            return shared(sa, sb, minLength: minLength).map {
                SharedStretch(start: $0.start + da, end: $0.end + da, otherStart: $0.otherStart + db, similarity: $0.similarity)
            }
        }
        let na = a.frameCount, nb = b.frameCount
        let minFrames = max(smoothing, Int(minLength * AudioPrint.frameRate))
        guard na >= minFrames, nb >= minFrames else { return [] }
        var found: [(start: Int, end: Int, shift: Int, score: Int, matched: Int)] = []
        // Per-frame agreement along one diagonal; unusable frames count as chance.
        var s = [Int32](repeating: 0, count: min(na, nb))
        // Frames quiet in both at this alignment: the silence padding around a theme belongs to it.
        var hush = [Bool](repeating: false, count: min(na, nb))
        a.codes.withUnsafeBufferPointer { ac in
        b.codes.withUnsafeBufferPointer { bc in
        a.states.withUnsafeBufferPointer { ast in
        b.states.withUnsafeBufferPointer { bst in
        s.withUnsafeMutableBufferPointer { sp in
        hush.withUnsafeMutableBufferPointer { hp in
            // b frame j lines up with a frame j + shift.
            for shift in (-(nb - minFrames))...(na - minFrames) {
                let i0 = max(0, shift), i1 = min(na, nb + shift)
                let count = i1 - i0
                guard count >= minFrames else { continue }
                var usable = 0
                for k in 0..<count {
                    let i = i0 + k, j = i - shift
                    if ast[i] == .known && bst[j] == .known {
                        sp[k] = Int32(32 - (ac[i] ^ bc[j]).nonzeroBitCount)
                        hp[k] = false
                        usable += 1
                    } else {
                        sp[k] = 16
                        hp[k] = ast[i] == .quiet && bst[j] == .quiet
                    }
                }
                guard usable >= minFrames else { continue }
                runs(sp, count: count, minFrames: minFrames) { lo0, hi0 in
                    var lo = lo0, hi = hi0
                    while lo > 0 && hp[lo - 1] { lo -= 1 }
                    while hi < count && hp[hi] { hi += 1 }
                    var score = 0, matched = 0
                    for k in lo..<hi {
                        score += Int(sp[k]) - 16
                        if sp[k] >= Int32(threshold + 3) { matched += 1 }
                    }
                    found.append((i0 + lo, i0 + hi, shift, score, matched))
                }
            }
        }}}}}}
        // Keep the strongest alignment for each part of a.
        found.sort { $0.score > $1.score }
        var kept: [(start: Int, end: Int, shift: Int, score: Int, matched: Int)] = []
        for f in found {
            let clash = kept.contains { k in
                let overlap = min(k.end, f.end) - max(k.start, f.start)
                return overlap > 0 && Double(overlap) > 0.3 * Double(min(k.end - k.start, f.end - f.start))
            }
            if !clash { kept.append(f) }
        }
        return kept.sorted { $0.start < $1.start }.map { k in
            SharedStretch(start: AudioPrint.time(ofFrame: k.start), end: AudioPrint.time(ofFrame: k.end),
                          otherStart: AudioPrint.time(ofFrame: k.start - k.shift),
                          similarity: 16 + Double(k.score) / Double(k.end - k.start))
        }
    }

    /// Calls `emit(lo, hi)` for each half-open stretch of `s[0..<count]` whose running mean stays above the threshold,
    /// with dips up to `maxGap` frames bridged, at least `minFrames` long.
    private static func runs(_ s: UnsafeMutableBufferPointer<Int32>, count: Int, minFrames: Int, emit: (Int, Int) -> Void) {
        let w = smoothing
        guard count >= w else { return }
        let need = Int32(threshold * w)
        var sum: Int32 = 0
        for k in 0..<w { sum += s[k] }
        var runStart = -1, runEnd = -1
        // A window agrees once about half its frames do, so a run starts up to a window early and ends up to a window
        // late; trim it to where a few frames in a row agree.
        let edge = 4, edgeNeed = Int32((threshold + 1) * edge)
        func close() {
            if runStart >= 0 {
                var lo = runStart, hi = runEnd
                while hi - lo > edge {
                    var t: Int32 = 0
                    for i in lo..<(lo + edge) { t += s[i] }
                    if t >= edgeNeed { break }
                    lo += 1
                }
                while hi - lo > edge {
                    var t: Int32 = 0
                    for i in (hi - edge)..<hi { t += s[i] }
                    if t >= edgeNeed { break }
                    hi -= 1
                }
                if hi - lo >= minFrames { emit(lo, hi) }
            }
            runStart = -1
        }
        // Window k covers s[k..<k+w]; when it agrees, all of those frames are taken as shared.
        var k = 0
        while true {
            if sum > need {
                let lo = k, hi = k + w
                if runStart >= 0 && lo <= runEnd + maxGap {
                    runEnd = max(runEnd, hi)
                } else {
                    close()
                    runStart = lo
                    runEnd = hi
                }
            }
            if k + w >= count { break }
            sum += s[k + w] - s[k]
            k += 1
        }
        close()
    }
}
