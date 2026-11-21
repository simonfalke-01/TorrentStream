import XCTest
@testable import MediaKit

/// Synthetic Matroska file with header stripping, an audio and a subtitle track around the video, a SeekHead chain
/// leading to Cues after the clusters, and a large element before the clusters that must not be read.
struct SyntheticMKV {
    var bytes: [UInt8] = []
    /// (time, decoded frame) per keyframe.
    var frames: [(time: Double, frame: [UInt8])] = []
    var clusterOffsets: [Int64] = []

    static let strip: [UInt8] = [0x00, 0x00]

    init(relativePositions: Bool, unknownClusterSize: Bool = false, filler: Int = 300_000) {
        let uint8 = { (id: UInt32, v: Int) -> [UInt8] in
            E.el(id, (0..<8).reversed().map { UInt8((v >> (8 * $0)) & 0xFF) })
        }
        let header = E.el(MKV.ebml, [E.uint(0x4286, 1), E.string(MKV.docType, "matroska")])
        let segmentHeader = E.id(MKV.segment) + E.unknownSize

        func seekHead(_ entries: [(UInt32, Int)]) -> [UInt8] {
            E.el(MKV.seekHead, entries.map { E.el(MKV.seek, [E.el(MKV.seekID, E.id($0.0)), uint8(MKV.seekPosition, $0.1)]) })
        }
        let info = E.el(MKV.info, [E.uint(MKV.timestampScale, 1_000_000), E.float(MKV.duration, 4000)])
        let encoding = E.el(MKV.contentEncodings, [E.el(MKV.contentEncoding, [
            E.uint(MKV.contentEncodingOrder, 0), E.uint(MKV.contentEncodingScope, 1), E.uint(MKV.contentEncodingType, 0),
            E.el(MKV.contentCompression, [E.uint(MKV.contentCompAlgo, 3), E.el(MKV.contentCompSettings, Self.strip)]),
        ])])
        let tracks = E.el(MKV.tracks, [
            E.el(MKV.trackEntry, [E.uint(MKV.trackNumber, 1), E.uint(MKV.trackType, 2), E.string(MKV.codecID, "A_AAC")]),
            E.el(MKV.trackEntry, [E.uint(MKV.trackNumber, 2), E.uint(MKV.trackType, 1), E.string(MKV.codecID, "V_MPEG4/ISO/AVC"),
                                  E.el(MKV.codecPrivate, [1, 100, 0, 40, 0xFF, 0xE0, 0x00]),
                                  E.el(MKV.video, [E.uint(MKV.pixelWidth, 640), E.uint(MKV.pixelHeight, 360)]), encoding]),
            E.el(MKV.trackEntry, [E.uint(MKV.trackNumber, 3), E.uint(MKV.trackType, 0x11), E.string(MKV.codecID, "S_TEXT/ASS")]),
        ])
        let void = E.el(0xEC, [UInt8](repeating: 0, count: 200_000))

        let f0: [UInt8] = [0, 0, 0, 5, 0x65, 1, 2, 3, 4]
        let f1: [UInt8] = [0, 0, 0, 6, 0x65, 9, 8, 7, 6, 5]
        let stored = { (f: [UInt8]) in Array(f.dropFirst(Self.strip.count)) }

        func cluster(_ children: [[UInt8]]) -> (bytes: [UInt8], relatives: [Int]) {
            var rel: [Int] = []
            var payload: [UInt8] = []
            for c in children { rel.append(payload.count); payload += c }
            let head = E.id(MKV.cluster) + (unknownClusterSize ? E.unknownSize : E.size(payload.count))
            return (head + payload, rel)
        }
        let audio = E.el(MKV.simpleBlock, E.block(track: 1, relative: 0, flags: 0x80, [UInt8](repeating: 0xAA, count: 1000)))
        var fill: [[UInt8]] = []
        for i in 0..<(filler / 10_000) {
            fill.append(E.el(MKV.simpleBlock, E.block(track: 1, relative: Int16(i + 1), flags: 0x80, [UInt8](repeating: 0xAB, count: 10_000))))
        }
        let a = cluster([
            E.el(0xBF, [1, 2, 3, 4]),  // CRC-32
            E.uint(MKV.timestamp, 0), audio,
            E.el(MKV.simpleBlock, E.block(track: 2, relative: 0, flags: 0x80, stored(f0))),
            E.el(MKV.simpleBlock, E.block(track: 2, relative: 40, flags: 0x00, [0, 0x41, 1])),
        ] + fill)
        let b = cluster([
            E.uint(MKV.timestamp, 2000),
            E.el(MKV.blockGroup, [E.el(MKV.block, E.block(track: 3, relative: 0, flags: 0, Array("hi".utf8))), E.uint(0x9B, 1000)]),
            E.el(MKV.blockGroup, [E.el(MKV.block, E.block(track: 2, relative: 0, flags: 0, [0x41, 1])), E.uint(MKV.referenceBlock, 40)]),
            E.el(MKV.blockGroup, [E.el(MKV.block, E.block(track: 2, relative: 40, flags: 0, stored(f1)))]),
            E.el(MKV.simpleBlock, E.block(track: 1, relative: 0, flags: 0x80, [1, 2, 3])),
        ])

        // Segment-relative positions; every size field is fixed-width, so they can be computed up front.
        let head1Length = seekHead([(MKV.info, 0), (MKV.tracks, 0), (MKV.seekHead, 0)]).count
        let infoAt = head1Length
        let tracksAt = infoAt + info.count
        let aAt = tracksAt + tracks.count + void.count
        let bAt = aAt + a.bytes.count
        let cuesAt = bAt + b.bytes.count
        func cuePoint(_ time: Int, _ cluster: Int, _ rel: Int) -> [UInt8] {
            var positions = [E.uint(MKV.cueTrack, 2), uint8(MKV.cueClusterPosition, cluster)]
            if relativePositions { positions.append(uint8(MKV.cueRelativePosition, rel)) }
            return E.el(MKV.cuePoint, [E.uint(MKV.cueTime, UInt64(time)), E.el(MKV.cueTrackPositions, positions)])
        }
        let cues = E.el(MKV.cues, [cuePoint(0, aAt, a.relatives[3]), cuePoint(2000, bAt, b.relatives[3])])
        let head2At = cuesAt + cues.count
        let head1 = seekHead([(MKV.info, infoAt), (MKV.tracks, tracksAt), (MKV.seekHead, head2At)])
        let head2 = seekHead([(MKV.cues, cuesAt)])

        bytes = header + segmentHeader + head1 + info + tracks + void + a.bytes + b.bytes + cues + head2
        let segStart = header.count + segmentHeader.count
        clusterOffsets = [Int64(segStart + aAt), Int64(segStart + bAt)]
        frames = [(0, f0), (2.04, f1)]
    }
}

