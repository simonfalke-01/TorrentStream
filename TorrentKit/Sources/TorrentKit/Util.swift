import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum SHA1 {
    static func hash(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(Insecure.SHA1.hash(data: data))
        #else
        return portableHash(data)
        #endif
    }

    /// Portable SHA-1 implementation used where CryptoKit is unavailable (Linux).
    static func portableHash(_ data: Data) -> Data {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }

        @inline(__always) func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        var w = [UInt32](repeating: 0, count: 80)
        msg.withUnsafeBufferPointer { m in
            var chunk = 0
            while chunk < m.count {
                for i in 0..<16 {
                    let b = chunk + 4 * i
                    w[i] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
                }
                for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
                var a = h0, b = h1, c = h2, d = h3, e = h4
                for i in 0..<80 {
                    let f: UInt32, k: UInt32
                    if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999 }
                    else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
                    else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
                    else { f = b ^ c ^ d; k = 0xCA62C1D6 }
                    let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                    e = d; d = c; c = rotl(b, 30); b = a; a = t
                }
                h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
                chunk += 64
            }
        }
        var out = Data(capacity: 20)
        for h in [h0, h1, h2, h3, h4] {
            out.append(UInt8(h >> 24)); out.append(UInt8((h >> 16) & 0xff))
            out.append(UInt8((h >> 8) & 0xff)); out.append(UInt8(h & 0xff))
        }
        return out
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    init?(base32: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var buffer: UInt64 = 0
        var bits = 0
        var out = [UInt8]()
        for c in base32.uppercased().utf8 where c != UInt8(ascii: "=") {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | UInt64(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        self.init(out)
    }

    static func random(count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let s = startIndex + offset
        return UInt32(self[s]) << 24 | UInt32(self[s + 1]) << 16 | UInt32(self[s + 2]) << 8 | UInt32(self[s + 3])
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let s = startIndex + offset
        return UInt16(self[s]) << 8 | UInt16(self[s + 1])
    }

    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }

    mutating func appendBE(_ v: UInt16) {
        append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)])
    }

    mutating func appendBE(_ v: UInt64) {
        appendBE(UInt32(v >> 32)); appendBE(UInt32(v & 0xffff_ffff))
    }
}

/// Moving-window transfer-rate meter.
struct RateMeter {
    private var samples: [(time: TimeInterval, bytes: Int)] = []
    private let window: TimeInterval = 5

    mutating func add(_ bytes: Int, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        samples.append((now, bytes))
        trim(now)
    }

    mutating func rate(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Double {
        trim(now)
        let total = samples.reduce(0) { $0 + $1.bytes }
        return Double(total) / window
    }

    private mutating func trim(_ now: TimeInterval) {
        if let idx = samples.firstIndex(where: { now - $0.time <= window }) {
            if idx > 0 { samples.removeFirst(idx) }
        } else {
            samples.removeAll()
        }
    }
}

func log(_ message: @autoclosure () -> String) {
    if TorrentLog.enabled { TorrentLog.handler(message()) }
}

public enum TorrentLog {
    public static var enabled = false
    public static var handler: (String) -> Void = { msg in
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
    }
}
