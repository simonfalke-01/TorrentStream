import XCTest
import CatalogKit
@testable import SkipKit

final class SkipDetectorTests: XCTestCase {
    let op = PrintBuilder.song(40, seed: 1)
    let ed = PrintBuilder.song(40, seed: 2)

    /// An episode of `cold` seconds of story, the opening, story up to `edAt`, the ending, then `tail` seconds.
    func episode(_ seed: UInt64, cold: Double, edAt: Double = 180, tail: Double = 20, opening: Bool = true,
                 ending: Bool = true) -> PrintBuilder {
        var b = PrintBuilder(seed: seed)
        b.noise(cold)
        if opening { b.song(op) }
        b.noise(edAt - b.duration)
        if ending { b.song(ed) } else { b.noise(40) }
        b.noise(tail)
        return b
    }

    func audio(_ id: String, _ b: PrintBuilder, decodedUpTo: Double? = nil, themes: [SkipSegment] = []) -> EpisodeAudio {
        EpisodeAudio(id: id, duration: b.duration, print: b.print(decodedUpTo: decodedUpTo), themes: themes)
    }

    func assertSegment(_ v: SkipVerdict?, _ start: Double, _ end: Double, accuracy: Double = 0.5,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard case .found(let s)? = v else { return XCTFail("expected a segment, got \(String(describing: v))", file: file, line: line) }
        XCTAssertEqual(s.start, start, accuracy: accuracy, "start", file: file, line: line)
        XCTAssertEqual(s.end, end, accuracy: accuracy, "end", file: file, line: line)
    }

    func testFindsOpeningAfterColdOpensOfAnyLength() {
        let eps = [episode(10, cold: 1), episode(11, cold: 30), episode(12, cold: 75, edAt: 170, tail: 30)]
        let r = SkipDetector.analyze(eps.enumerated().map { audio("e\($0.offset)", $0.element) })
        assertSegment(r["e0"]?.intro, 1, 41)
        assertSegment(r["e1"]?.intro, 30, 70)
        assertSegment(r["e2"]?.intro, 75, 115)
        assertSegment(r["e0"]?.credits, 180, 220)
        assertSegment(r["e2"]?.credits, 170, 210)
    }

    func testEpisodeWithoutOpeningIsAbsentOnceFullyHeard() {
        let eps = [episode(10, cold: 5), episode(11, cold: 20), episode(12, cold: 10, opening: false)]
        let full = SkipDetector.analyze(eps.enumerated().map { audio("e\($0.offset)", $0.element) })
        XCTAssertEqual(full["e2"]?.intro, .absent)
        assertSegment(full["e2"]?.credits, 180, 220)

        // Half heard: the opening could still be in the rest.
        let partial = SkipDetector.analyze([audio("e0", eps[0]), audio("e1", eps[1]), audio("e2", eps[2], decodedUpTo: 120)])
        XCTAssertEqual(partial["e2"]?.intro, .unknown)
        XCTAssertEqual(partial["e2"]?.credits, .unknown)
    }

    func testOpeningCutOffByUndecodedAudioIsNotReportedYet() {
        let eps = [episode(10, cold: 5), episode(11, cold: 20)]
        let r = SkipDetector.analyze([audio("e0", eps[0], decodedUpTo: 40), audio("e1", eps[1])])
        XCTAssertEqual(r["e0"]?.intro, .unknown)
        let done = SkipDetector.analyze([audio("e0", eps[0], decodedUpTo: 60), audio("e1", eps[1])])
        assertSegment(done["e0"]?.intro, 5, 45)
    }

    func testRecapOfThePreviousEpisodeIsNotAnOpening() {
        let previous = episode(10, cold: 5)
        // The next episode opens with the last 30 seconds of story before the previous one's ending.
        var next = PrintBuilder(seed: 11)
        next.song(previous.codes, from: 145, to: 175)
        next.noise(10)
        next.song(op)
        next.noise(180 - next.duration)
        next.song(ed)
        next.noise(20)
        let r = SkipDetector.analyze([audio("next", next), audio("prev", previous)])
        assertSegment(r["next"]?.intro, 40, 80)
        assertSegment(r["prev"]?.intro, 5, 45)
    }

