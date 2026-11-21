import XCTest
import CatalogKit
@testable import SkipKit

final class AudioPipelineTests: XCTestCase {
    func fingerprint(_ samples: [Float], rate: Double) -> AudioPrint {
        var p = AudioPrint()
        Fingerprinter.add(samples, sampleRate: rate, startTime: 0, to: &p)
        return p
    }

    func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        (0..<Int(Double(x.count) * to / from)).map { i in
            let t = Double(i) * from / to, k = Int(t), f = Float(t - Double(k))
            return k + 1 < x.count ? x[k] * (1 - f) + x[k + 1] * f : x[min(k, x.count - 1)]
        }
    }

    func testSameMusicMatchesAcrossRatesAndLevels() {
        // The same recording at another sample rate, quieter, after a longer cold open.
        let song = music(seconds: 30, rate: 44100, seed: 9)
        let a = music(seconds: 20, rate: 44100, seed: 1) + song + music(seconds: 15, rate: 44100, seed: 2)
        let b = music(seconds: 35, rate: 48000, seed: 3) + resample(song, from: 44100, to: 48000).map { $0 * 0.3 }
            + music(seconds: 10, rate: 48000, seed: 4)
        let found = PrintMatcher.shared(fingerprint(a, rate: 44100), fingerprint(b, rate: 48000), minLength: 15)
        XCTAssertEqual(found.count, 1)
        guard let s = found.first else { return }
        XCTAssertEqual(s.start, 20, accuracy: 0.4)
        XCTAssertEqual(s.end, 50, accuracy: 0.4)
        XCTAssertEqual(s.otherStart, 35, accuracy: 0.4)
        XCTAssertGreaterThan(s.similarity, 24)
    }

    func testUnrelatedMusicDoesNotMatch() {
        let a = music(seconds: 40, rate: 8000, seed: 1), b = music(seconds: 40, rate: 8000, seed: 2)
        XCTAssertEqual(PrintMatcher.shared(fingerprint(a, rate: 8000), fingerprint(b, rate: 8000), minLength: 15), [])
    }

    func testPieceByPieceFingerprintEqualsWholeFile() {
        let x = music(seconds: 12, rate: 8000, seed: 5)
        let whole = fingerprint(x, rate: 8000)
        var pieces = AudioPrint()
        var start = 0
        while start < x.count {
            // Overlap by half a second, as the listener does.
            let end = min(x.count, start + 3 * 8000 + 4000)
            Fingerprinter.add(Array(x[start..<end]), sampleRate: 8000, startTime: Double(start) / 8000, to: &pieces)
            start += 3 * 8000
        }
        XCTAssertEqual(pieces.frameCount, whole.frameCount)
        for f in 0..<whole.frameCount where whole.isDecoded(f) {
            XCTAssertEqual(pieces.codes[f], whole.codes[f], "frame \(f)")
        }
    }

    // MARK: Matroska

    func int16(_ x: [Float]) -> [Int16] { x.map { Int16(max(-1, min(1, $0)) * 32767) } }

    func testDemuxesEveryLacing() async throws {
        let samples: [Int16] = (0..<(5 * 8000)).map { Int16(truncatingIfNeeded: $0 &* 7919) }
        for lacing: UInt8 in [0, 1, 2, 3] {
            let (bytes, clusters) = MKVWriter.file(samples: samples, rate: 8000, lacing: lacing)
            let file = FakeFile(bytes)
            let size = Int64(bytes.count)
            let found = await MatroskaAudio.layout(read: file.reader, fileSize: size)
            let layout = try XCTUnwrap(found, "lacing \(lacing)")
            XCTAssertEqual(layout.audio.codecID, "A_PCM/INT/LIT")
            XCTAssertEqual(layout.audio.number, 2)
            XCTAssertEqual(layout.audio.sampleRate, 8000)
            XCTAssertEqual(layout.audio.bitDepth, 16)
            XCTAssertEqual(layout.duration, 5, accuracy: 0.001)
            XCTAssertEqual(layout.cues.map(\.offset), clusters.map(Int64.init))
            var payload: [UInt8] = []
            var offset: Int64? = Int64(clusters[0])
            var times: [Double] = []
            while let o = offset, let c = await MatroskaAudio.cluster(at: o, layout: layout, read: file.reader, fileSize: size) {
                times.append(c.time)
                for p in c.packets { payload += p.data }
                XCTAssertEqual(c.packets.filter(\.isTimed).count, 1, "lacing \(lacing)")
                offset = c.end
            }
            XCTAssertEqual(times, [0, 1, 2, 3, 4], "lacing \(lacing)")
            let expected = samples.flatMap { [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)] }
            XCTAssertEqual(payload, expected, "lacing \(lacing)")
        }
    }

    func testPCMDecoder() throws {
        let track = AudioTrackInfo(number: 1, codecID: "A_PCM/INT/LIT", codecPrivate: Data(), sampleRate: 8000, channels: 1, bitDepth: 16)
        let d = try XCTUnwrap(PCMDecoder(track))
        XCTAssertEqual(d.decode(Data([0x00, 0x40, 0x00, 0xC0])), [0.5, -0.5])
        var big = track
        big.codecID = "A_PCM/INT/BIG"
        XCTAssertEqual(PCMDecoder(big)?.decode(Data([0x40, 0x00])), [0.5])
        var other = track
        other.codecID = "A_AAC"
        XCTAssertNil(PCMDecoder(other))
    }

    func testListenerFingerprintsWhatHasDownloaded() async throws {
        let x = music(seconds: 30, rate: 8000, seed: 6)
        let (bytes, clusters) = MKVWriter.file(samples: int16(x), rate: 8000, lacing: 1)
        // The header, the first ten seconds, two more, and the cue index at the end, as a torrent fetches them.
        let file = FakeFile(bytes, available: [0..<clusters[10], clusters[20]..<clusters[22], (bytes.count - 4000)..<bytes.count])
        let listener = EpisodeListener(id: "e", fileSize: Int64(bytes.count), read: file.reader, decoder: PCMDecoder.factory)
        let changed = await listener.update()
        XCTAssertTrue(changed)
        let partial = await listener.print
        XCTAssertEqual(partial.coverage(from: 1, to: 9.5), 1, accuracy: 0.01)
        XCTAssertEqual(partial.coverage(from: 10.5, to: 19.5), 0)
        XCTAssertEqual(partial.coverage(from: 20.5, to: 21.5), 1, accuracy: 0.01)
        let stillUnchanged = await listener.update()
        XCTAssertFalse(stillUnchanged)

        file.make(available: [0..<bytes.count])
        await listener.update()
        let heard = await listener.audio()
        let audio = try XCTUnwrap(heard)
        XCTAssertEqual(audio.duration, 30, accuracy: 0.01)
        // Where decoding picked up out of order, a fraction of a second is missing.
        XCTAssertLessThan(audio.print.longestGap(from: 1, to: 29), 0.6)
        XCTAssertTrue(SkipDetector.isFullyHeard(audio))
        // Same codes as fingerprinting the decoded samples in one go.
        var direct = AudioPrint()
        Fingerprinter.add(int16(x).map { Float($0) / 32768 }, sampleRate: 8000, startTime: 0, to: &direct)
        var same = 0, compared = 0
        for f in 0..<min(direct.frameCount, audio.print.frameCount) where direct.isDecoded(f) && audio.print.isDecoded(f) {
            compared += 1
            if direct.codes[f] == audio.print.codes[f] { same += 1 }
        }
        XCTAssertGreaterThan(compared, 200)
        XCTAssertEqual(same, compared)
    }

    func testListenerWalksClustersWithoutCues() async throws {
        let x = music(seconds: 8, rate: 8000, seed: 7)
        let (bytes, _) = MKVWriter.file(samples: int16(x), rate: 8000, withCues: false)
        let listener = EpisodeListener(id: "e", fileSize: Int64(bytes.count), read: FakeFile(bytes).reader, decoder: PCMDecoder.factory)
        await listener.update()
        let p = await listener.print
        XCTAssertLessThan(p.longestGap(from: 0.5, to: 7.5), 0.3)
    }

    func testOtherFilesAreUnsupported() async {
        let mp4 = FakeFile([0, 0, 0, 0x20] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 100))
        let listener = EpisodeListener(id: "e", fileSize: 112, read: mp4.reader, decoder: PCMDecoder.factory)
        await listener.update()
        let state = await listener.state
        XCTAssertEqual(state, .unsupported)

        let (bytes, _) = MKVWriter.file(samples: [Int16](repeating: 0, count: 8000), rate: 8000)
        let noDecoder = EpisodeListener(id: "e", fileSize: Int64(bytes.count), read: FakeFile(bytes).reader, decoder: { _ in nil })
        await noDecoder.update()
        let state2 = await noDecoder.state
        XCTAssertEqual(state2, .unsupported)
    }

    func testWaitsForTheHeader() async {
        let (bytes, _) = MKVWriter.file(samples: [Int16](repeating: 0, count: 8000), rate: 8000)
        let file = FakeFile(bytes, available: [])
        let listener = EpisodeListener(id: "e", fileSize: Int64(bytes.count), read: file.reader, decoder: PCMDecoder.factory)
        await listener.update()
        let state = await listener.state
        XCTAssertEqual(state, .waiting)
    }
}
