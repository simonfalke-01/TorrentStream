import Foundation

/// Turns subtitle file bytes into a string with "\n" line endings.
enum SubtitleText {
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var text: String
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            text = utf16(bytes.dropFirst(2), littleEndian: true)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            text = utf16(bytes.dropFirst(2), littleEndian: false)
        } else if bytes.count >= 4, bytes[0] != 0, bytes[1] == 0, bytes[3] == 0 {
            text = utf16(bytes[...], littleEndian: true)
        } else if bytes.count >= 4, bytes[0] == 0, bytes[1] != 0, bytes[2] == 0 {
            text = utf16(bytes[...], littleEndian: false)
        } else if isValidUTF8(bytes) {
            text = String(decoding: bytes, as: UTF8.self)
        } else {
            text = windows1252(bytes)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return normalizeNewlines(text)
    }

    static func normalizeNewlines(_ s: String) -> String {
        guard s.utf8.contains(13) else { return s }
        var out = String.UnicodeScalarView()
        var afterCR = false
        for u in s.unicodeScalars {
            if u == "\r" {
                out.append("\n")
                afterCR = true
            } else {
                if !(afterCR && u == "\n") { out.append(u) }
                afterCR = false
            }
        }
        return String(out)
    }

    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var it = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(littleEndian ? a | b << 8 : a << 8 | b)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Code points for 0x80...0x9F; the rest of Windows-1252 coincides with Latin-1.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    private static func windows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for b in bytes {
            let v = (0x80...0x9F).contains(b) ? cp1252High[Int(b) - 0x80] : UInt32(b)
            scalars.append(Unicode.Scalar(v)!)
        }
        return String(scalars)
    }
}
