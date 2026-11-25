import XCTest
import CatalogKit
@testable import SourceKit

final class DownloadLibraryTests: XCTestCase {
    let frieren = Show(id: 154587, title: "Frieren")
    let mushishi = Show(id: 457, title: "Mushishi")

    func record(_ show: Show, _ season: Int, _ episode: Int, state: DownloadState = .queued, at: Double = 0,
                release: DownloadRelease? = nil) -> DownloadRecord {
        DownloadRecord(id: "\(show.id).\(season).\(episode)", show: show, seasonID: show.id + season, season: season,
                       episode: episode, release: release, state: state, addedAt: Date(timeIntervalSince1970: at))
    }

    func testRoundTrips() throws {
        var lib = DownloadLibrary()
        lib.add(record(frieren, 1, 1, release: DownloadRelease(infoHash: "abc", fileIndex: 3, isBatch: true, length: 1 << 30)))
        lib.add(record(frieren, 1, 2, state: .completed))
        let data = try XCTUnwrap(lib.encoded())
        let back = DownloadLibrary.decode(data)
        XCTAssertEqual(back.records, lib.records)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, DownloadLibrary.currentVersion)
    }

    func testAddingTheSameEpisodeTwiceKeepsOne() {
        var lib = DownloadLibrary()
        XCTAssertTrue(lib.add(record(frieren, 1, 1)))
        XCTAssertFalse(lib.add(record(frieren, 1, 1, state: .completed)))
        XCTAssertEqual(lib.records.count, 1)
        XCTAssertEqual(lib["154587.1.1"]?.state, .queued)
    }

    /// A later version's file: a new state, a new field, and one record this version can't read.
    func testReadsFilesFromLaterVersions() throws {
        let json = """
        {"version": 7, "storageLimit": 5, "records": [
          {"id": "1.2.3", "show": {"id": 1, "title": "A", "synonyms": [], "genres": []}, "seasonID": 2, "season": 1,
           "episode": 3, "state": "throttled", "addedAt": "2026-01-01T00:00:00Z", "quality": "1080p"},
          {"id": "broken"},
          {"id": "1.2.4", "show": {"id": 1, "title": "A", "synonyms": [], "genres": []}, "seasonID": 2, "episode": 4,
           "state": "completed", "release": {"infoHash": "ff", "fileIndex": 0, "isBatch": false}}
        ]}
        """
        let lib = DownloadLibrary.decode(Data(json.utf8))
        XCTAssertEqual(lib.records.map(\.id), ["1.2.3", "1.2.4"])
        XCTAssertEqual(lib["1.2.3"]?.state, .queued)
        XCTAssertEqual(lib["1.2.4"]?.state, .completed)
        XCTAssertEqual(lib["1.2.4"]?.release?.infoHash, "ff")
        XCTAssertEqual(lib["1.2.4"]?.priority, 0)
    }

    func testUnreadableFileIsEmpty() {
        XCTAssertTrue(DownloadLibrary.decode(Data("not json".utf8)).records.isEmpty)
    }

    func testFindsInShowOrderOldestShowFirst() {
        var lib = DownloadLibrary()
        lib.add(record(mushishi, 1, 2, at: 10))
        lib.add(record(frieren, 1, 5, at: 20))
        lib.add(record(frieren, 1, 3, at: 20))
        lib.add(record(mushishi, 1, 1, at: 30))
        lib.add(record(mushishi, 1, 0, state: .completed, at: 1))
        XCTAssertEqual(lib.nextToFind?.id, "457.1.1")
        lib.update("457.1.1") { $0.state = .downloading }
        XCTAssertEqual(lib.nextToFind?.id, "457.1.2")
        lib.update("457.1.2") { $0.state = .failed }
        XCTAssertEqual(lib.nextToFind?.id, "154587.1.3")
        lib.update("154587.1.5") { $0.priority = 1 }
        XCTAssertEqual(lib.nextToFind?.id, "154587.1.5")
        XCTAssertEqual(lib.nextToFind(skipping: [154587])?.id, nil, "shows being found are left to their own finder")
        lib.add(record(mushishi, 1, 4, at: 30))
        XCTAssertEqual(lib.nextToFind(skipping: [154587])?.id, "457.1.4")
    }

    func testSummaryAndShows() {
        var lib = DownloadLibrary()
        lib.add(record(frieren, 1, 1, state: .completed, at: 1))
        lib.add(record(frieren, 1, 2, state: .downloading, at: 2))
        lib.add(record(frieren, 1, 3, state: .failed, at: 3))
        lib.add(record(mushishi, 1, 1, at: 4))
        let s = lib.summary(show: frieren.id)
        XCTAssertEqual([s.total, s.completed, s.pending, s.failed], [3, 1, 1, 1])
        XCTAssertTrue(lib.summary(show: 99).isEmpty)
        XCTAssertEqual(lib.shows.map(\.id), [mushishi.id, frieren.id])
        XCTAssertEqual(lib.records(show: frieren.id).map(\.episode), [1, 2, 3])
    }

    func testReleasesSharedBetweenEpisodes() {
        let pack = DownloadRelease(infoHash: "pack", fileIndex: 0, isBatch: true)
        var lib = DownloadLibrary()
        lib.add(record(frieren, 1, 1, release: pack))
        var second = pack
        second.fileIndex = 1
        lib.add(record(frieren, 1, 2, release: second))
        lib.add(record(frieren, 1, 3, release: DownloadRelease(infoHash: "single", fileIndex: 0)))
        XCTAssertEqual(lib.others(using: "pack", excluding: "154587.1.1").map(\.id), ["154587.1.2"])
        XCTAssertEqual(lib.packs(show: frieren.id).map(\.infoHash), ["pack"])
        XCTAssertEqual(lib.infoHashes, ["pack", "single"])
        lib.remove("154587.1.2")
        XCTAssertTrue(lib.others(using: "pack", excluding: "154587.1.1").isEmpty)
    }
}
