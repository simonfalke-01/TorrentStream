import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TorrentKit

final class TorrentKitTests: XCTestCase {
    func testBencodeRoundTrip() throws {
        let v = BValue.dict(["b": .int(-42), "a": .list([.str("spam"), .int(0)]), "c": .dict(["x": .bytes(Data([0, 255]))])])
        let enc = v.encoded()
        XCTAssertEqual(String(decoding: enc.prefix(3), as: UTF8.self), "d1:")
        XCTAssertEqual(try BDecoder.decode(enc), v)
    }

    func testBencodeRejectsGarbage() {
        XCTAssertThrowsError(try BDecoder.decode(Data("i12".utf8)))
        XCTAssertThrowsError(try BDecoder.decode(Data("5:ab".utf8)))
        XCTAssertThrowsError(try BDecoder.decode(Data("x".utf8)))
    }

    func testSHA1() {
        XCTAssertEqual(SHA1.portableHash(Data("abc".utf8)).hexString, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.portableHash(Data()).hexString, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        let long = Data(repeating: 0x61, count: 1_000_000)
        XCTAssertEqual(SHA1.portableHash(long).hexString, "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    func testMagnetParsing() throws {
        let m = "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=wss%3A%2F%2Ftracker.btorrent.xyz"
        let d = try TorrentDescriptor.parse(magnet: m)
        XCTAssertEqual(d.infoHashHex, "08ada5a7a6183aae1e09d831df6748d566095a10")
        XCTAssertEqual(d.displayName, "Sintel")
        XCTAssertEqual(d.trackers, ["udp://explodie.org:6969", "wss://tracker.btorrent.xyz"])

        let b32 = try TorrentDescriptor.parse(magnet: "magnet:?xt=urn:btih:BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ")
        XCTAssertEqual(b32.infoHashHex, "08ada5a7a6183aae1e09d831df6748d566095a10")
        XCTAssertEqual(try TorrentDescriptor.parse(magnet: " 08ADA5A7A6183AAE1E09D831DF6748D566095A10 ").infoHashHex,
                       "08ada5a7a6183aae1e09d831df6748d566095a10")
        XCTAssertThrowsError(try TorrentDescriptor.parse(magnet: "https://example.com"))
    }

    private func makeTorrent(files: [(String, Int)], pieceLength: Int) -> (Data, Data) {
        var content = Data()
        for (i, f) in files.enumerated() { content.append(Data((0..<f.1).map { UInt8(($0 + i * 7) % 251) })) }
        var pieces = Data()
        var o = 0
        while o < content.count {
            pieces.append(SHA1.hash(content.subdata(in: o..<min(content.count, o + pieceLength))))
            o += pieceLength
        }
        let info = BValue.dict([
            "name": .str("pack"),
            "piece length": .int(Int64(pieceLength)),
            "pieces": .bytes(pieces),
            "files": .list(files.map { .dict(["length": .int(Int64($0.1)), "path": .list([.str("sub"), .str($0.0)])]) }),
        ])
        let torrent = BValue.dict(["announce": .str("udp://tracker.example:80"), "info": info])
        return (torrent.encoded(), content)
    }

    func testTorrentFileParsing() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 50_000), ("b.srt", 1_000)], pieceLength: 16384)
        let d = try TorrentDescriptor.parse(torrentData: data)
        let info = try XCTUnwrap(d.info)
        XCTAssertEqual(info.files.count, 2)
        XCTAssertEqual(info.files[1].offset, 50_000)
        XCTAssertEqual(info.files[1].displayPath, "sub/b.srt")
        XCTAssertEqual(info.pieceCount, 4)
        XCTAssertEqual(info.pieceSize(3), 51_000 - 3 * 16384)
        XCTAssertEqual(info.pieces(for: info.files[1]), 3...3)
        XCTAssertEqual(d.trackers, ["udp://tracker.example:80"])
        XCTAssertEqual(SHA1.hash(info.rawInfo), d.infoHash)
    }

    func testStorageSpansFiles() throws {
        let (data, content) = makeTorrent(files: [("a.bin", 10_000), ("b.bin", 30_000)], pieceLength: 16384)
        let info = try XCTUnwrap(try TorrentDescriptor.parse(torrentData: data).info)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = Storage(root: dir, info: info)
        for p in 0..<info.pieceCount {
            let s = p * info.pieceLength
            try storage.writePiece(p, data: content.subdata(in: s..<s + info.pieceSize(p)))
        }
        XCTAssertEqual(try storage.read(offset: 9_000, length: 5_000), content.subdata(in: 9_000..<14_000))
        XCTAssertEqual(try Data(contentsOf: storage.url(for: info.files[1])), content.subdata(in: 10_000..<40_000))
    }

    func testBitfieldDecoding() {
        XCTAssertEqual(Torrent.decodeBitfield(Data([0b1010_0000, 0b1000_0000]), count: 9),
                       [true, false, true, false, false, false, false, false, true])
    }

    /// End-to-end over loopback: a fake seeder serves pieces to the engine, and the local HTTP server
    /// streams a byte range from the middle of the second file.
    func testStreamingFromLocalSeeder() throws {
        let (data, content) = makeTorrent(files: [("intro.txt", 5_000), ("movie.mp4", 300_000)], pieceLength: 32768)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let info = desc.info!
        let seeder = try FakeSeeder(info: info, content: content)
        defer { seeder.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(descriptor: TorrentDescriptor(infoHash: desc.infoHash, displayName: nil, trackers: [],
                                                                   info: info, magnetURI: nil, torrentData: nil))
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        let url = client.streamURL(for: torrent, fileIndex: 1, fileName: "movie.mp4")
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("bytes=150000-199999", forHTTPHeaderField: "Range")
        let exp = expectation(description: "stream")
        var body: Data?
        var http: HTTPURLResponse?
        URLSession.shared.dataTask(with: req) { d, r, _ in body = d; http = r as? HTTPURLResponse; exp.fulfill() }.resume()
        wait(for: [exp], timeout: 30)
        XCTAssertEqual(http?.statusCode, 206)
        XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Range"), "bytes 150000-199999/300000")
        XCTAssertEqual(body, content.subdata(in: 5_000 + 150_000 ..< 5_000 + 200_000))
    }

    func testPauseResumeAndAvailability() throws {
        let (data, content) = makeTorrent(files: [("clip.mp4", 200_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.pause()
        XCTAssertTrue(torrent.status().isPaused)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")
        // Reading from a paused torrent resumes it.
        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 0, length: 20_000, readerID: UUID(), timeout: 20))
        XCTAssertFalse(torrent.status().isPaused)
        torrent.setWanted(true, fileIndex: 0)
        let deadline = Date().addingTimeInterval(20)
        while !(torrent.status().files.first?.isComplete ?? false) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let fs = try XCTUnwrap(torrent.status().files.first)
        XCTAssertTrue(fs.isComplete)
        XCTAssertFalse(fs.isDownloading)
        XCTAssertEqual(torrent.availability(fileIndex: 0, buckets: 8), Array(repeating: 1.0, count: 8))
        let local = try XCTUnwrap(torrent.localURL(fileIndex: 0))
        XCTAssertEqual(try Data(contentsOf: local), content)
        XCTAssertTrue(torrent.magnetLink.hasPrefix("magnet:?xt=urn:btih:\(desc.infoHashHex)"))
    }

    func testStreamingFetchesOnlyReadaheadAndPrefetch() throws {
        // 256 pieces: with a 512 KB urgent window and 1 MB of near read-ahead the reader needs 64, the container-index
        // tail the last 128.
        let pieceLength = 16384
        let (data, content) = makeTorrent(files: [("ep1.mkv", 256 * pieceLength), ("ep2.mkv", 256 * pieceLength)],
                                          pieceLength: pieceLength)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.lock.lock()
        torrent.criticalBytes = Int64(32 * pieceLength)
        torrent.soonBytes = Int64(64 * pieceLength)
        torrent.lock.unlock()
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        func downloaded(_ i: Int) -> Int64 { torrent.status().files[i].downloadedBytes }
        func waitUntil(_ cond: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        }

        // No readahead: the urgent window and the tail, nothing in between.
        torrent.setReadahead(0, fileIndex: 0)
        let reader = UUID()
        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 0, length: 1000, readerID: reader, timeout: 20))
        let expected = Int64(192 * pieceLength)
        waitUntil { downloaded(0) >= expected }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(downloaded(0), expected)
        XCTAssertEqual(downloaded(1), 0, "streaming one file must not fetch others")

        // Default readahead covers the rest of this small file.
        torrent.setReadahead(nil, fileIndex: 0)
        waitUntil { torrent.status().files[0].isComplete }
        XCTAssertTrue(torrent.status().files[0].isComplete)
        torrent.removeReader(reader)

        // Prefetch loads the next file's start and tail only.
        let head = Int64(10 * pieceLength)
        XCTAssertFalse(torrent.hasPrefix(fileIndex: 1, bytes: head))
        torrent.prefetch(fileIndex: 1, bytes: head)
        waitUntil { torrent.hasPrefix(fileIndex: 1, bytes: head) }
        XCTAssertTrue(torrent.hasPrefix(fileIndex: 1, bytes: head))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(downloaded(1), Int64(138 * pieceLength))
        XCTAssertFalse(torrent.status().files[1].isComplete)
    }

    func testMetadataExchangeFromMagnet() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 70_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(magnet: "magnet:?xt=urn:btih:\(desc.infoHashHex)")
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")
        let info = try XCTUnwrap(torrent.waitForInfo(timeout: 20))
        XCTAssertEqual(info.files.first?.displayPath, "sub/a.mkv")
        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 60_000, length: 10_000, readerID: UUID(), timeout: 20))
        XCTAssertEqual(try torrent.readData(fileIndex: 0, offset: 60_000, length: 10_000), content.subdata(in: 60_000..<70_000))
    }

    /// Pieces restored from a resume file are served by `availableData` right away (no re-hash while their files are
    /// intact); anything touching a missing piece (here: recorded, but its file was truncated) is nil, and asking never
    /// registers a reader.
    func testAvailableData() throws {
        let (data, content) = makeTorrent(files: [("a.bin", 20_000), ("b.mkv", 30_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let info = try XCTUnwrap(desc.info)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let torrentDir = dir.appendingPathComponent(desc.infoHashHex, isDirectory: true)
        let storage = Storage(root: torrentDir.appendingPathComponent("data", isDirectory: true), info: info)
        for p in 0..<2 { try storage.writePiece(p, data: content.subdata(in: p * 16384..<(p + 1) * 16384)) }
        storage.closeAll()
        try Data([1, 1, 1, 0]).write(to: torrentDir.appendingPathComponent("resume.bin"))

        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        XCTAssertNotNil(torrent.availableData(fileIndex: 1, offset: 0, length: 1), "intact pieces are trusted at once")
        XCTAssertEqual(torrent.availableData(fileIndex: 0, offset: 100, length: 1_000), content.subdata(in: 100..<1_100))
        XCTAssertEqual(torrent.availableData(fileIndex: 0, offset: 10_000, length: 1_000_000), content.subdata(in: 10_000..<20_000))
        XCTAssertEqual(torrent.availableData(fileIndex: 1, offset: 0, length: 12_768), content.subdata(in: 20_000..<32_768))
        XCTAssertNil(torrent.availableData(fileIndex: 1, offset: 0, length: 12_769), "piece 2's file was truncated")
        XCTAssertNil(torrent.availableData(fileIndex: 1, offset: 29_000, length: 100))
        XCTAssertEqual(torrent.availableData(fileIndex: 1, offset: 30_000, length: 10), Data())
        XCTAssertNil(torrent.availableData(fileIndex: 2, offset: 0, length: 10))
        XCTAssertNil(torrent.availableData(fileIndex: 0, offset: -1, length: 10))
        XCTAssertNil(torrent.streamStatus(fileIndex: 1).readerOffset)
        XCTAssertNil(torrent.streamStatus(fileIndex: 0).readerOffset)
    }

    func testAddedPeersConnectWithoutWaitingForTick() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 70_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        Thread.sleep(forTimeInterval: 0.1)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")
        let deadline = Date().addingTimeInterval(0.5)
        while torrent.status().connectedPeers == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(torrent.status().connectedPeers, 1)
    }

    /// A torrent without trackers or peers, so a test can drive the piece picker directly.
    private func makeIdleTorrent(_ data: Data) throws -> (TorrentClient, Torrent, URL) {
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        let torrent = try client.add(descriptor: TorrentDescriptor(infoHash: desc.infoHash, displayName: nil, trackers: [],
                                                                   info: desc.info, magnetURI: nil, torrentData: nil))
        return (client, torrent, dir)
    }

    /// A peer that has everything and unchoked us, measured at `rate` bytes/s (0: not measured yet).
    private func unchokedPeer(_ torrent: Torrent, port: UInt16, rate: Double = 0) -> PeerConnection {
        let peer = PeerConnection(address: PeerAddress(ip: 0x7f00_0001, port: port), torrent: torrent)
        peer.bitfield = Array(repeating: true, count: torrent.torrentInfo!.pieceCount)
        peer.peerChoking = false
        peer.rate = rate
        return peer
    }

    /// What the scheduler sends `peer` now (as after a message from it).
    private func actions(_ torrent: Torrent, _ peer: PeerConnection) -> PeerActions {
        torrent.lock.lock(); defer { torrent.lock.unlock() }
        torrent.peersByID[ObjectIdentifier(peer)] = peer
        return torrent.nextActionsLocked(for: peer)
    }

    private func registerReader(_ torrent: Torrent, _ id: UUID, piece: Int, extra: Int64 = 0) throws {
        _ = try torrent.waitForData(fileIndex: 0, offset: Int64(piece) * 262_144 + extra, length: 1, readerID: id, timeout: 0.01)
    }

    private func blocks(_ piece: Int, _ range: [Int]) -> [BlockRequest] {
        range.map { BlockRequest(piece: piece, offset: $0 * 16384, length: 16384) }
    }

    /// "piece/block" names, for readable failures.
    private func names(_ requests: [BlockRequest]) -> [String] { requests.map { "\($0.piece)/\($0.offset / 16384)" } }

    private func waitUntil(_ timeout: TimeInterval = 20, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    private func get(_ url: URL, range: String) -> (HTTPURLResponse?, Data?) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        let exp = expectation(description: "http")
        var body: Data?
        var http: HTTPURLResponse?
        URLSession.shared.dataTask(with: req) { d, r, _ in body = d; http = r as? HTTPURLResponse; exp.fulfill() }.resume()
        wait(for: [exp], timeout: 30)
        return (http, body)
    }

    /// After a seek, the new position is requested before what the previous (still waiting) reader needs.
    /// Pieces are 256 KB (16 blocks); a peer of unknown speed gets its slow-start window (32) of the blocks the player
    /// waits on.
    func testSeekRequestsNewPositionFirst() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        let old = UUID(), new = UUID()
        try registerReader(torrent, old, piece: 20)
        let a = actions(torrent, unchokedPeer(torrent, port: 1))
        XCTAssertEqual(names(a.requests), names(blocks(20, Array(0..<16)) + blocks(21, Array(0..<16))))

        try registerReader(torrent, new, piece: 8, extra: 1000)
        try registerReader(torrent, old, piece: 20)
        let b = actions(torrent, unchokedPeer(torrent, port: 2))
        // The old reader's first blocks are raced too (raced blocks may exceed the share).
        XCTAssertEqual(names(b.requests), names(blocks(8, Array(0..<16)) + blocks(9, Array(0..<16)) + blocks(20, [0, 1])))
    }

    /// A peer whose pipeline is full of less urgent requests cancels them (keeping ~0.15 s of its rate that is likely
    /// on the wire) when the player waits on new blocks; blocks that were urgent before the seek lose their priority.
    func testSeekCancelsQueuedBackgroundRequests() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        try registerReader(torrent, UUID(), piece: 31)
        // 1 MB/s: a share of 0.5 s (32 urgent blocks), a queue of rate × (rtt + 0.3 s) + 8 = 46 blocks.
        let peer = unchokedPeer(torrent, port: 1, rate: 1_048_576)
        // The reader's (last) piece, then the container index at the end of the file.
        let a = actions(torrent, peer)
        XCTAssertEqual(a.requests.count, 46)
        XCTAssertEqual(Array(a.requests.prefix(16)), blocks(31, Array(0..<16)))
        XCTAssertEqual(Set(a.requests.map(\.piece)), [31, 24, 25])

        // The block the new reader is blocked on comes after 0.15 s of the queue (9 blocks); 32 urgent ones follow.
        try registerReader(torrent, UUID(), piece: 8)
        let b = actions(torrent, peer)
        XCTAssertEqual(b.requests.count, 32)
        XCTAssertEqual(b.requests.first, BlockRequest(piece: 8, offset: 0, length: 16384))
        XCTAssertEqual(Set(b.requests.map(\.piece)), [8, 9], "\(names(b.requests))")
        XCTAssertEqual(b.cancels.count, 46 - 9)
        XCTAssertTrue(b.cancels.allSatisfy { [31, 24, 25].contains($0.piece) })
        XCTAssertEqual(peer.pending.count, 9 + 32)
        XCTAssertEqual(peer.cancelled.count, 37, "cancelled requests aren't asked of this peer again until answered")
    }

    /// The first blocks at a new position go to several peers at once; blocks the player waits on that a peer is
    /// late with are requested again from another peer.
    func testOverdueCriticalBlocksAreRaced() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        try registerReader(torrent, UUID(), piece: 31)
        let slow = unchokedPeer(torrent, port: 1), other = unchokedPeer(torrent, port: 2)
        XCTAssertEqual(names(Array(actions(torrent, slow).requests.prefix(16))), names(blocks(31, Array(0..<16))))
        // Only the head is raced while the rest isn't late.
        let second = actions(torrent, other).requests
        XCTAssertEqual(names(second.filter { $0.piece == 31 }), names(blocks(31, [0, 1])))

        // Two seconds later nothing has arrived.
        torrent.lock.lock()
        if let pp = torrent.inProgress[31] {
            for b in 0..<pp.blockCount { pp.requestedAt[b] -= 2; pp.eta[b] -= 2 }
        }
        for p in [slow, other] {
            for (r, v) in p.pending { p.pending[r] = PendingRequest(at: v.at - 2, eta: v.eta - 2, priority: v.priority,
                                                                    deliveredBefore: v.deliveredBefore, queuedAhead: v.queuedAhead, seq: v.seq) }
        }
        torrent.lock.unlock()
        let fast = unchokedPeer(torrent, port: 3, rate: 2_000_000)
        let late = actions(torrent, fast)
        XCTAssertEqual(names(Array(late.requests.prefix(16))), names(blocks(31, Array(0..<16))))
    }

    /// A peer gets about half a second's worth of the blocks the player waits on (its slow-start window while its
    /// speed is being found out) and nothing behind them while some are still unassigned, so slow peers can't hold
    /// much and fast peers take most.
    func testCriticalBlocksAreSharedByPeerSpeed() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        try registerReader(torrent, UUID(), piece: 8)
        let unknown = actions(torrent, unchokedPeer(torrent, port: 1))
        XCTAssertEqual(names(unknown.requests), names(blocks(8, Array(0..<16)) + blocks(9, Array(0..<16))))
        let slowPeer = unchokedPeer(torrent, port: 2, rate: 20_000)
        slowPeer.windowGrowing = false
        let slow = actions(torrent, slowPeer)
        XCTAssertEqual(names(slow.requests), names(blocks(8, [0, 1]) + blocks(10, Array(0..<6))))
        // The rest of the 2 MB window (pieces 8-15); nothing less urgent while the player waits.
        let fast = actions(torrent, unchokedPeer(torrent, port: 3, rate: 4_000_000))
        XCTAssertEqual(names(Array(fast.requests.prefix(4))), names(blocks(8, [0, 1]) + blocks(10, [6, 7])))
        XCTAssertEqual(fast.requests.count, 2 + 128 - 32 - 6)
        XCTAssertTrue(fast.requests.allSatisfy { (8...15).contains($0.piece) })
    }

    /// `want` ranges are ranked by urgency: `.now` with what the player waits on, `.soon` before read-ahead,
    /// `.background` after it; clearing a tag drops its ranges.
    func testWantsArePrioritizedByUrgency() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 64 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        torrent.lock.lock()
        torrent.criticalBytes = 4 * 16384
        torrent.soonBytes = 16 * 16384
        torrent.lock.unlock()
        torrent.setReadahead(4 * 262_144, fileIndex: 0)
        try registerReader(torrent, UUID(), piece: 0)
        torrent.want(fileIndex: 0, ranges: [30 * 262_144 ..< 30 * 262_144 + 32768], urgency: .now, tag: "scrub")
        torrent.want(fileIndex: 0, ranges: [40 * 262_144 ..< 40 * 262_144 + 65536], urgency: .soon, tag: "skip")
        torrent.want(fileIndex: 0, ranges: [50 * 262_144 + 1 ..< 50 * 262_144 + 65536], urgency: .background, tag: "preview")

        let info = try XCTUnwrap(torrent.torrentInfo)
        func spans() -> [Span] {
            torrent.lock.lock(); defer { torrent.lock.unlock() }
            torrent.rebuildOrder(info)
            return torrent.spans
        }
        var s = spans()
        func first(_ piece: Int) -> Int? { s.firstIndex { $0.piece == piece } }
        XCTAssertEqual(s.first { $0.piece == 30 }.map { [$0.priority, $0.start, $0.end] }, [Span.now, 0, 2])
        XCTAssertEqual(s.first { $0.piece == 40 }.map { [$0.priority, $0.start, $0.end] }, [Span.soon, 0, 4])
        XCTAssertEqual(s.first { $0.piece == 50 }.map { [$0.priority, $0.start, $0.end] }, [Span.background, 0, 4])
        let readahead = try XCTUnwrap(s.firstIndex { $0.priority == Span.readahead })
        XCTAssertLessThan(try XCTUnwrap(first(30)), try XCTUnwrap(first(40)))
        XCTAssertLessThan(try XCTUnwrap(first(40)), readahead)
        XCTAssertLessThan(readahead, try XCTUnwrap(first(50)))
        // The player's blocks and the scrub position are requested first.
        let a = actions(torrent, unchokedPeer(torrent, port: 1))
        XCTAssertEqual(Array(a.requests.prefix(6)), blocks(0, [0, 1, 2, 3]) + blocks(30, [0, 1]))

        torrent.clearWants(tag: "scrub")
        torrent.clearWants(tag: "preview")
        s = spans()
        XCTAssertNil(first(30))
        XCTAssertNil(first(50))
        XCTAssertNotNil(first(40))
    }

    /// Blocks are served as they arrive: a piece whose last block never comes is still streamed (and returned by
    /// `waitForBlocks`) up to that block, though it can't be verified and `availableData` doesn't serve it.
    func testBlocksAreServedBeforeThePieceIsVerified() throws {
        let pl = 262_144
        let (data, content) = makeTorrent(files: [("big.mkv", 4 * pl)], pieceLength: pl)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var options = FakeSeeder.Options()
        options.withhold = { $0.piece == 1 && $0.offset == 15 * 16384 }
        let seeder = try FakeSeeder(info: desc.info!, content: content, options: options)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        let url = client.streamURL(for: torrent, fileIndex: 0, fileName: "big.mkv")
        let (http, body) = get(url, range: "\(pl)-\(pl + 99_999)")
        XCTAssertEqual(http?.statusCode, 206)
        XCTAssertEqual(body, content.subdata(in: pl ..< pl + 100_000))
        XCTAssertNil(torrent.availableData(fileIndex: 0, offset: Int64(pl), length: 1000), "piece 1 isn't verified")
        waitUntil { torrent.availableData(fileIndex: 0, offset: 0, length: 1000) != nil }
        XCTAssertEqual(torrent.availableData(fileIndex: 0, offset: 0, length: 1000), content.prefix(1000))
    }

    func testWaitForBlocks() async throws {
        let pl = 262_144
        let (data, content) = makeTorrent(files: [("big.mkv", 4 * pl)], pieceLength: pl)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var options = FakeSeeder.Options()
        options.withhold = { $0.piece == 1 && $0.offset == 15 * 16384 }
        let seeder = try FakeSeeder(info: desc.info!, content: content, options: options)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        let start = Int64(pl) + 1000
        torrent.want(fileIndex: 0, ranges: [start ..< start + 200_000], urgency: .now, tag: "t")
        let got = await torrent.waitForBlocks(fileIndex: 0, offset: start, length: 200_000, timeout: 20)
        XCTAssertEqual(got, content.subdata(in: Int(start) ..< Int(start) + 200_000))

        // The withheld block: nil once the timeout passes, without waiting much longer.
        let t0 = Date()
        let missing = await torrent.waitForBlocks(fileIndex: 0, offset: Int64(pl + 15 * 16384), length: 100, timeout: 0.3)
        XCTAssertNil(missing)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        torrent.clearWants(tag: "t")

        let invalid = await torrent.waitForBlocks(fileIndex: 5, offset: 0, length: 10, timeout: 5)
        XCTAssertNil(invalid)
        let empty = await torrent.waitForBlocks(fileIndex: 0, offset: Int64(4 * pl), length: 10, timeout: 5)
        XCTAssertEqual(empty, Data())
    }

    /// BEP 6: a peer that keeps us choked still serves its allowed-fast pieces, and nothing else is asked of it.
    func testAllowedFastPiecesWhileChoked() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 4 * 32768)], pieceLength: 32768)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var options = FakeSeeder.Options()
        options.fast = true
        options.haveAll = true
        options.choked = true
        options.allowedFast = [2]
        let seeder = try FakeSeeder(info: desc.info!, content: content, options: options)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 2 * 32768 + 100, length: 20_000, readerID: UUID(), timeout: 20))
        XCTAssertEqual(try torrent.readData(fileIndex: 0, offset: 2 * 32768 + 100, length: 20_000),
                       content.subdata(in: 2 * 32768 + 100 ..< 2 * 32768 + 20_100))
        XCTAssertFalse(try torrent.waitForData(fileIndex: 0, offset: 0, length: 100, readerID: UUID(), timeout: 0.5))
        XCTAssertEqual(seeder.refusedRequests, 0)
    }

    /// A rejected request (BEP 6) is asked again and the data still arrives.
    func testRejectedRequestIsRetried() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 4 * 32768)], pieceLength: 32768)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var options = FakeSeeder.Options()
        options.fast = true
        options.rejectOnce = [BlockRequest(piece: 0, offset: 0, length: 16384)]
        let seeder = try FakeSeeder(info: desc.info!, content: content, options: options)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 0, length: 1000, readerID: UUID(), timeout: 20))
        XCTAssertEqual(try torrent.readData(fileIndex: 0, offset: 0, length: 1000), content.prefix(1000))
        XCTAssertEqual(seeder.rejectedRequests, 1)
    }

    /// A peer that alone sent a piece failing the hash check is banned and disconnected.
    func testCorruptSeederIsBanned() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 4 * 16384)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var options = FakeSeeder.Options()
        options.corrupt = { $0.piece == 0 }
        let seeder = try FakeSeeder(info: desc.info!, content: content, options: options)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        let address = PeerAddress(ip: 0x7f00_0001, port: seeder.port)
        torrent.addPeers([address], source: "test")
        _ = try torrent.waitForData(fileIndex: 0, offset: 0, length: 100, readerID: UUID(), timeout: 0.01)

        func banned() -> Bool { torrent.lock.lock(); defer { torrent.lock.unlock() }; return torrent.banned.contains(address) }
        waitUntil(10) { banned() }
        XCTAssertTrue(banned())
        waitUntil(5) { torrent.status().connectedPeers == 0 }
        XCTAssertEqual(torrent.status().connectedPeers, 0)
    }

    /// With an honest and a corrupting seeder, failed pieces are downloaded again, the file ends up correct, and only
    /// the peer that sent bad blocks is banned.
    func testCorruptPiecesAreDownloadedAgain() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 16 * 65536)], pieceLength: 65536)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var bad = FakeSeeder.Options()
        bad.corrupt = { _ in true }
        let evil = try FakeSeeder(info: desc.info!, content: content, options: bad)
        defer { evil.stop() }
        let honest = try FakeSeeder(info: desc.info!, content: content)
        defer { honest.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        let evilAddress = PeerAddress(ip: 0x7f00_0001, port: evil.port)
        let honestAddress = PeerAddress(ip: 0x7f00_0001, port: honest.port)
        torrent.setWanted(true, fileIndex: 0)
        // The corrupting seeder first, so it surely sends some blocks.
        torrent.addPeers([evilAddress], source: "test")
        waitUntil(10) { evil.servedRequests > 0 }
        torrent.addPeers([honestAddress], source: "test")

        waitUntil(30) { torrent.status().files.first?.isComplete ?? false }
        XCTAssertTrue(torrent.status().files.first?.isComplete ?? false)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(torrent.localURL(fileIndex: 0))), content)
        torrent.lock.lock()
        let banned = torrent.banned
        torrent.lock.unlock()
        XCTAssertGreaterThan(evil.servedRequests, 0)
        XCTAssertTrue(banned.contains(evilAddress))
        XCTAssertFalse(banned.contains(honestAddress))
    }

    /// Background downloads (next-episode prefetch) of one torrent hold back while another torrent's player waits.
    func testBackgroundTorrentYieldsToStarvingPlayer() throws {
        let (dataA, _) = makeTorrent(files: [("a.mkv", 4 * 16384)], pieceLength: 16384)
        let (dataB, contentB) = makeTorrent(files: [("b.mkv", 8 * 16384), ("c.mkv", 1)], pieceLength: 16384)
        let descB = try TorrentDescriptor.parse(torrentData: dataB)
        let seeder = try FakeSeeder(info: descB.info!, content: contentB)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let a = try client.add(torrentData: dataA)
        let b = try client.add(torrentData: dataB)
        client.setStarving(a, true)
        b.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")
        b.prefetch(fileIndex: 0, bytes: 4 * 16384)
        waitUntil(5) { b.status().connectedPeers == 1 }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(b.status().files[0].downloadedBytes, 0)
        XCTAssertEqual(seeder.servedRequests, 0)

        client.setStarving(a, false)
        waitUntil { b.hasPrefix(fileIndex: 0, bytes: 4 * 16384) }
        XCTAssertTrue(b.hasPrefix(fileIndex: 0, bytes: 4 * 16384))
    }

    // MARK: app lifecycle and the streaming server

    /// Sends a GET on its own connection and reads the response head. Returns the socket, the head (status line under
    /// ":status") and body bytes that came with it.
    private func openStream(port: UInt16, path: String, range: String) throws -> (TCPSocket, [String: String], Data) {
        let s = try TCPSocket.connect(to: PeerAddress(ip: 0x7f00_0001, port: port), timeout: 2)
        s.setReceiveTimeout(1)
        try s.send(Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=\(range)\r\n\r\n".utf8))
        let terminator = Data("\r\n\r\n".utf8)
        var buf = Data()
        let deadline = Date().addingTimeInterval(20)
        while buf.range(of: terminator) == nil {
            guard Date() < deadline else { throw SocketError.timeout }
            if let d = try s.receive(max: 4096) { buf.append(d) }
        }
        let end = buf.range(of: terminator)!
        let lines = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers = [":status": lines[0]]
        for l in lines.dropFirst() {
            if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) }
        }
        return (s, headers, Data(buf[end.upperBound...]))
    }

    private func ping(_ port: UInt16) -> String? {
        guard let s = try? TCPSocket.connect(to: PeerAddress(ip: 0x7f00_0001, port: port), timeout: 1) else { return nil }
        defer { s.close() }
        s.setReceiveTimeout(1)
        guard (try? s.send(Data("GET /ping HTTP/1.1\r\n\r\n".utf8))) != nil,
              let d = try? s.receiveExactly(12, deadline: Date().addingTimeInterval(2)) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// iOS reclaims the listening socket of a suspended app (accept then fails). The server listens again on the same
    /// port, so URLs the player holds keep working.
    func testStreamServerListensAgainOnSamePort() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 100_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")
        let url = client.streamURL(for: torrent, fileIndex: 0, fileName: "a.mkv")
        let port = client.streamingPort
        XCTAssertEqual(ping(port), "HTTP/1.1 204")
        let generation = client.streamingServerGeneration

        // What a reclaimed socket looks like on Linux: accept fails.
        let fd = client.server.listenerFD
        XCTAssertGreaterThanOrEqual(fd, 0)
        _ = Glue.shutdown(fd, 2 /* SHUT_RDWR */)
        waitUntil(3) { client.server.listenerFD != fd && client.server.listenerFD >= 0 }
        client.applicationWillEnterForeground()
        XCTAssertEqual(client.streamingPort, port)
        // Darwin keeps a shut-down listener accepting, so there is nothing to re-create there.
        if client.server.listenerFD != fd {
            XCTAssertGreaterThan(client.streamingServerGeneration, generation, "the player can tell its connection died")
        }
        XCTAssertEqual(ping(port), "HTTP/1.1 204")
        let (http, body) = get(url, range: "1000-1999")
        XCTAssertEqual(http?.statusCode, 206)
        XCTAssertEqual(body, content.subdata(in: 1000..<2000))
    }

    /// A player that stops reading for longer than the send timeout (paused, app in the background) later gets the
    /// rest of the response: it is never cut short.
    func testResponseWaitsForPlayerThatStopsReading() throws {
        let size = 12 << 20
        let (data, content) = makeTorrent(files: [("a.mkv", size)], pieceLength: 262_144)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        let (s, headers, first) = try openStream(port: client.streamingPort, path: "/stream/\(desc.infoHashHex)/0/a.mkv", range: "0-")
        defer { s.close() }
        var small: Int32 = 32 * 1024
        setsockopt(s.fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        XCTAssertEqual(headers["content-length"], "\(size)")
        var body = first
        while body.count < 1 << 20, let d = try s.receive() { body.append(d) }
        Thread.sleep(forTimeInterval: 3)
        let deadline = Date().addingTimeInterval(30)
        while body.count < size && Date() < deadline {
            if let d = try s.receive() { body.append(d) }
        }
        XCTAssertEqual(body.count, size)
        XCTAssertTrue(body == content, "body differs")
    }

    /// A response that can't be completed (here: the torrent is removed) ends with a reset, so the player sees an
    /// error and asks again instead of taking the short body for the end of the file.
    func testUnfinishedResponseEndsWithReset() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 100_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        let (s, headers, _) = try openStream(port: client.streamingPort, path: "/stream/\(desc.infoHashHex)/0/a.mkv", range: "0-")
        defer { s.close() }
        XCTAssertEqual(headers[":status"], "HTTP/1.1 206 Partial Content")
        client.remove(torrent, deleteData: true)
        s.setReceiveTimeout(5)
        var b: UInt8 = 0
        let n = Glue.recv(s.fd, &b, 1, 0)
        XCTAssertEqual(n, -1)
        XCTAssertEqual(errno, ECONNRESET)
    }

    /// After a long suspension every connection is replaced; peers that sent data are dialed again at once (no
    /// back-off). Going to the background saves them.
    func testReconnectAfterSuspension() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 64 * 16384)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        torrent.setReadahead(0, fileIndex: 0)
        let seederAddress = PeerAddress(ip: 0x7f00_0001, port: seeder.port)
        torrent.addPeers([seederAddress], source: "test")
        let reader = UUID()
        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 0, length: 16384, readerID: reader, timeout: 20))
        torrent.removeReader(reader)

        client.applicationDidEnterBackground()
        let saved = try Data(contentsOf: torrent.directory.appendingPathComponent("peers.bin"))
        XCTAssertEqual(PeerAddress.parseCompactList(saved), [seederAddress])

        torrent.lock.lock()
        let before = torrent.peers[seederAddress].map(ObjectIdentifier.init)
        torrent.lock.unlock()
        XCTAssertNotNil(before)
        torrent.reconnectAfterSuspension(suspended: 600)
        func replaced() -> Bool {
            torrent.lock.lock(); defer { torrent.lock.unlock() }
            guard let p = torrent.peers[seederAddress] else { return false }
            return ObjectIdentifier(p) != before && p.isActive
        }
        waitUntil(2) { replaced() }
        XCTAssertTrue(replaced(), "the useful peer is dialed again right away")
        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 40 * 16384, length: 16384, readerID: UUID(), timeout: 10))
    }

    /// DHT nodes that answered are kept across launches.
    func testDHTNodesPersist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var d = Data()
        for i in 0..<3 { d.append(Data(repeating: UInt8(i), count: 20)); d.append(PeerAddress(ip: 0x0102_0300 + UInt32(i), port: 6881).compact) }
        try d.write(to: file)
        DHT(stateFile: file).save()
        XCTAssertEqual(try Data(contentsOf: file), d)
    }

    /// A torrent added paused stays off the network (no announce, no peer connection) until it is resumed.
    func testAddPausedStaysOffNetworkUntilResumed() throws {
        let (data, content) = makeTorrent(files: [("a.mkv", 70_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: content)
        defer { seeder.stop() }
        let tracker = try FakeHTTPTracker()
        defer { tracker.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(descriptor: TorrentDescriptor(infoHash: desc.infoHash, displayName: nil,
                                                                   trackers: ["http://127.0.0.1:\(tracker.port)/announce"],
                                                                   info: desc.info, magnetURI: nil, torrentData: nil), paused: true)
        XCTAssertTrue(torrent.isPaused)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(tracker.announces, 0)
        XCTAssertEqual(seeder.connections, 0)

        torrent.resume()
        waitUntil(5) { tracker.announces > 0 }
        XCTAssertEqual(tracker.announces, 1)
        XCTAssertTrue(try torrent.waitForData(fileIndex: 0, offset: 0, length: 70_000, readerID: UUID(), timeout: 10))

        // Paused again: no announce (the tracker thread sleeps until a resume pokes it).
        torrent.pause()
        let before = tracker.announces
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(tracker.announces, before)
        XCTAssertTrue(torrent.isPaused)
    }

    /// A ticker runs at the interval it returns, stops when it returns nil, and `tickSoon` runs it right away.
    func testTickerIntervalsAndTickSoon() {
        let loop = EventLoop()
        defer { loop.stop() }
        let owner = NSObject()
        let lock = NSLock()
        var times: [TimeInterval] = []
        var stopAfter = Int.max
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return times.count }
        loop.addTicker(owner: owner, interval: 0) {
            lock.lock(); defer { lock.unlock() }
            times.append(Date.timeIntervalSinceReferenceDate)
            return times.count >= stopAfter ? nil : 10
        }
        waitUntil(1) { count() == 1 }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(count(), 1, "waits for the interval the ticker returned")
        lock.lock(); stopAfter = 2; lock.unlock()
        let asked = Date.timeIntervalSinceReferenceDate
        loop.tickSoon(owner: owner)
        waitUntil(1) { count() == 2 }
        XCTAssertEqual(count(), 2)
        lock.lock(); let second = times.last ?? 0; lock.unlock()
        XCTAssertLessThan(second - asked, 0.2)
        loop.tickSoon(owner: owner)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(count(), 2, "a ticker that returned nil is gone")
    }
}

/// Minimal BitTorrent seeder on 127.0.0.1 used by the tests (supports ut_metadata and, optionally, the fast extension,
/// withheld, rejected and corrupt blocks).
final class FakeSeeder {
    struct Options {
        /// BEP 6.
        var fast = false
        /// Announce pieces with have_all (needs `fast`).
        var haveAll = false
        /// Never unchoke; only `allowedFast` pieces are served.
        var choked = false
        var allowedFast: [Int] = []
        /// Requests never answered.
        var withhold: (BlockRequest) -> Bool = { _ in false }
        /// Requests rejected the first time they are asked (needs `fast`).
        var rejectOnce: Set<BlockRequest> = []
        /// Requests answered with a flipped byte.
        var corrupt: (BlockRequest) -> Bool = { _ in false }
    }

    let info: TorrentInfo
    let content: Data
    let options: Options
    let listener: TCPListener
    var port: UInt16 { listener.port }
    private var running = true
    private let lock = NSLock()
    private var rejectOnce: Set<BlockRequest>
    private var served = 0, rejected = 0, refused = 0
    /// Blocks sent.
    var servedRequests: Int { lock.lock(); defer { lock.unlock() }; return served }
    /// Requests rejected through `rejectOnce`.
    var rejectedRequests: Int { lock.lock(); defer { lock.unlock() }; return rejected }
    /// Requests for pieces not allowed while choked.
    var refusedRequests: Int { lock.lock(); defer { lock.unlock() }; return refused }

    init(info: TorrentInfo, content: Data, options: Options = Options()) throws {
        self.info = info
        self.content = content
        self.options = options
        rejectOnce = options.rejectOnce
        listener = try TCPListener(port: 0)
        Thread.detachNewThread { [self] in
            while running, let a = try? listener.accept() {
                if case .socket(let s) = a {
                    lock.lock(); connected += 1; lock.unlock()
                    Thread.detachNewThread { self.serve(s) }
                }
            }
        }
    }

    private var connected = 0
    var connections: Int { lock.lock(); defer { lock.unlock() }; return connected }

    func stop() { running = false; listener.close() }

    private func frame(_ body: Data) -> Data { var d = Data(); d.appendBE(UInt32(body.count)); d.append(body); return d }

    private func serve(_ s: TCPSocket) {
        s.setReceiveTimeout(5)
        guard let hs = try? s.receiveExactly(68, deadline: Date().addingTimeInterval(5)) else { return }
        var reply = hs.prefix(20)
        reply.append(Data([0, 0, 0, 0, 0, 0x10, 0, options.fast ? 0x04 : 0]))
        reply.append(info.infoHash)
        reply.append(Data(repeating: 0x53, count: 20))
        try? s.send(reply)
        let ext = BValue.dict(["m": .dict(["ut_metadata": .int(3)]), "metadata_size": .int(Int64(info.rawInfo.count))]).encoded()
        try? s.send(frame(Data([20, 0]) + ext))
        if options.fast && options.haveAll {
            try? s.send(frame(Data([0x0E])))
        } else {
            var bf = [UInt8](repeating: 0, count: (info.pieceCount + 7) / 8)
            for i in 0..<info.pieceCount { bf[i / 8] |= 0x80 >> UInt8(i % 8) }
            try? s.send(frame(Data([5]) + bf))
        }
        for p in options.allowedFast { var m = Data([0x11]); m.appendBE(UInt32(p)); try? s.send(frame(m)) }
        if !options.choked { try? s.send(frame(Data([1]))) }
        var buf = Data()
        while running {
            let received: Data?
            do { received = try s.receive() } catch { return }
            guard let d = received else { continue }
            buf.append(d)
            while buf.count >= 4 {
                let len = Int(buf.readUInt32BE(at: 0))
                guard buf.count >= 4 + len else { break }
                let msg = buf.subdata(in: buf.startIndex + 4 ..< buf.startIndex + 4 + len)
                buf = buf.subdata(in: buf.startIndex + 4 + len ..< buf.endIndex)
                guard let id = msg.first else { continue }
                if id == 6 {
                    let p = Int(msg.readUInt32BE(at: 1)), o = Int(msg.readUInt32BE(at: 5)), l = Int(msg.readUInt32BE(at: 9))
                    let r = BlockRequest(piece: p, offset: o, length: l)
                    let reject = frame(Data([0x10]) + msg.dropFirst().prefix(12))
                    if options.choked && !options.allowedFast.contains(p) {
                        lock.lock(); refused += 1; lock.unlock()
                        if options.fast { try? s.send(reject) }
                        continue
                    }
                    lock.lock()
                    let rejectNow = options.fast && rejectOnce.remove(r) != nil
                    if rejectNow { rejected += 1 }
                    lock.unlock()
                    if rejectNow { try? s.send(reject); continue }
                    if options.withhold(r) { continue }
                    let start = p * info.pieceLength + o
                    var block = content.subdata(in: start..<start + l)
                    if options.corrupt(r) { block[block.startIndex] ^= 0xFF }
                    var body = Data([7]); body.appendBE(UInt32(p)); body.appendBE(UInt32(o))
                    body.append(block)
                    lock.lock(); served += 1; lock.unlock()
                    try? s.send(frame(body))
                } else if id == 20, msg.count > 2, msg[msg.startIndex + 1] == 3 {
                    guard let req = try? BDecoder.decode(msg.dropFirst(2)), let piece = req["piece"]?.int else { continue }
                    let raw = info.rawInfo
                    let start = Int(piece) * 16384
                    var body = Data([20, UInt8(PeerConnection.ourUtMetadataID)])
                    body.append(BValue.dict(["msg_type": .int(1), "piece": .int(piece), "total_size": .int(Int64(raw.count))]).encoded())
                    body.append(raw.subdata(in: start..<min(raw.count, start + 16384)))
                    try? s.send(frame(body))
                }
            }
        }
    }
}

/// HTTP tracker on 127.0.0.1 that counts announces and answers with no peers.
final class FakeHTTPTracker {
    let listener: TCPListener
    var port: UInt16 { listener.port }
    private let lock = NSLock()
    private var count = 0
    private var running = true
    var announces: Int { lock.lock(); defer { lock.unlock() }; return count }

    init() throws {
        listener = try TCPListener(port: 0)
        Thread.detachNewThread { [self] in
            while running, let a = try? listener.accept() {
                guard case .socket(let s) = a else { continue }
                Thread.detachNewThread { self.serve(s) }
            }
        }
    }

    func stop() { running = false; listener.close() }

    private func serve(_ s: TCPSocket) {
        defer { s.close() }
        s.setReceiveTimeout(2)
        var buf = Data()
        let deadline = Date().addingTimeInterval(5)
        while buf.range(of: Data("\r\n\r\n".utf8)) == nil && Date() < deadline {
            guard let d = try? s.receive(max: 4096) else { return }
            buf.append(d)
        }
        guard String(decoding: buf, as: UTF8.self).hasPrefix("GET /announce") else { return }
        lock.lock(); count += 1; lock.unlock()
        let body = BValue.dict(["interval": .int(1800), "peers": .bytes(Data())]).encoded()
        var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        reply.append(body)
        try? s.send(reply)
    }
}