    func testOpeningPlayedAsTheFirstEpisodesEnding() {
        // Episode 1 has no opening; its song plays over the ending instead.
        var first = PrintBuilder(seed: 10)
        first.noise(180)
        first.song(op)
        first.noise(20)
        let r = SkipDetector.analyze([audio("e1", first), audio("e2", episode(11, cold: 20)), audio("e3", episode(12, cold: 50))])
        assertSegment(r["e1"]?.credits, 180, 220)
        XCTAssertEqual(r["e1"]?.intro, .absent)
        assertSegment(r["e2"]?.intro, 20, 60)
    }

    func testPartnerSharingMoreThanTheSongDoesNotStretchIt() {
        // Target and the second reference both follow the opening with the same 8 seconds (a title card, say).
        let card = PrintBuilder.song(8, seed: 3)
        func ep(_ seed: UInt64, cold: Double, card withCard: Bool) -> PrintBuilder {
            var b = PrintBuilder(seed: seed)
            b.noise(cold)
            b.song(op)
            if withCard { b.song(card) }
            b.noise(180 - b.duration)
            b.song(ed)
            b.noise(20)
            return b
        }
        let target = ep(10, cold: 10, card: true)
        let two = SkipDetector.analyze([audio("t", target), audio("a", ep(11, cold: 30, card: false)), audio("b", ep(12, cold: 50, card: true))])
        assertSegment(two["t"]?.intro, 10, 50)
        let one = SkipDetector.analyze([audio("t", target), audio("b", ep(12, cold: 50, card: true))])
        assertSegment(one["t"]?.intro, 10, 58)   // with one partner there's no telling
    }

    func testChapterThemeOfAPartnerBoundsTheSong() {
        let card = PrintBuilder.song(8, seed: 3)
        var a = PrintBuilder(seed: 10)
        a.noise(10); a.song(op); a.song(card); a.noise(140); a.song(ed); a.noise(20)
        var b = PrintBuilder(seed: 11)
        b.noise(30); b.song(op); b.song(card); b.noise(120); b.song(ed); b.noise(20)
        let r = SkipDetector.analyze([audio("a", a), audio("b", b, themes: [SkipSegment(kind: .intro, start: 30, end: 70)])])
        assertSegment(r["a"]?.intro, 10, 50)
    }

    func testShortSharedSoundIsNotATheme() {
        let jingle = PrintBuilder.song(10, seed: 4)
        func ep(_ seed: UInt64, at: Double) -> PrintBuilder {
            var b = PrintBuilder(seed: seed)
            b.noise(at); b.song(jingle); b.noise(240 - b.duration)
            return b
        }
        let r = SkipDetector.analyze([audio("a", ep(10, at: 20)), audio("b", ep(11, at: 60)), audio("c", ep(12, at: 90))])
        XCTAssertEqual(r["a"], ContentSkips())
    }

    func testMatcherIncludesSilencePaddingBothShare() {
        var a = PrintBuilder(seed: 10)
        a.noise(20); a.song(op); a.noise(20)
        var b = PrintBuilder(seed: 11)
        b.noise(50); b.song(op); b.noise(20)
        var pa = a.print(), pb = b.print()
        // Two seconds of silence right before the song in both.
        for f in (18 * 8)..<(20 * 8) { pa.set(f, code: 0, quiet: true) }
        for f in (48 * 8)..<(50 * 8) { pb.set(f, code: 0, quiet: true) }
        let found = PrintMatcher.shared(pa, pb, minLength: 15)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.start ?? 0, 18, accuracy: 0.3)
        XCTAssertEqual(found.first?.otherStart ?? 0, 48, accuracy: 0.3)
        XCTAssertEqual(found.first?.end ?? 0, 60, accuracy: 0.3)
    }
}
