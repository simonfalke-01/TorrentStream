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
        // 256 pieces: the urgent window covers 64, the container-index tail the last 128.
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

    /// Pieces restored from a resume file are served by `availableData`; anything touching a missing or corrupt
    /// piece is nil, and asking never registers a reader.
    func testAvailableData() throws {
        let (data, content) = makeTorrent(files: [("a.bin", 20_000), ("b.mkv", 30_000)], pieceLength: 16384)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let info = try XCTUnwrap(desc.info)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let torrentDir = dir.appendingPathComponent(desc.infoHashHex, isDirectory: true)
        let storage = Storage(root: torrentDir.appendingPathComponent("data", isDirectory: true), info: info)
        for p in 0..<2 { try storage.writePiece(p, data: content.subdata(in: p * 16384..<(p + 1) * 16384)) }
        try storage.writePiece(2, data: Data(repeating: 0xAA, count: 16384))
        storage.closeAll()
        try Data([1, 1, 1, 0]).write(to: torrentDir.appendingPathComponent("resume.bin"))

        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        let torrent = try client.add(torrentData: data)
        let deadline = Date().addingTimeInterval(10)
        while torrent.availableData(fileIndex: 1, offset: 0, length: 1) == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }

        XCTAssertEqual(torrent.availableData(fileIndex: 0, offset: 100, length: 1_000), content.subdata(in: 100..<1_100))
        XCTAssertEqual(torrent.availableData(fileIndex: 0, offset: 10_000, length: 1_000_000), content.subdata(in: 10_000..<20_000))
        XCTAssertEqual(torrent.availableData(fileIndex: 1, offset: 0, length: 12_768), content.subdata(in: 20_000..<32_768))
        XCTAssertNil(torrent.availableData(fileIndex: 1, offset: 0, length: 12_769), "piece 2 failed verification")
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

    private func unchokedPeer(_ torrent: Torrent, port: UInt16, capacity: Double = 1e9) -> PeerConnection {
        let peer = PeerConnection(address: PeerAddress(ip: 0x7f00_0001, port: port), torrent: torrent)
        peer.bitfield = Array(repeating: true, count: torrent.torrentInfo!.pieceCount)
        peer.peerChoking = false
        peer.capacity = capacity
        return peer
    }

    private func registerReader(_ torrent: Torrent, _ id: UUID, piece: Int, extra: Int64 = 0) throws {
        _ = try torrent.waitForData(fileIndex: 0, offset: Int64(piece) * 262_144 + extra, length: 1, readerID: id, timeout: 0.01)
    }

    /// After a seek, the new position is requested before what the previous (still waiting) reader needs.
    /// Pieces are 256 KB (16 blocks), so the 2 MB past a reader spans 8 or 9 of them.
    func testSeekRequestsNewPositionFirst() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        let old = UUID(), new = UUID()
        try registerReader(torrent, old, piece: 20)
        let a = torrent.nextActions(for: unchokedPeer(torrent, port: 1), pipelineDepth: 48)
        XCTAssertEqual(Set(a.requests.map(\.piece)), [20, 21, 22])

        try registerReader(torrent, new, piece: 8, extra: 1000)
        try registerReader(torrent, old, piece: 20)
        let b = torrent.nextActions(for: unchokedPeer(torrent, port: 2), pipelineDepth: 48)
        XCTAssertEqual(b.requests.first, BlockRequest(piece: 8, offset: 0, length: 16384))
        XCTAssertEqual(Set(b.requests.map(\.piece)), [8, 9, 10])
    }

    /// A peer whose pipeline is full of background requests cancels them when the player waits on new blocks.
    func testSeekCancelsQueuedBackgroundRequests() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        try registerReader(torrent, UUID(), piece: 31)
        let peer = unchokedPeer(torrent, port: 1)
        // The reader's last piece, then the file head and the container index at the end.
        let a = torrent.nextActions(for: peer, pipelineDepth: 48)
        XCTAssertEqual(a.requests.count, 48)
        XCTAssertEqual(a.requests.first?.piece, 31)
        XCTAssertEqual(Set(a.requests.map(\.piece)), [31, 0, 24])

        try registerReader(torrent, UUID(), piece: 8)
        let b = torrent.nextActions(for: peer, pipelineDepth: 48)
        XCTAssertEqual(Set(b.cancels.map(\.piece)), [0, 24])
        XCTAssertEqual(b.cancels.count, 32)
        XCTAssertEqual(b.requests.first, BlockRequest(piece: 8, offset: 0, length: 16384))
        XCTAssertEqual(Set(b.requests.map(\.piece)), [8, 9])
        XCTAssertEqual(peer.pending.count, 48)
    }

    /// Blocks the player waits on that a peer is slow to send are requested again from another peer, ahead of that
    /// peer's queued work.
    func testOverdueCriticalBlocksAreRaced() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        try registerReader(torrent, UUID(), piece: 31)
        let slow = unchokedPeer(torrent, port: 1), other = unchokedPeer(torrent, port: 2)
        XCTAssertEqual(torrent.nextActions(for: slow, pipelineDepth: 48).requests.first?.piece, 31)
        let early = torrent.nextActions(for: other, pipelineDepth: 48)
        XCTAssertFalse(early.requests.contains { $0.piece == 31 })
        XCTAssertTrue(early.cancels.isEmpty)

        Thread.sleep(forTimeInterval: Torrent.criticalRaceAfter + 0.1)
        let late = torrent.nextActions(for: other, pipelineDepth: 48)
        XCTAssertEqual(late.cancels.count, 48)
        XCTAssertEqual(Array(late.requests.prefix(16)), (0..<16).map { BlockRequest(piece: 31, offset: $0 * 16384, length: 16384) })
    }

    /// A peer gets as many of the blocks the player waits on as it can deliver in about half a second (a few when its
    /// speed is unknown), and nothing behind them while some are still unassigned, so a slow peer can't delay
    /// playback much and fast peers take most of the work.
    func testCriticalBlocksAreSharedByPeerSpeed() throws {
        let (data, _) = makeTorrent(files: [("a.mkv", 32 * 262_144)], pieceLength: 262_144)
        let (client, torrent, dir) = try makeIdleTorrent(data)
        defer { client.shutdown(); try? FileManager.default.removeItem(at: dir) }
        try registerReader(torrent, UUID(), piece: 8)
        let unknown = torrent.nextActions(for: unchokedPeer(torrent, port: 1, capacity: 0), pipelineDepth: 48)
        XCTAssertEqual(unknown.requests, (0..<4).map { BlockRequest(piece: 8, offset: $0 * 16384, length: 16384) })
        let slow = torrent.nextActions(for: unchokedPeer(torrent, port: 2, capacity: 20_000), pipelineDepth: 48)
        XCTAssertEqual(slow.requests, [BlockRequest(piece: 8, offset: 4 * 16384, length: 16384)])
        let fast = torrent.nextActions(for: unchokedPeer(torrent, port: 3, capacity: 4_000_000), pipelineDepth: 48)
        XCTAssertEqual(fast.requests.count, 48)
        XCTAssertEqual(fast.requests.first, BlockRequest(piece: 8, offset: 5 * 16384, length: 16384))
        XCTAssertTrue(fast.requests.allSatisfy { (8...11).contains($0.piece) })
    }
}

