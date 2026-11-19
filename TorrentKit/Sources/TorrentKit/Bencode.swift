import Foundation

/// A bencoded value (BEP 3).
public indirect enum BValue: Equatable {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([String: BValue])

    public subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var data: Data? { if case .bytes(let v) = self { return v }; return nil }
    public var list: [BValue]? { if case .list(let v) = self { return v }; return nil }
    public var dict: [String: BValue]? { if case .dict(let v) = self { return v }; return nil }
    public var string: String? {
        guard let d = data else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    public static func str(_ s: String) -> BValue { .bytes(Data(s.utf8)) }

    public func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .int(let v):
            out.append(contentsOf: Array("i\(v)e".utf8))
        case .bytes(let b):
            out.append(contentsOf: Array("\(b.count):".utf8))
            out.append(b)
        case .list(let l):
            out.append(UInt8(ascii: "l"))
            for v in l { v.encode(into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let d):
            out.append(UInt8(ascii: "d"))
            let keys = d.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for k in keys {
                BValue.str(k).encode(into: &out)
                d[k]!.encode(into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}

public enum BencodeError: Error {
    case unexpectedEnd
    case invalid(String)
}

/// Bencode decoder. Records the raw byte range of the top level `info` dictionary so the
/// info-hash can be computed from the exact original bytes.
public struct BDecoder {
    private let bytes: [UInt8]
    public private(set) var position: Int = 0
    public private(set) var infoRange: Range<Int>?
    private var depth = 0
    private let maxDepth = 64

    public init(_ data: Data) { bytes = [UInt8](data) }
    public init(bytes: [UInt8]) { self.bytes = bytes }

    /// Decodes a single value starting at the current position.
    public mutating func decode() throws -> BValue {
        guard position < bytes.count else { throw BencodeError.unexpectedEnd }
        depth += 1
        defer { depth -= 1 }
        guard depth <= maxDepth else { throw BencodeError.invalid("nesting too deep") }
        let c = bytes[position]
        switch c {
        case UInt8(ascii: "i"):
            position += 1
            let v = try readInt(until: UInt8(ascii: "e"))
            return .int(v)
        case UInt8(ascii: "l"):
            position += 1
            var items: [BValue] = []
            while true {
                guard position < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[position] == UInt8(ascii: "e") { position += 1; break }
                items.append(try decode())
            }
            return .list(items)
        case UInt8(ascii: "d"):
            position += 1
            var dict: [String: BValue] = [:]
            while true {
                guard position < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[position] == UInt8(ascii: "e") { position += 1; break }
                let keyData = try readBytes()
                let key = String(decoding: keyData, as: UTF8.self)
                let start = position
                let value = try decode()
                if depth == 1 && key == "info" { infoRange = start..<position }
                dict[key] = value
            }
            return .dict(dict)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .bytes(Data(try readBytes()))
        default:
            throw BencodeError.invalid("unexpected byte \(c) at \(position)")
        }
    }

    private mutating func readInt(until terminator: UInt8) throws -> Int64 {
        var negative = false
        var value: Int64 = 0
        var digits = 0
        if position < bytes.count && bytes[position] == UInt8(ascii: "-") { negative = true; position += 1 }
        while true {
            guard position < bytes.count else { throw BencodeError.unexpectedEnd }
            let c = bytes[position]
            position += 1
            if c == terminator { break }
            guard c >= 48 && c <= 57 else { throw BencodeError.invalid("bad digit") }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(c - 48))
            guard !o1 && !o2 else { throw BencodeError.invalid("integer overflow") }
            value = a
            digits += 1
        }
        guard digits > 0 else { throw BencodeError.invalid("empty integer") }
        return negative ? -value : value
    }

    private mutating func readBytes() throws -> ArraySlice<UInt8> {
        let len = try readInt(until: UInt8(ascii: ":"))
        guard len >= 0, len <= Int64(bytes.count - position) else { throw BencodeError.unexpectedEnd }
        let start = position
        position += Int(len)
        return bytes[start..<position]
    }

    public static func decode(_ data: Data) throws -> BValue {
        var d = BDecoder(data)
        return try d.decode()
    }
}
