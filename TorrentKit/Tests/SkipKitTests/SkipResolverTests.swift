import XCTest
import CatalogKit
@testable import SkipKit

final class SkipResolverTests: XCTestCase {
    let duration = 1437.0

    func seg(_ kind: SkipSegment.Kind, _ start: Double, _ end: Double, inferred: Bool = false) -> SkipSegment {
        SkipSegment(kind: kind, start: start, end: end, isInferred: inferred)
    }

    func testAudioBeatsCatalog() {
        // AniSkip's opening was timed against another cut and is 13.6 s late; the audio has it right.
        let content = ContentSkips(intro: .found(seg(.intro, 393.1, 483.1)), credits: .found(seg(.credits, 1332.0, 1422.6)))
        let out = SkipResolver.segments(catalog: [seg(.intro, 406.7, 496.7), seg(.credits, 1331.1, 1437.1), seg(.recap, 0, 30)],
                                        content: content, chapters: [], duration: duration)
        XCTAssertEqual(out, [seg(.recap, 0, 30), seg(.intro, 393.1, 483.1), seg(.credits, 1332.0, 1422.6)])
        XCTAssertEqual(SkipResolver.nextEpisodeCue(out, duration: duration), 1332.0)
    }

    func testNamedChaptersBeatAudio() {
        let chapters: [(name: String, start: Double, end: Double?)] = [("OP", 0, 89.99), ("Part A", 89.99, 641), ("ED", 1325.01, 1414.98)]
        let content = ContentSkips(intro: .found(seg(.intro, 0.4, 90.8)), credits: .found(seg(.credits, 1325.8, 1415.6)))
        let out = SkipResolver.segments(catalog: [], content: content, chapters: chapters, duration: 1430)
        XCTAssertEqual(out, [seg(.intro, 0, 89.99), seg(.credits, 1325.01, 1414.98)])
    }

    func testAudioSnapsToUnnamedChapterBoundaries() {
        let chapters: [(name: String, start: Double, end: Double?)] = [("Chapter 1", 0, nil), ("Chapter 2", 120, nil), ("Chapter 3", 210, nil)]
        let content = ContentSkips(intro: .found(seg(.intro, 120.6, 209.2)))
        let out = SkipResolver.segments(catalog: [], content: content, chapters: chapters, duration: duration)
        XCTAssertEqual(out, [seg(.intro, 120, 210)])
    }

    func testAbsentOpeningDropsCatalogOpening() {
        let content = ContentSkips(intro: .absent, credits: .unknown)
        let out = SkipResolver.segments(catalog: [seg(.intro, 0, 90), seg(.credits, 1330, 1420)], content: content,
                                        chapters: [], duration: duration)
        XCTAssertEqual(out, [seg(.credits, 1330, 1420)])
    }

    func testInferredOpeningWaitsForTheAudio() {
        let catalog = [seg(.intro, 0, 120, inferred: true), seg(.credits, 1334, 1429, inferred: true)]
        XCTAssertEqual(SkipResolver.segments(catalog: catalog, content: ContentSkips(), chapters: [], duration: 1430),
                       [seg(.credits, 1334, 1430, inferred: true)])
        // A file whose audio can't be analysed keeps the old behaviour.
        XCTAssertEqual(SkipResolver.segments(catalog: catalog, content: nil, chapters: [], duration: 1430),
                       [seg(.intro, 0, 120, inferred: true), seg(.credits, 1334, 1430, inferred: true)])
    }

    func testFileEdgesAreSnapped() {
        let content = ContentSkips(intro: .found(seg(.intro, 0.4, 90.3)), credits: .found(seg(.credits, 1317.1, 1406.6)))
        let out = SkipResolver.segments(catalog: [], content: content, chapters: [], duration: 1407.1)
        XCTAssertEqual(out, [seg(.intro, 0, 90.3), seg(.credits, 1317.1, 1407.1)])
    }

    func testNoNextEpisodeCueWithoutAnEnding() {
        XCTAssertNil(SkipResolver.nextEpisodeCue([], duration: duration))
        XCTAssertNil(SkipResolver.nextEpisodeCue([seg(.intro, 0, 90)], duration: duration))
        // An "ending" AniSkip has at the start of the episode is no cue.
        XCTAssertNil(SkipResolver.nextEpisodeCue([seg(.credits, 6.7, 96.7)], duration: duration))
        XCTAssertNil(SkipResolver.nextEpisodeCue([seg(.credits, 1300, 1390)], duration: 0))
    }

