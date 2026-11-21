import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TorrentKit

/// Matroska head walking (`MatroskaLayout`) and serving undownloaded attachments as a Void element.
final class ContainerLayoutTests: XCTestCase {
    /// A synthetic MKV: EBML header, Segment (unknown size) with SeekHead (cues, tags), Info (24 min), Tracks,
    /// optional Attachments, a Cluster, Cues at the end.
    struct SyntheticMKV {
        var data = Data()
        var segmentStart: Int64 = 0
        var info: Int64 = 0
        var attachments: Range<Int64>?
        var cluster: Int64 = 0
        var cues: Int64 = 0
        var tags: Int64 = 0
    }

    static func element(_ id: [UInt8], _ payload: Data) -> Data {
        var d = Data(id)
        d.append(0x01)
        for shift in stride(from: 48, through: 0, by: -8) { d.append(UInt8(truncatingIfNeeded: UInt64(payload.count) >> UInt64(shift))) }
        d.append(payload)
        return d
    }

    static func uint8Bytes(_ v: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * $0)) })
    }

    static func pattern(_ n: Int, seed: Int) -> Data { Data((0..<n).map { UInt8(($0 * 31 + seed) % 251) }) }

    static func makeMKV(attachmentBytes: Int?, clusterBytes: Int = 400_000) -> SyntheticMKV {
        func build(cuesPos: UInt64, tagsPos: UInt64) -> SyntheticMKV {
            var m = SyntheticMKV()
            var d = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Data("matroska".utf8)))
            d.append(contentsOf: [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            m.segmentStart = Int64(d.count)
            func seek(_ id: [UInt8], _ pos: UInt64) -> Data {
                element([0x4D, 0xBB], element([0x53, 0xAB], Data(id)) + element([0x53, 0xAC], uint8Bytes(pos)))
            }
            d.append(element([0x11, 0x4D, 0x9B, 0x74], seek([0x1C, 0x53, 0xBB, 0x6B], cuesPos) + seek([0x12, 0x54, 0xC3, 0x67], tagsPos)))
            m.info = Int64(d.count)
            var duration = Data()
            let bits = Float(1_440_000).bitPattern
            for shift in stride(from: 24, through: 0, by: -8) { duration.append(UInt8(truncatingIfNeeded: bits >> UInt32(shift))) }
            d.append(element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], Data([0x0F, 0x42, 0x40])) + element([0x44, 0x89], duration)))
            d.append(element([0x16, 0x54, 0xAE, 0x6B], pattern(100, seed: 1)))
            if let n = attachmentBytes {
                let start = Int64(d.count)
                d.append(element([0x19, 0x41, 0xA4, 0x69], pattern(n, seed: 2)))
                m.attachments = start..<Int64(d.count)
            }
            m.cluster = Int64(d.count)
            d.append(element([0x1F, 0x43, 0xB6, 0x75], pattern(clusterBytes, seed: 3)))
            m.tags = Int64(d.count)
            d.append(element([0x12, 0x54, 0xC3, 0x67], pattern(500, seed: 4)))
            m.cues = Int64(d.count)
            d.append(element([0x1C, 0x53, 0xBB, 0x6B], pattern(1_000, seed: 5)))
            m.data = d
            return m
        }
        let first = build(cuesPos: 0, tagsPos: 0)
        return build(cuesPos: UInt64(first.cues - first.segmentStart), tagsPos: UInt64(first.tags - first.segmentStart))
    }

    func testParsesCompleteLayout() throws {
        let m = Self.makeMKV(attachmentBytes: 300_000)
        let a = try XCTUnwrap(m.attachments)
        // The walk stops at the attachments: nothing past them is needed.
        let l = try XCTUnwrap(MatroskaLayout.parse(m.data.prefix(Int(a.lowerBound) + 12)))
        XCTAssertTrue(l.complete)
        XCTAssertEqual(l.frontier, .max)
        XCTAssertEqual(l.segmentStart, m.segmentStart)
        XCTAssertEqual(l.attachments, a)
        XCTAssertEqual(l.firstCluster, m.cluster)
        XCTAssertEqual(l.cues, m.cues)
        XCTAssertEqual(l.seekEntries[MatroskaLayout.tagsID], m.tags)
        XCTAssertEqual(try XCTUnwrap(l.duration), 1440, accuracy: 0.01)

        let plain = Self.makeMKV(attachmentBytes: nil)
        let p = try XCTUnwrap(MatroskaLayout.parse(plain.data.prefix(Int(plain.cluster) + 12)))
        XCTAssertTrue(p.complete)
        XCTAssertNil(p.attachments)
        XCTAssertEqual(p.firstCluster, plain.cluster)
        XCTAssertEqual(p.cues, plain.cues)
    }

    func testIncompleteHeadReportsFrontier() throws {
        let m = Self.makeMKV(attachmentBytes: 300_000)
        // Cut inside Info: the walk resumes there once more arrives.
        let l = try XCTUnwrap(MatroskaLayout.parse(m.data.prefix(Int(m.info) + 20)))
        XCTAssertFalse(l.complete)
        XCTAssertEqual(l.frontier, m.info)
        XCTAssertEqual(l.cues, m.cues, "the SeekHead before it was read")
        XCTAssertNil(l.firstCluster)
        // Too little to tell.
        XCTAssertEqual(MatroskaLayout.parse(m.data.prefix(3)), MatroskaLayout())
        let early = try XCTUnwrap(MatroskaLayout.parse(m.data.prefix(10)))
        XCTAssertFalse(early.complete)
        XCTAssertEqual(early.frontier, 0)
    }

    func testRejectsOtherFiles() {
        XCTAssertNil(MatroskaLayout.parse(Data("RIFF....AVI LIST".utf8)))
        var bad = Self.element([0x1A, 0x45, 0xDF, 0xA3], Data([0x42, 0x82, 0x81, 0x41]))
        bad.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(MatroskaLayout.parse(bad), "an element header can't start with a zero byte")
        var notSegment = Self.element([0x1A, 0x45, 0xDF, 0xA3], Data([0x42, 0x82, 0x81, 0x41]))
        notSegment.append(Self.element([0x1F, 0x43, 0xB6, 0x75], Data(count: 4)))
        XCTAssertNil(MatroskaLayout.parse(notSegment))
    }

    func testVoidedAttachmentsAreAVoidElementOfTheSameLength() throws {
        let m = Self.makeMKV(attachmentBytes: 300_000)
        let a = try XCTUnwrap(m.attachments)
        let l = try XCTUnwrap(MatroskaLayout.parse(m.data))
        let whole = l.voided(offset: a.lowerBound, count: a.count)
        XCTAssertEqual(whole.count, a.count)
        guard case let .header(h) = MatroskaLayout.element([UInt8](whole), 0) else { return XCTFail("no element") }
        XCTAssertEqual(h.id, 0xEC)
        XCTAssertEqual(h.dataStart + (h.size ?? -1), a.count)
        XCTAssertTrue(whole.dropFirst(h.dataStart).allSatisfy { $0 == 0 })
        // Any slice matches the same bytes.
        XCTAssertEqual(l.voided(offset: a.lowerBound + 3, count: 20), whole.subdata(in: 3..<23))
        // A player walking the voided file goes from the void straight to the cluster.
        var file = m.data
        file.replaceSubrange(Int(a.lowerBound)..<Int(a.upperBound), with: whole)
        let walked = try XCTUnwrap(MatroskaLayout.parse(file.prefix(Int(m.cluster) + 12)))
        XCTAssertNil(walked.attachments)
        XCTAssertEqual(walked.firstCluster, m.cluster)
    }

    // MARK: - Streaming

    private func makeTorrent(_ content: Data, name: String, pieceLength: Int) -> Data {
        var pieces = Data()
        var o = 0
        while o < content.count {
            pieces.append(SHA1.hash(content.subdata(in: o..<min(content.count, o + pieceLength))))
            o += pieceLength
        }
        let info = BValue.dict([
            "name": .str(name), "piece length": .int(Int64(pieceLength)), "pieces": .bytes(pieces),
            "length": .int(Int64(content.count)),
        ])
        return BValue.dict(["announce": .str("udp://tracker.example:80"), "info": info]).encoded()
    }

    private func get(_ url: URL, range: String) -> (HTTPURLResponse?, Data?) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        let exp = expectation(description: "http")
        let box = ResponseBox()
        URLSession.shared.dataTask(with: req) { d, r, _ in box.set(d, r as? HTTPURLResponse); exp.fulfill() }.resume()
        wait(for: [exp], timeout: 30)
        return box.get()
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var body: Data?
        private var http: HTTPURLResponse?
        func set(_ d: Data?, _ r: HTTPURLResponse?) { lock.lock(); body = d; http = r; lock.unlock() }
        func get() -> (HTTPURLResponse?, Data?) { lock.lock(); defer { lock.unlock() }; return (http, body) }
    }

    /// Attachments that haven't arrived when the player reads their header are served as a Void element (the player
    /// skips them, as fonts it doesn't get), so the first frame doesn't wait for megabytes of fonts.
    func testUndownloadedAttachmentsAreServedAsVoid() throws {
        let m = Self.makeMKV(attachmentBytes: 300_000)
        let a = try XCTUnwrap(m.attachments)
        let pl = 32768
        let data = makeTorrent(m.data, name: "ep.mkv", pieceLength: pl)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        var options = FakeSeeder.Options()
        options.withhold = { r in
            let s = Int64(r.piece * pl + r.offset)
            return s >= a.lowerBound && s + Int64(r.length) <= a.upperBound
        }
        let seeder = try FakeSeeder(info: desc.info!, content: m.data, options: options)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        XCTAssertTrue(client.skipsUndownloadedAttachments)
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        let url = client.streamURL(for: torrent, fileIndex: 0, fileName: "ep.mkv")
        let end = Int(m.cluster) + 50_000
        let (http, body) = get(url, range: "0-\(end - 1)")
        XCTAssertEqual(http?.statusCode, 206)
        let l = try XCTUnwrap(MatroskaLayout.parse(m.data))
        var expected = m.data.prefix(end)
        expected.replaceSubrange(Int(a.lowerBound)..<Int(a.upperBound), with: l.voided(offset: a.lowerBound, count: a.count))
        XCTAssertEqual(body?.count, end)
        XCTAssertTrue(body == expected, "head real, attachments voided, cluster real")
        XCTAssertEqual(body?.prefix(Int(a.lowerBound)), m.data.prefix(Int(a.lowerBound)))
    }

    /// With `skipsUndownloadedAttachments` off, the file is served exactly as it is.
    func testAttachmentsServedAsIsWhenSkippingIsOff() throws {
        let m = Self.makeMKV(attachmentBytes: 300_000)
        let data = makeTorrent(m.data, name: "ep.mkv", pieceLength: 32768)
        let desc = try TorrentDescriptor.parse(torrentData: data)
        let seeder = try FakeSeeder(info: desc.info!, content: m.data)
        defer { seeder.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(downloadDirectory: dir, useDHT: false, extraTrackers: [])
        defer { client.shutdown() }
        client.skipsUndownloadedAttachments = false
        let torrent = try client.add(torrentData: data)
        torrent.addPeers([PeerAddress(ip: 0x7f00_0001, port: seeder.port)], source: "test")

        let url = client.streamURL(for: torrent, fileIndex: 0, fileName: "ep.mkv")
        let end = Int(m.cluster) + 50_000
        let (http, body) = get(url, range: "0-\(end - 1)")
        XCTAssertEqual(http?.statusCode, 206)
        XCTAssertTrue(body == m.data.prefix(end))
    }
}