final class SyntheticMatroskaTests: XCTestCase {
    func testSeekHeadChainHeaderStrippingAndRelativePositions() async throws {
        let mkv = SyntheticMKV(relativePositions: true)
        let src = MemorySource(mkv.bytes)
        let index = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
        XCTAssertLessThan(src.bytesRead, 40_000, "the walk must skip the large element before the clusters")
        XCTAssertEqual(index.video.codec, .h264)
        XCTAssertEqual(index.video.width, 640)
        XCTAssertEqual(index.video.height, 360)
        XCTAssertEqual(index.trackNumber, 2)
        XCTAssertEqual(index.stripped, SyntheticMKV.strip)
        XCTAssertEqual(index.duration ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(index.keyframes.map(\.time), [0, 2])
        XCTAssertEqual(index.keyframes.map(\.clusterOffset), mkv.clusterOffsets)
        XCTAssertTrue(index.keyframes.allSatisfy { $0.relativeOffset != nil })

        for (i, expected) in mkv.frames.enumerated() {
            src.resetReads()
            let got = try await index.keyframeData(at: i)
            XCTAssertEqual(got.time, expected.time, accuracy: 1e-9)
            XCTAssertEqual([UInt8](got.data), expected.frame)
            XCTAssertLessThan(src.bytesRead, 8_000, "keyframe \(i) read too much: \(src.reads)")
        }
    }

    func testScansClusterWithoutRelativePositions() async throws {
        for unknown in [false, true] {
            let mkv = SyntheticMKV(relativePositions: false, unknownClusterSize: unknown)
            let src = MemorySource(mkv.bytes)
            let index = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
            XCTAssertTrue(index.keyframes.allSatisfy { $0.relativeOffset == nil })
            for (i, expected) in mkv.frames.enumerated() {
                src.resetReads()
                let got = try await index.keyframeData(at: i)
                XCTAssertEqual(got.time, expected.time, accuracy: 1e-9)
                XCTAssertEqual([UInt8](got.data), expected.frame, "unknown size: \(unknown)")
                XCTAssertLessThanOrEqual(src.bytesRead, 2 * 64 * 1024, "scan should stop at the keyframe")
            }
        }
    }

    func testWrongRelativePositionFallsBackToScan() async throws {
        let mkv = SyntheticMKV(relativePositions: true)
        let src = MemorySource(mkv.bytes)
        let loaded = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
        let broken = loaded.keyframes.map { Keyframe(time: $0.time, clusterOffset: $0.clusterOffset, relativeOffset: 0) }
        let index = MatroskaIndex(video: loaded.video, trackNumber: loaded.trackNumber, duration: loaded.duration,
                                  timestampScale: loaded.timestampScale, keyframes: broken, fileLength: loaded.fileLength,
                                  segmentStart: loaded.segmentStart, segmentEnd: loaded.segmentEnd, stripped: loaded.stripped,
                                  read: loaded.read)
        for (i, expected) in mkv.frames.enumerated() {
            let got = try await index.keyframeData(at: i)
            XCTAssertEqual([UInt8](got.data), expected.frame)
        }
    }

    func testMissingDataThrowsUnavailable() async throws {
        let mkv = SyntheticMKV(relativePositions: true)
        let src = MemorySource(mkv.bytes)
        let index = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
        src.missing = [mkv.clusterOffsets[1]..<(mkv.clusterOffsets[1] + 200)]
        do {
            _ = try await index.keyframeData(at: 1)
            XCTFail("expected dataUnavailable")
        } catch let e as MediaIndexError {
            XCTAssertEqual(e, .dataUnavailable)
        }
        let first = try await index.keyframeData(at: 0)
        XCTAssertEqual([UInt8](first.data), mkv.frames[0].frame)

        // Per-call read overrides the index's closure.
        let full = MemorySource(mkv.bytes)
        let second = try await index.keyframeData(at: 1, read: full.read)
        XCTAssertEqual([UInt8](second.data), mkv.frames[1].frame)
    }

    func testIndexNeedsCuesAndTracks() async throws {
        let src = MemorySource(SyntheticMKV(relativePositions: true).bytes)
        src.missing = [Int64(src.bytes.count - 200)..<src.length]
        do {
            _ = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
            XCTFail("expected an error while the Cues aren't there")
        } catch let e as MediaIndexError {
            XCTAssertEqual(e, .dataUnavailable)
        }
    }

    func testEstimatedRangeCoversFrameAndStopsAtNextCluster() async throws {
        let mkv = SyntheticMKV(relativePositions: true)
        let src = MemorySource(mkv.bytes)
        let index = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
        let r0 = index.estimatedRange(ofKeyframe: 0)
        XCTAssertEqual(r0.lowerBound, mkv.clusterOffsets[0])
        XCTAssertLessThanOrEqual(r0.upperBound, mkv.clusterOffsets[1])
        XCTAssertGreaterThan(r0.count, 1100)
        let r1 = index.estimatedRange(ofKeyframe: 1)
        XCTAssertEqual(r1.lowerBound, mkv.clusterOffsets[1])
        XCTAssertLessThanOrEqual(r1.upperBound, src.length)
    }

    func testNearestKeyframe() async throws {
        let src = MemorySource(SyntheticMKV(relativePositions: true).bytes)
        let index = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
        XCTAssertEqual(index.nearestKeyframe(to: -5), 0)
        XCTAssertEqual(index.nearestKeyframe(to: 0.9), 0)
        XCTAssertEqual(index.nearestKeyframe(to: 1.1), 1)
        XCTAssertEqual(index.nearestKeyframe(to: 99), 1)
        let near = try await index.keyframeData(near: 1.7)
        XCTAssertEqual(near.time, 2.04, accuracy: 1e-9)
    }

    func testRejectsOtherFiles() async {
        let src = MemorySource([UInt8](repeating: 0x42, count: 4096))
        do {
            _ = try await MediaIndex.load(fileLength: src.length, read: src.read)
            XCTFail("expected unsupportedContainer")
        } catch {
            XCTAssertEqual(error as? MediaIndexError, .unsupportedContainer)
        }
    }
}
