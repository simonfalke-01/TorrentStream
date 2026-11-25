import XCTest
@testable import SubtitleKit

final class MatroskaReaderTests: XCTestCase {
    private func srt(_ k: Int) -> SubtitleCue { SubtitleCue(start: Double(10 * k + 1), end: Double(10 * k + 3), text: "Line \(k)\nsecond") }
    private func simple(_ k: Int) -> SubtitleCue { SubtitleCue(start: Double(10 * k + 6), end: Double(10 * k + 11), text: "Line \(k) simple") }
    private func ass(_ k: Int) -> SubtitleCue { SubtitleCue(start: Double(10 * k + 2), end: Double(10 * k + 4), text: "Hello \(k)\nworld") }

    private func allSRT(_ clusters: Range<Int>) -> [SubtitleCue] { clusters.flatMap { [srt($0), simple($0)] } }

    private func assertCues(_ actual: [SubtitleCue], _ expected: [SubtitleCue], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.text, e.text, file: file, line: line)
            XCTAssertEqual(a.start, e.start, accuracy: 1e-6, file: file, line: line)
            XCTAssertEqual(a.end, e.end, accuracy: 1e-6, file: file, line: line)
        }
    }

    func testTracks() async throws {
        let fixture = MKVFixture()
        let reader = FixtureSource(fixture.data).reader()
        let tracks = try await reader.tracks()
        XCTAssertEqual(tracks, [
            SubtitleTrackInfo(number: 2, codecID: "S_TEXT/UTF8", format: .srt, language: "eng", name: "Full", isDefault: true, isForced: false),
            SubtitleTrackInfo(number: 3, codecID: "S_TEXT/ASS", format: .ass, language: "ja-JP", name: "Signs & Songs", isDefault: false, isForced: true),
        ])
        XCTAssertEqual(tracks.map(\.id), [2, 3])
        let again = try await reader.tracks()
        XCTAssertEqual(again, tracks)
    }

    func testASSHeaderAndCueStyle() async throws {
        let reader = FixtureSource(MKVFixture().data).reader()
        let header = try await reader.assHeader(track: 3)
        XCTAssertEqual(header?.playResX, 384)
        XCTAssertEqual(header?.playResY, 288)
        XCTAssertEqual(header?.style(named: "Default")?.fontName, "Arial")
        let noHeader = try await reader.assHeader(track: 2)
        XCTAssertNil(noHeader)
        let cues = try await reader.cues(track: 3, from: 33.9, to: 33.9)
        XCTAssertEqual(cues.map(\.style), ["Default"])
        let fonts = try await reader.fonts()
        XCTAssertTrue(fonts.isEmpty)
    }

    func testASSHeaderParse() {
        let script = """
        [Script Info]
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Open Sans Semibold,74,&H00FFFFFF,&H000000FF,&H00020713,&H64000000,-1,0,0,0,100,100,0,0,1,3.6,1.5,2,120,120,64,1
        Style: Top,Open Sans,60,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,-1,0,0,100,100,0,0,3,2,0,8,10,10,30,1
        """
        let h = ASSHeader.parse(script)
        XCTAssertEqual(h.playResX, 1920)
        XCTAssertEqual(h.playResY, 1080)
        let d = h.style(named: "*default")
        XCTAssertEqual(d?.fontName, "Open Sans Semibold")
        XCTAssertEqual(d?.fontSize, 74)
        XCTAssertEqual(d?.primaryColour, 0x00FF_FFFF)
        XCTAssertEqual(d?.outlineColour, 0x0002_0713)
        XCTAssertEqual(d?.backColour, 0x6400_0000)
        XCTAssertEqual(d?.bold, true)
        XCTAssertEqual(d?.outline, 3.6)
        XCTAssertEqual(d?.marginV, 64)
        let top = h.style(named: "Top")
        XCTAssertEqual(top?.italic, true)
        XCTAssertEqual(top?.borderStyle, 3)
        XCTAssertEqual(top?.alignment, 8)
        XCTAssertEqual(h.style(named: "Missing")?.name, "Default")

        let ssa = ASSHeader.parse("[V4 Styles]\nFormat: Name, Alignment\nStyle: Old,6\n")
        XCTAssertEqual(ssa.style(named: "Old")?.alignment, 8)
        XCTAssertEqual(ASSHeader.colour("&HFF&"), 0xFF)
        XCTAssertEqual(ASSHeader.colour("255"), 255)
    }

    func testWebMDocTypeAccepted() async throws {
        let reader = FixtureSource(MKVFixture { $0.docType = "webm" }.data).reader()
        let count = try await reader.tracks().count
        XCTAssertEqual(count, 2)
    }

    func testRejectsNonMatroska() async throws {
        let notMKV = FixtureSource(Data("1\n00:00:01,000 --> 00:00:02,000\nhi\n".utf8)).reader()
        await assertThrows(MatroskaError.notMatroska) { _ = try await notMKV.tracks() }
        let otherDocType = FixtureSource(MKVFixture { $0.docType = "avi" }.data).reader()
        await assertThrows(MatroskaError.notMatroska) { _ = try await otherDocType.tracks() }
        let fixture = MKVFixture()
        let notYet = FixtureSource(fixture.data, available: []).reader()
        await assertThrows(MatroskaError.dataUnavailable) { _ = try await notYet.tracks() }
    }

    private func assertThrows(_ expected: MatroskaError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MatroskaError, expected, file: file, line: line)
        }
    }

    func testCueWindowsWithIndex() async throws {
        let fixture = MKVFixture()
        let source = FixtureSource(fixture.data)
        let reader = source.reader()
        assertCues(try await reader.cues(track: 2, from: 20, to: 25), [simple(1), srt(2)])
        assertCues(try await reader.cues(track: 2, from: 0, to: 100), allSRT(0..<6))
        assertCues(try await reader.cues(track: 3, from: 0, to: 100), (0..<6).map(ass))
        assertCues(try await reader.cues(track: 3, from: 33.9, to: 33.9), [ass(3)])
        assertCues(try await reader.cues(track: 2, from: 200, to: 300), [])
        assertCues(try await reader.cues(track: 2, from: 5, to: 4), [])
        assertCues(try await reader.cues(track: 1, from: 0, to: 100), [])
        assertCues(try await reader.cues(track: 9, from: 0, to: 100), [])
        XCTAssertLessThanOrEqual(source.maxRequest, 64 * 1024)
    }

    func testIndexedLookupReadsOnlyNearbyClusters() async throws {
        let fixture = MKVFixture { $0.clusterCount = 12 }
        let source = FixtureSource(fixture.data)
        let reader = source.reader()
        _ = try await reader.tracks()
        let before = source.totalRequested
        assertCues(try await reader.cues(track: 2, from: 101, to: 102), [srt(10)])
        let used = source.totalRequested - before
        XCTAssertLessThan(used, fixture.data.count / 3, "read \(used) of \(fixture.data.count) bytes")
        XCTAssertFalse(source.requests.contains { Int($0.offset) < fixture.clusterOffsets[8] && Int($0.offset) >= fixture.clusterOffsets[0] },
                       "clusters before the lookback window must not be read")
        XCTAssertLessThanOrEqual(source.maxRequest, 64 * 1024)
    }

    func testRepeatedQueriesUseCachedClusters() async throws {
        let source = FixtureSource(MKVFixture().data)
        let reader = source.reader()
        _ = try await reader.cues(track: 2, from: 0, to: 60)
        let count = source.requests.count
        assertCues(try await reader.cues(track: 3, from: 30, to: 45), [ass(3), ass(4)])
        assertCues(try await reader.cues(track: 2, from: 30, to: 45), [simple(2), srt(3), simple(3), srt(4)])
        XCTAssertEqual(source.requests.count, count)
    }

    func testUnknownSizes() async throws {
        for includeCues in [true, false] {
            let fixture = MKVFixture {
                $0.unknownSegmentSize = true
                $0.unknownClusterSize = true
                $0.includeCues = includeCues
            }
            let reader = FixtureSource(fixture.data).reader()
            let count = try await reader.tracks().count
            XCTAssertEqual(count, 2)
            assertCues(try await reader.cues(track: 2, from: 20, to: 25), [simple(1), srt(2)])
            assertCues(try await reader.cues(track: 2, from: 0, to: 100), allSRT(0..<6))
            assertCues(try await reader.cues(track: 3, from: 40, to: 60), [ass(4), ass(5)])
        }
    }

    func testTimestampScale() async throws {
        let fixture = MKVFixture { $0.timestampScale = 10_000_000 }
        let reader = FixtureSource(fixture.data).reader()
        assertCues(try await reader.cues(track: 2, from: 30, to: 35), [simple(2), srt(3)])
        assertCues(try await reader.cues(track: 3, from: 0, to: 15), [ass(0), ass(1)])
    }

    func testSequentialScanWithoutIndex() async throws {
        let fixture = MKVFixture { $0.includeCues = false }
        let source = FixtureSource(fixture.data)
        let reader = source.reader()
        assertCues(try await reader.cues(track: 2, from: 41, to: 43), [srt(4)])
        assertCues(try await reader.cues(track: 2, from: 0, to: 12), [srt(0), simple(0), srt(1)])
        assertCues(try await reader.cues(track: 3, from: 50, to: 100), [ass(5)])
    }

    func testSequentialScanSkipsClustersBySize() async throws {
        let fixture = MKVFixture {
            $0.includeCues = false
            $0.clusterCount = 12
        }
        let source = FixtureSource(fixture.data)
        let reader = source.reader()
        assertCues(try await reader.cues(track: 2, from: 101, to: 102), [srt(10)])
        XCTAssertLessThan(source.totalRequested, fixture.data.count / 2, "early clusters are skipped using their sizes")
        XCTAssertLessThanOrEqual(source.maxRequest, 64 * 1024)
    }

    func testPartialDownloadFallsBackToSequentialScan() async throws {
        let fixture = MKVFixture()
        let cuesOffset = try XCTUnwrap(fixture.cuesOffset)
        // Head through the srt block of cluster 3 (ending inside its second video frame); the Cues at the end
        // aren't downloaded.
        let source = FixtureSource(fixture.data, available: [0..<fixture.clusterOffsets[3] + 45_000])
        let reader = source.reader()
        let count = try await reader.tracks().count
        XCTAssertEqual(count, 2)
        assertCues(try await reader.cues(track: 2, from: 0, to: 100), allSRT(0..<3) + [srt(3)])
        assertCues(try await reader.cues(track: 3, from: 0, to: 100), [ass(0), ass(1), ass(2)])
        assertCues(try await reader.cues(track: 2, from: 45, to: 50), [])

        // More arrives (still no index): later calls continue from what was seen.
        source.setAvailable([0..<cuesOffset])
        assertCues(try await reader.cues(track: 2, from: 45, to: 50), [simple(4)])
        assertCues(try await reader.cues(track: 2, from: 50, to: 60), [simple(4), srt(5), simple(5)])

        // Once the index is local it is used, including for ranges seen before.
        source.setAvailable([0..<fixture.data.count])
        assertCues(try await reader.cues(track: 2, from: 30, to: 35), [simple(2), srt(3)])
    }

    func testIndexSkipsGapsAfterSeek() async throws {
        let fixture = MKVFixture()
        // Header and cluster 0, then from cluster 4 to the end (a seek): the lookback cluster 3 is missing.
        let source = FixtureSource(fixture.data, available: [0..<fixture.clusterOffsets[1], fixture.clusterOffsets[4]..<fixture.data.count])
        let reader = source.reader()
        assertCues(try await reader.cues(track: 2, from: 42, to: 44), [srt(4)])
        assertCues(try await reader.cues(track: 2, from: 0, to: 100), [srt(0), simple(0)] + allSRT(4..<6))
    }

    func testHeaderStripping() async throws {
        let fixture = MKVFixture { $0.strippedHeader = Array("<i>Line ".utf8) }
        let reader = FixtureSource(fixture.data).reader()
        assertCues(try await reader.cues(track: 2, from: 0, to: 25), allSRT(0..<2) + [srt(2)])
    }

    func testZlibUsesDecompressor() async throws {
        let fixture = MKVFixture { $0.fakeZlibASS = true }
        let calls = Counter()
        let reader = FixtureSource(fixture.data).reader { data in
            calls.increment()
            return Data(data.reversed())
        }
        let numbers = try await reader.tracks().map(\.number)
        XCTAssertEqual(numbers, [2, 3])
        assertCues(try await reader.cues(track: 3, from: 0, to: 25), [ass(0), ass(1), ass(2)])
        XCTAssertEqual(calls.value, 12)

        let failing = FixtureSource(fixture.data).reader { _ in nil }
        assertCues(try await failing.cues(track: 3, from: 0, to: 25), [])

        let withoutInflater = FixtureSource(fixture.data).reader()
        let remaining = try await withoutInflater.tracks().map(\.number)
        XCTAssertEqual(remaining, [2], "zlib tracks can't be read without a decompressor")
    }

    func testReadErrorsPropagate() async throws {
        struct Boom: Error {}
        let reader = MatroskaSubtitleReader(fileLength: 1000) { _, _ in throw Boom() }
        do {
            _ = try await reader.tracks()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