    func testNextEpisodeCueLeavesEpiloguesUncovered() {
        // Two and a half minutes of story after the ending: the card waits for the end of the file.
        XCTAssertNil(SkipResolver.nextEpisodeCue([seg(.credits, 1100, 1190)], duration: duration))
        // Story, then a preview: the card comes with the preview.
        XCTAssertEqual(SkipResolver.nextEpisodeCue([seg(.credits, 1100, 1190), seg(.preview, 1400, 1430)], duration: duration), 1400)
        // A preview straight after the ending doesn't hold the card back.
        XCTAssertEqual(SkipResolver.nextEpisodeCue([seg(.credits, 1300, 1390), seg(.preview, 1390, 1437)], duration: duration), 1300)
    }
}

final class SkipLibraryTests: XCTestCase {
    func testStoresAndForgetsOldestEpisodes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skiplib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SkipLibrary(directory: dir, maxSeries: 1, maxEpisodes: 2)
        var b = PrintBuilder(seed: 1)
        b.noise(5)
        for n in 1...3 {
            await library.store(EpisodeAudio(id: "e\(n)", duration: 5, print: b.print()), series: "mal:1", episode: n)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let kept = await SkipLibrary(directory: dir).episodes(series: "mal:1")
        XCTAssertEqual(Set(kept.keys), [2, 3])
        XCTAssertEqual(kept[3]?.print, b.print())

        await library.store(EpisodeAudio(id: "x", duration: 5, print: b.print()), series: "other show", episode: 1)
        let gone = await SkipLibrary(directory: dir).episodes(series: "mal:1")
        XCTAssertTrue(gone.isEmpty)
    }

    func testKeepsTheFullerPrintOfAnEpisode() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skiplib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SkipLibrary(directory: dir)
        var full = PrintBuilder(seed: 1)
        full.noise(60)
        var start = PrintBuilder(seed: 2)
        start.noise(10)
        await library.store(EpisodeAudio(id: "a", duration: 60, print: full.print()), series: "s", episode: 4)
        await library.store(EpisodeAudio(id: "b", duration: 60, print: start.print()), series: "s", episode: 4)
        let kept = await SkipLibrary(directory: dir).episodes(series: "s")
        XCTAssertEqual(kept[4]?.id, "a")
    }
}

final class SkipSessionTests: XCTestCase {
    /// Three episodes as PCM Matroska files: a cold open, a 25-second song, then story.
    func file(cold: Double, seed: UInt64) -> [UInt8] {
        let song = music(seconds: 25, rate: 8000, seed: 100)
        let x = music(seconds: cold, rate: 8000, seed: seed) + song + music(seconds: 100 - cold - 25, rate: 8000, seed: seed + 1)
        return MKVWriter.file(samples: x.map { Int16($0 * 32767) }, rate: 8000).bytes
    }

    func listener(_ id: String, _ bytes: [UInt8]) -> EpisodeListener {
        EpisodeListener(id: id, fileSize: Int64(bytes.count), read: FakeFile(bytes).reader, decoder: PCMDecoder.factory)
    }

    func testFindsTheOpeningAndRemembersEpisodesForLater() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skipsession-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SkipLibrary(directory: dir)

        let first = SkipSession(target: listener("e1", file(cold: 5, seed: 1)), series: "s", episode: 1, library: library)
        await first.addReference(listener("e2", file(cold: 20, seed: 3)), episode: 2)
        let r1 = await first.refresh()
        XCTAssertEqual(r1?.intro.segment?.start ?? -1, 5, accuracy: 0.5)
        XCTAssertEqual(r1?.intro.segment?.end ?? -1, 30, accuracy: 0.5)
        let stored = await library.episodes(series: "s")
        XCTAssertEqual(Set(stored.keys), [1, 2])

        // A later episode, with nothing else downloading, is compared with the ones remembered.
        let third = SkipSession(target: listener("e3", file(cold: 30, seed: 5)), series: "s", episode: 3, library: library)
        let r3 = await third.refresh()
        XCTAssertEqual(r3?.intro.segment?.start ?? -1, 30, accuracy: 0.5)
        XCTAssertEqual(r3?.intro.segment?.end ?? -1, 55, accuracy: 0.5)
    }

    func testFinishSavesWhatWasHeard() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skipsession-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = SkipLibrary(directory: dir)
        let session = SkipSession(target: listener("e1", file(cold: 5, seed: 1)), series: "s", episode: 1, library: library)
        await session.finish()
        let stored = await library.episodes(series: "s")
        XCTAssertEqual(stored[1]?.print.decodedSeconds ?? 0, 100, accuracy: 1)
    }

    func testUnsupportedFileGivesNil() async {
        let bytes = [UInt8](repeating: 0, count: 64)
        let session = SkipSession(target: listener("x", bytes), series: nil, episode: nil, library: nil)
        let r = await session.refresh()
        XCTAssertNil(r)
    }
}
