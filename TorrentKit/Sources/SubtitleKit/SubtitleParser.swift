import Foundation

/// Parses subtitle files into time-sorted plain-text cues.
public enum SubtitleParser {
    /// Decodes text (UTF-8 with/without BOM, UTF-16 LE/BE with BOM, else Windows-1252/Latin-1 fallback),
    /// normalizes CRLF, parses, drops empty cues, sorts by start.
    public static func parse(_ data: Data, format: SubtitleFormat) -> [SubtitleCue] {
        let text = SubtitleText.decode(data)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cues: [SubtitleCue]
        switch format {
        case .srt: cues = parseSRT(lines)
        case .vtt: cues = parseVTT(lines)
        case .ass: cues = ASSScript.parse(lines)
        }
        return sorted(cues)
    }

    /// Drops cues without text or with an end before their start, then sorts by start (stable for ties).
    static func sorted(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.enumerated()
            .filter { !$0.element.text.isEmpty && $0.element.end >= $0.element.start }
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map { $0.element }
    }

    /// Parses "H:MM:SS.fff", "MM:SS,fff", "H:MM:SS.cc" and similar clock values into seconds.
    static func seconds(_ s: Substring) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts.dropLast() {
            guard !p.isEmpty, p.allSatisfy(\.isASCIIDigit), let v = Double(p) else { return nil }
            total = (total + v) * 60
        }
        let last = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
        let secFrac = last.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = secFrac.first, !whole.isEmpty, whole.allSatisfy(\.isASCIIDigit), let sec = Double(whole) else { return nil }
        total += sec
        if secFrac.count == 2 {
            let frac = secFrac[1]
            guard frac.allSatisfy(\.isASCIIDigit) else { return nil }
            if !frac.isEmpty, let f = Double("0." + frac) { total += f }
        }
        return total
    }

    /// "start --> end [settings]" with anything after the end time ignored.
    static func timing(_ line: Substring) -> (Double, Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let rhs = line[arrow.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        guard let start = seconds(line[..<arrow.lowerBound]), let end = seconds(rhs) else { return nil }
        return (start, end)
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
    }

    static func parseSRT(_ lines: [Substring]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: (start: Double, end: Double)?
        var text: [Substring] = []
        var textEnded = false

        func flush() {
            if let c = current { cues.append(SubtitleCue(start: c.start, end: c.end, text: SubtitleMarkup.plainSRT(text.joined(separator: "\n")))) }
            current = nil
            text = []
            textEnded = false
        }

        for (i, line) in lines.enumerated() {
            if let t = timing(line) {
                flush()
                current = (t.0, t.1)
                continue
            }
            guard current != nil else { continue }
            if isBlank(line) {
                if !text.isEmpty { textEnded = true }
                continue
            }
            if textEnded { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.allSatisfy(\.isASCIIDigit), i + 1 < lines.count, timing(lines[i + 1]) != nil { continue }
            text.append(line)
        }
        flush()
        return cues
    }

    static func parseVTT(_ lines: [Substring]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var i = 0
        var firstBlock = true
        while i < lines.count {
            while i < lines.count && isBlank(lines[i]) { i += 1 }
            let blockStart = i
            while i < lines.count && !isBlank(lines[i]) { i += 1 }
            let block = lines[blockStart..<i]
            guard let first = block.first else { continue }
            defer { firstBlock = false }
            if firstBlock && first.hasPrefix("WEBVTT") { continue }
            if isKeywordBlock(first) { continue }
            guard let timingIndex = block.prefix(2).firstIndex(where: { timing($0) != nil }),
                  let t = timing(block[timingIndex]) else { continue }
            let text = block[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(SubtitleCue(start: t.0, end: t.1, text: SubtitleMarkup.plainVTT(text)))
        }
        return cues
    }

    private static func isKeywordBlock(_ line: Substring) -> Bool {
        for keyword in ["NOTE", "STYLE", "REGION"] where line.hasPrefix(keyword) {
            let rest = line.dropFirst(keyword.count)
            if rest.isEmpty || rest.first == " " || rest.first == "\t" { return true }
        }
        return false
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
