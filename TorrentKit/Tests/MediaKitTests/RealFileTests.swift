import XCTest
@testable import MediaKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opt-in check against a real release. Set MEDIAKIT_REAL_FILE (a local path) or MEDIAKIT_REAL_URL (an HTTP URL
/// that honours Range requests, e.g. `tkcli <magnet> --serve`) plus MEDIAKIT_REAL_LENGTH; MEDIAKIT_DUMP_DIR receives
/// a few keyframes as Annex B files for decoding with ffmpeg.
final class RealFileTests: XCTestCase {
    func testRealFile() async throws {
        let env = ProcessInfo.processInfo.environment
        let read: ReadBytes
        let length: Int64
        if let path = env["MEDIAKIT_REAL_FILE"] {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            length = Int64(try handle.seekToEnd())
            let file = LockedFile(handle)
            read = { offset, count in file.read(offset, count) }
        } else if let s = env["MEDIAKIT_REAL_URL"], let url = URL(string: s), let l = env["MEDIAKIT_REAL_LENGTH"].flatMap(Int64.init) {
            length = l
            read = { offset, count in
                var req = URLRequest(url: url, timeoutInterval: 300)
                req.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
                return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                    URLSession.shared.dataTask(with: req) { data, _, _ in c.resume(returning: data) }.resume()
                }
            }
        } else {
            throw XCTSkip("set MEDIAKIT_REAL_FILE or MEDIAKIT_REAL_URL + MEDIAKIT_REAL_LENGTH")
        }

        let counter = Counter()
        let counted: ReadBytes = { offset, count in
            let d = await read(offset, count)
            counter.add(count)
            return d
        }
        let t0 = Date()
        let index = try await MediaIndex.load(fileLength: length, read: counted)
        print("index: \(index.video.codec) \(index.video.codecID) \(index.video.width)x\(index.video.height) " +
              "profile \(index.video.profile ?? -1) depth \(index.video.bitDepth ?? -1), duration \(index.duration ?? -1), " +
              "\(index.keyframes.count) keyframes, \(counter.total) bytes read in \(Date().timeIntervalSince(t0))s")
        XCTAssertGreaterThan(index.keyframes.count, 1)
        let gaps = zip(index.keyframes.dropFirst(), index.keyframes).map { $0.time - $1.time }
        print("keyframe spacing: min \(gaps.min() ?? 0) max \(gaps.max() ?? 0) mean \(gaps.reduce(0, +) / Double(max(1, gaps.count)))")
        if let m = index as? MatroskaIndex {
            print("relative positions: \(m.keyframes.filter { $0.relativeOffset != nil }.count)/\(m.keyframes.count), stripped \(m.stripped)")
        }

        let dump = env["MEDIAKIT_DUMP_DIR"].map { URL(fileURLWithPath: $0) }
        let duration = index.duration ?? index.keyframes.last!.time
        var sizes: [Int] = []
        for (n, t) in stride(from: duration * 0.05, to: duration, by: duration / 6).enumerated() {
            let before = counter.total
            let f = try await index.keyframeData(near: t)
            sizes.append(f.data.count)
            let est = index.estimatedRange(ofKeyframe: index.nearestKeyframe(to: t)!)
            print(String(format: "  t=%.1f -> keyframe %.3f, %d bytes, read %d, estimate %d", t, f.time, f.data.count,
                         counter.total - before, est.count))
            XCTAssertNotNil(NAL.units([UInt8](f.data)))
            if let d = dump {
                let ext = index.video.codec == .hevc ? "hevc" : "h264"
                try Data(NAL.annexB([UInt8](f.data), index.video)).write(to: d.appendingPathComponent("frame\(n).\(ext)"))
            }
        }
    }
}

final class LockedFile: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }

    func read(_ offset: Int64, _ count: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: Int(count))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int64) { lock.lock(); value += n; lock.unlock() }
    var total: Int64 { lock.lock(); defer { lock.unlock() }; return value }
}
