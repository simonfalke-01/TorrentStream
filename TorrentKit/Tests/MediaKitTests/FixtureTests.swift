import XCTest
@testable import MediaKit

/// Tiny files made with ffmpeg (64x36 testsrc, 10 fps, a keyframe every second, 3 s; the H.264 ones with AAC audio
/// and B-frames). Expected frame positions and sizes come from ffprobe -show_packets.
final class FixtureTests: XCTestCase {
    struct Expected {
        let file: String
        let codec: VideoCodec
        /// Offset of the frame bytes in the file, and their size.
        let frames: [(offset: Int, size: Int)]
        var times: [Double] = [0, 1, 2]
    }

    static let cases: [Expected] = [
        Expected(file: "h264.mkv", codec: .h264, frames: [(768, 1248), (4874, 649), (8797, 656)]),
        Expected(file: "h264-cues-front.mkv", codec: .h264, frames: [(979, 1248), (5053, 649), (8928, 656)]),
        Expected(file: "hevc.mkv", codec: .hevc, frames: [(2962, 467), (4044, 513), (5069, 514)]),
        Expected(file: "h264.mp4", codec: .h264, frames: [(2555, 1248), (6352, 649), (9892, 656)]),
        Expected(file: "hevc.mp4", codec: .hevc, frames: [(44, 467), (1065, 513), (2029, 514)]),
    ]

    func testFixtures() async throws {
        for c in Self.cases {
            let data = try Fixture.data(c.file)
            let src = MemorySource(data)
            let index = try await MediaIndex.load(fileLength: src.length, read: src.read)
            XCTAssertEqual(index.video.codec, c.codec, c.file)
            XCTAssertEqual(index.video.width, 64, c.file)
            XCTAssertEqual(index.video.height, 36, c.file)
            XCTAssertEqual(index.video.bitDepth, 8, c.file)
            XCTAssertEqual(index.video.configurationAtom, c.codec == .h264 ? "avcC" : "hvcC")
            XCTAssertFalse(NAL.parameterSets(index.video).isEmpty, c.file)
            XCTAssertEqual(index.duration ?? 0, 3, accuracy: 0.1, c.file)
            XCTAssertEqual(index.keyframes.count, 3, c.file)
            for (k, t) in zip(index.keyframes, c.times) { XCTAssertEqual(k.time, t, accuracy: 0.05, c.file) }
            if c.file.hasSuffix(".mkv") {
                XCTAssertTrue(index.keyframes.allSatisfy { $0.relativeOffset != nil }, "ffmpeg writes CueRelativePosition")
            }

            for (i, f) in c.frames.enumerated() {
                let got = try await index.keyframeData(at: i)
                XCTAssertEqual(got.time, c.times[i], accuracy: 0.05, "\(c.file) #\(i)")
                XCTAssertEqual(got.data, data.subdata(in: f.offset..<(f.offset + f.size)), "\(c.file) #\(i)")
                let units = NAL.units([UInt8](got.data))
                XCTAssertNotNil(units, "\(c.file) #\(i) isn't length-prefixed NAL units")
                let types = (units ?? []).map { c.codec == .h264 ? Int($0[0] & 0x1F) : Int($0[0] >> 1) & 0x3F }
                // IDR (H.264 5) / IRAP (HEVC 16...23).
                XCTAssertTrue(types.contains { c.codec == .h264 ? $0 == 5 : (16...23).contains($0) }, "\(c.file) #\(i): \(types)")

                let estimate = index.estimatedRange(ofKeyframe: i)
                XCTAssertLessThanOrEqual(estimate.lowerBound, Int64(f.offset), c.file)
                if c.file.hasSuffix(".mp4") { XCTAssertEqual(estimate, Int64(f.offset)..<Int64(f.offset + f.size)) }
            }
            let near = try await index.keyframeData(near: 1.4)
            XCTAssertEqual(near.time, 1, accuracy: 0.05)
        }
    }

    func testMatroskaCuesAfterClusters() throws {
        // The default ffmpeg layout: SeekHead up front, Cues after the last cluster.
        let b = [UInt8](try Fixture.data("h264.mkv"))
        func find(_ id: [UInt8]) -> [Int] {
            (0..<(b.count - id.count)).filter { Array(b[$0..<($0 + id.count)]) == id }
        }
        let cues = find([0x1C, 0x53, 0xBB, 0x6B]), clusters = find([0x1F, 0x43, 0xB6, 0x75])
        XCTAssertFalse(cues.isEmpty)
        XCTAssertGreaterThan(cues.max()!, clusters.max()!)
    }

    func testScanPathOnFixture() async throws {
        let data = try Fixture.data("h264.mkv")
        let src = MemorySource(data)
        let loaded = try await MatroskaIndex.load(fileLength: src.length, read: src.read)
        let index = MatroskaIndex(video: loaded.video, trackNumber: loaded.trackNumber, duration: loaded.duration,
                                  timestampScale: loaded.timestampScale,
                                  keyframes: loaded.keyframes.map { Keyframe(time: $0.time, clusterOffset: $0.clusterOffset, relativeOffset: nil) },
                                  fileLength: loaded.fileLength, segmentStart: loaded.segmentStart,
                                  segmentEnd: loaded.segmentEnd, stripped: loaded.stripped, read: loaded.read)
        for (i, f) in Self.cases[0].frames.enumerated() {
            let got = try await index.keyframeData(at: i)
            XCTAssertEqual(got.data, data.subdata(in: f.offset..<(f.offset + f.size)))
        }
    }

    func testReadsAreSmall() async throws {
        let data = try Fixture.data("h264.mkv")
        let src = MemorySource(data)
        let index = try await MediaIndex.load(fileLength: src.length, read: src.read)
        src.resetReads()
        _ = try await index.keyframeData(at: 1)
        // Cluster head + the 649-byte frame.
        XCTAssertLessThan(src.bytesRead, 2_000, "\(src.reads)")
    }
}
