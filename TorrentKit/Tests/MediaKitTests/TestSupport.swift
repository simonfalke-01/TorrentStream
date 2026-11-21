import Foundation
@testable import MediaKit

/// Builds EBML elements for synthetic Matroska files.
enum E {
    static func id(_ v: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var x = v
        while x > 0 { out.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return out
    }

    /// 8-byte size field, so element sizes don't change when payloads are patched.
    static func size(_ n: Int) -> [UInt8] {
        var out: [UInt8] = [0x01]
        for k in (0..<7).reversed() { out.append(UInt8((n >> (8 * k)) & 0xFF)) }
        return out
    }

    static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    static func el(_ i: UInt32, _ payload: [UInt8]) -> [UInt8] { id(i) + size(payload.count) + payload }
    static func el(_ i: UInt32, _ children: [[UInt8]]) -> [UInt8] { el(i, children.flatMap { $0 }) }

    static func uint(_ i: UInt32, _ v: UInt64) -> [UInt8] {
        var b: [UInt8] = []
        var x = v
        repeat { b.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return el(i, b)
    }

    static func string(_ i: UInt32, _ s: String) -> [UInt8] { el(i, Array(s.utf8)) }

    static func float(_ i: UInt32, _ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return el(i, (0..<8).reversed().map { UInt8((bits >> (8 * UInt64($0))) & 0xFF) })
    }

    /// SimpleBlock / Block payload: track number vint, relative timestamp, flags, frame.
    static func block(track: Int, relative: Int16, flags: UInt8, _ frame: [UInt8]) -> [UInt8] {
        let r = UInt16(bitPattern: relative)
        return [0x80 | UInt8(track), UInt8(r >> 8), UInt8(r & 0xFF), flags] + frame
    }
}

/// Fixture files next to this source file.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

/// In-memory byte source that records what was read and can hide ranges.
final class MemorySource: @unchecked Sendable {
    let bytes: Data
    private let lock = NSLock()
    private var _reads: [Range<Int64>] = []
    var missing: [Range<Int64>] = []

    init(_ bytes: Data) { self.bytes = bytes }
    convenience init(_ bytes: [UInt8]) { self.init(Data(bytes)) }

    var length: Int64 { Int64(bytes.count) }
    var reads: [Range<Int64>] { lock.lock(); defer { lock.unlock() }; return _reads }
    var bytesRead: Int64 { reads.reduce(0) { $0 + Int64($1.count) } }
    func resetReads() { lock.lock(); _reads = []; lock.unlock() }

    var read: ReadBytes {
        { [self] offset, length in
            let end = min(offset + length, Int64(self.bytes.count))
            guard offset >= 0, offset < end else { return Data() }
            let range = offset..<end
            if self.record(range) { return nil }
            return self.bytes.subdata(in: Int(offset)..<Int(end))
        }
    }

    /// Logs the read; true if it touches a hidden range.
    private func record(_ range: Range<Int64>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _reads.append(range)
        return missing.contains { $0.overlaps(range) }
    }
}

/// Length-prefixed NAL units to Annex B with the parameter sets from avcC/hvcC up front, for checking frames with
/// ffmpeg and for structural assertions.
enum NAL {
    static func units(_ frame: [UInt8], lengthSize: Int = 4) -> [[UInt8]]? {
        var out: [[UInt8]] = []
        var i = 0
        while i < frame.count {
            guard i + lengthSize <= frame.count else { return nil }
            var n = 0
            for k in 0..<lengthSize { n = n << 8 | Int(frame[i + k]) }
            i += lengthSize
            guard n > 0, i + n <= frame.count else { return nil }
            out.append(Array(frame[i..<(i + n)]))
            i += n
        }
        return out
    }

    static func parameterSets(_ track: VideoTrack) -> [[UInt8]] {
        let c = [UInt8](track.configuration)
        var out: [[UInt8]] = []
        switch track.codec {
        case .h264:
            guard c.count > 6 else { return [] }
            var i = 6
            func take(_ n: Int) {
                for _ in 0..<n {
                    guard i + 2 <= c.count else { return }
                    let len = Int(c[i]) << 8 | Int(c[i + 1])
                    i += 2
                    guard i + len <= c.count else { return }
                    out.append(Array(c[i..<(i + len)]))
                    i += len
                }
            }
            take(Int(c[5] & 0x1F))
            if i < c.count {
                let pps = Int(c[i])
                i += 1
                take(pps)
            }
        case .hevc:
            guard c.count > 23 else { return [] }
            var i = 23
            for _ in 0..<Int(c[22]) {
                guard i + 3 <= c.count else { return out }
                let n = Int(c[i + 1]) << 8 | Int(c[i + 2])
                i += 3
                for _ in 0..<n {
                    guard i + 2 <= c.count else { return out }
                    let len = Int(c[i]) << 8 | Int(c[i + 1])
                    i += 2
                    guard i + len <= c.count else { return out }
                    out.append(Array(c[i..<(i + len)]))
                    i += len
                }
            }
        default: break
        }
        return out
    }

    static func annexB(_ frame: [UInt8], _ track: VideoTrack) -> [UInt8] {
        let start: [UInt8] = [0, 0, 0, 1]
        let ps = parameterSets(track).flatMap { start + $0 }
        let body = (units(frame) ?? []).flatMap { start + $0 }
        return ps + body
    }
}
