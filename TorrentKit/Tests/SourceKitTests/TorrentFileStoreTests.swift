import XCTest
@testable import SourceKit

final class TorrentFileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tfs-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func torrent(_ n: Int) -> Data { Data("d4:infod4:name\(String(n).count):\(n)ee-padding".utf8) }

    func testFetchesOnceThenReadsFromDisk() async throws {
        let calls = Calls()
        let url = URL(string: "https://nyaa.si/download/1.torrent")!
        let store = TorrentFileStore(directory: dir) { u in
            await calls.add()
            try await Task.sleep(nanoseconds: 100_000_000)
            return Self.torrent(u.absoluteString.count)
        }
        // Concurrent requests share one download.
        async let a = store.data(for: url)
        async let b = store.data(for: url)
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, y)
        let count = await calls.count
        XCTAssertEqual(count, 1)

        // A new store (next launch) finds it on disk.
        let again = TorrentFileStore(directory: dir) { _ in XCTFail("should not fetch"); return Data() }
        let cached = try await again.data(for: url)
        XCTAssertEqual(cached, x)
    }

    func testPrefetchFillsTheStore() async throws {
        let url = URL(string: "https://nyaa.si/download/2.torrent")!
        let store = TorrentFileStore(directory: dir) { _ in Self.torrent(2) }
        store.prefetch([url])
        for _ in 0..<50 {
            if await store.cached(url) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let hit = await store.cached(url)
        XCTAssertEqual(hit, Self.torrent(2))
    }

    func testRejectsErrorPages() async {
        let url = URL(string: "https://nyaa.si/download/3.torrent")!
        let store = TorrentFileStore(directory: dir) { _ in Data("<html>rate limited</html>".utf8) }
        do {
            _ = try await store.data(for: url)
            XCTFail("an HTML page isn't a torrent")
        } catch {}
        let hit = await store.cached(url)
        XCTAssertNil(hit)
    }

    func testPruneKeepsMostRecent() async throws {
        let store = TorrentFileStore(directory: dir, maxFiles: 3) { u in Self.torrent(Int(u.lastPathComponent) ?? 0) }
        for i in 0..<5 {
            let u = URL(string: "https://x/\(i)")!
            _ = try await store.data(for: u)
            let f = await store.file(u)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))], ofItemAtPath: f.path)
        }
        await store.prune()
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left.count, 3)
        let oldest = await store.cached(URL(string: "https://x/0")!)
        XCTAssertNil(oldest)
        let newest = await store.cached(URL(string: "https://x/4")!)
        XCTAssertNotNil(newest)
    }

    func testNameIsStable() {
        XCTAssertEqual(TorrentFileStore.name("https://nyaa.si/download/1.torrent"), TorrentFileStore.name("https://nyaa.si/download/1.torrent"))
        XCTAssertNotEqual(TorrentFileStore.name("a"), TorrentFileStore.name("b"))
    }
}

private actor Calls {
    var count = 0
    func add() { count += 1 }
}
