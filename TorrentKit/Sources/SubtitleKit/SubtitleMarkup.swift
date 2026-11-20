import Foundation

/// Removes formatting from cue text, leaving the plain lines a simple overlay can draw.
enum SubtitleMarkup {
    /// SRT and Matroska S_TEXT/UTF8: HTML-ish tags (<i>, <font ...>) and ASS override blocks ({\an8}).
    static func plainSRT(_ s: String) -> String {
        joinLines(strip(s, tags: .letterTags, braces: .overridesOnly, assEscapes: false))
    }

    /// WebVTT cue text: every <...> tag (classes, voices, karaoke timestamps), then character references.
    static func plainVTT(_ s: String) -> String {
        joinLines(decodeEntities(strip(s, tags: .all, braces: .none, assEscapes: false)))
    }

    /// ASS event text: {...} blocks, \N and \n line breaks, \h hard spaces.
    static func plainASS(_ s: String) -> String {
        joinLines(strip(s, tags: .none, braces: .all, assEscapes: true))
    }

    /// Trims every line and drops the empty ones.
    static func joinLines(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private enum TagMode { case none, letterTags, all }
    private enum BraceMode { case none, overridesOnly, all }

    private static func strip(_ s: String, tags: TagMode, braces: BraceMode, assEscapes: Bool) -> String {
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == "<", tags != .none, let close = closing(">", in: u, from: i + 1) {
                var j = i + 1
                if j < close, u[j] == "/" { j += 1 }
                if tags == .all || (j < close && u[j].properties.isAlphabetic) {
                    i = close + 1
                    continue
                }
            } else if c == "{", braces != .none, let close = closing("}", in: u, from: i + 1) {
                if braces == .all || (i + 1 < close && u[i + 1] == "\\") {
                    i = close + 1
                    continue
                }
            } else if c == "\\", assEscapes, i + 1 < u.count {
                switch u[i + 1] {
                case "N", "n": out.append("\n"); i += 2; continue
                case "h": out.append(" "); i += 2; continue
                default: break
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// Index of `end` on the same line, starting at `from`.
    private static func closing(_ end: Unicode.Scalar, in u: [Unicode.Scalar], from: Int) -> Int? {
        var j = from
        while j < u.count {
            if u[j] == end { return j }
            if u[j] == "\n" { return nil }
            j += 1
        }
        return nil
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "nbsp": " ", "quot": "\"", "apos": "'", "lrm": "", "rlm": "",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";"), let value = entity(after[..<semi]) {
                out += value
                rest = after[after.index(after: semi)...]
            } else {
                out += "&"
                rest = after
            }
        }
        out += rest
        return out
    }

    private static func entity(_ name: Substring) -> String? {
        if let v = entities[String(name)] { return v }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return code.flatMap(Unicode.Scalar.init).map { String($0) }
    }
}
