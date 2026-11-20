import Foundation

/// ASS/SSA events, reduced to the dialogue a plain secondary-subtitle overlay should show.
enum ASSScript {
    private static let defaultFormat = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    static func parse(_ lines: [Substring]) -> [SubtitleCue] {
        var inEvents = false
        var format = defaultFormat
        var cues: [SubtitleCue] = []
        for raw in lines {
            let line = raw.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            if key == "format" {
                let columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if columns.contains("start") && columns.contains("end") { format = columns }
            } else if key == "dialogue", let cue = dialogue(value, format: format) {
                cues.append(cue)
            }
        }
        return mergeSimultaneous(cues)
    }

    private static func dialogue(_ value: Substring, format: [String]) -> SubtitleCue? {
        let fields = value.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
        guard fields.count == format.count,
              let si = format.firstIndex(of: "start"), let ei = format.firstIndex(of: "end"),
              let start = SubtitleParser.seconds(fields[si]), let end = SubtitleParser.seconds(fields[ei]) else { return nil }
        let style = format.firstIndex(of: "style").map { fields[$0] } ?? ""
        let text = fields[format.firstIndex(of: "text") ?? format.count - 1]
        return cue(start: start, end: end, style: style, text: text)
    }

    /// A cue for one event, or nil when it is typesetting, a sign/song style, or has no text.
    static func cue(start: Double, end: Double, style: Substring, text: Substring) -> SubtitleCue? {
        guard !isSignStyle(style), !isTypesetting(text) else { return nil }
        let plain = SubtitleMarkup.plainASS(String(text))
        return plain.isEmpty ? nil : SubtitleCue(start: start, end: end, text: plain)
    }

    /// Positioned, moved, clipped, drawn or karaoke-timed text: signs and songs rather than dialogue.
    static func isTypesetting(_ text: Substring) -> Bool {
        guard text.contains("\\") else { return false }
        for tag in ["\\pos(", "\\move(", "\\org(", "\\clip(", "\\iclip("] where text.contains(tag) { return true }
        let u = Array(text.unicodeScalars)
        var inBlock = false
        for i in u.indices {
            switch u[i] {
            case "{": inBlock = true
            case "}": inBlock = false
            case "\\" where inBlock && i + 1 < u.count:
                let next = i + 2 < u.count ? u[i + 2] : " "
                switch u[i + 1] {
                case "p" where ("1"..."9").contains(next): return true
                case "k", "K":
                    let digitAfter = i + 3 < u.count && ("0"..."9").contains(u[i + 3])
                    if ("0"..."9").contains(next) || ((next == "f" || next == "o") && digitAfter) { return true }
                default: break
                }
            default: break
            }
        }
        return false
    }

    private static let signWords: Set<String> = [
        "sign", "signs", "song", "songs", "op", "ed", "opening", "ending", "karaoke", "kara", "kfx", "fx",
        "title", "titles", "lyric", "lyrics", "romaji", "kanji", "ts", "typeset", "typesetting", "insert",
    ]
    private static let signPrefixes = ["sign", "song", "karaoke", "kfx", "lyric", "typeset"]

    /// Style names used for signs, songs and titles ("Sign_Board", "OP Romaji", "SongTL", "ED-kfx"), but not
    /// dialogue styles like "Default", "Main", "Italics", "Flashback", "Top" or "Alt".
    static func isSignStyle(_ style: Substring) -> Bool {
        words(style).contains { w in signWords.contains(w) || signPrefixes.contains { w.hasPrefix($0) } }
    }

    /// Lowercased words, split at non-letters, letter/digit changes and camel-case boundaries ("SongTL" -> song, tl).
    static func words(_ s: Substring) -> [String] {
        var out: [String] = []
        var word = ""
        var prev: Character?
        func flush() { if !word.isEmpty { out.append(word.lowercased()); word = "" } }
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else { flush(); prev = nil; continue }
            if let p = prev {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = p.isLowercase && c.isUppercase
                let acronymEnd = p.isUppercase && c.isUppercase && (next?.isLowercase ?? false)
                if p.isNumber != c.isNumber || lowerToUpper || acronymEnd { flush() }
            }
            word.append(c)
            prev = c
        }
        flush()
        return out
    }

    /// Collapses events that share start and end (layered duplicates, split lines) into one cue with unique lines.
    static func mergeSimultaneous(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        struct Key: Hashable { let start: Double; let end: Double }
        var order: [Key] = []
        var lines: [Key: [String]] = [:]
        for c in cues {
            let k = Key(start: c.start, end: c.end)
            if lines[k] == nil { order.append(k) }
            for l in c.text.split(separator: "\n").map(String.init) where !(lines[k]?.contains(l) ?? false) {
                lines[k, default: []].append(l)
            }
        }
        return order.map { SubtitleCue(start: $0.start, end: $0.end, text: lines[$0, default: []].joined(separator: "\n")) }
    }
}