/// Minimal BitTorrent seeder on 127.0.0.1 used by the tests (supports ut_metadata).
final class FakeSeeder {
    let info: TorrentInfo
    let content: Data
    let listener: TCPListener
    var port: UInt16 { listener.port }
    private var running = true

    init(info: TorrentInfo, content: Data) throws {
        self.info = info
        self.content = content
        listener = try TCPListener(port: 0)
        Thread.detachNewThread { [self] in
            while running, let s = try? listener.accept() { Thread.detachNewThread { self.serve(s) } }
        }
    }

    func stop() { running = false; listener.close() }

    private func frame(_ body: Data) -> Data { var d = Data(); d.appendBE(UInt32(body.count)); d.append(body); return d }

    private func serve(_ s: TCPSocket) {
        s.setReceiveTimeout(5)
        guard let hs = try? s.receiveExactly(68, deadline: Date().addingTimeInterval(5)) else { return }
        var reply = hs.prefix(20)
        reply.append(Data([0, 0, 0, 0, 0, 0x10, 0, 0]))
        reply.append(info.infoHash)
        reply.append(Data(repeating: 0x53, count: 20))
        try? s.send(reply)
        let ext = BValue.dict(["m": .dict(["ut_metadata": .int(3)]), "metadata_size": .int(Int64(info.rawInfo.count))]).encoded()
        try? s.send(frame(Data([20, 0]) + ext))
        var bf = [UInt8](repeating: 0, count: (info.pieceCount + 7) / 8)
        for i in 0..<info.pieceCount { bf[i / 8] |= 0x80 >> UInt8(i % 8) }
        try? s.send(frame(Data([5]) + bf))
        try? s.send(frame(Data([1])))
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
                    let start = p * info.pieceLength + o
                    var body = Data([7]); body.appendBE(UInt32(p)); body.appendBE(UInt32(o))
                    body.append(content.subdata(in: start..<start + l))
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
