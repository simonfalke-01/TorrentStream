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
        let name = style.trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? nil : SubtitleCue(start: start, end: end, text: plain, style: name.isEmpty ? nil : name)
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
        var styles: [Key: String] = [:]
        for c in cues {
            let k = Key(start: c.start, end: c.end)
            if lines[k] == nil { order.append(k) }
            if styles[k] == nil, let s = c.style { styles[k] = s }
            for l in c.text.split(separator: "\n").map(String.init) where !(lines[k]?.contains(l) ?? false) {
                lines[k, default: []].append(l)
            }
        }
        return order.map { SubtitleCue(start: $0.start, end: $0.end, text: lines[$0, default: []].joined(separator: "\n"), style: styles[$0]) }
    }
}

/// One style of an ASS script's [V4+ Styles] (or SSA's [V4 Styles]) section, in script pixels.
public struct ASSStyle: Hashable, Sendable {
    public var name = "Default"
    public var fontName = "Arial"
    public var fontSize: Double = 20
    /// Colours as ASS writes them: 0xAABBGGRR, alpha 0 opaque.
    public var primaryColour: UInt32 = 0x00FF_FFFF
    public var outlineColour: UInt32 = 0x0000_0000
    public var backColour: UInt32 = 0x0000_0000
    public var bold = false
    public var italic = false
    public var scaleX: Double = 100
    public var scaleY: Double = 100
    public var spacing: Double = 0
    /// 1: outline and shadow; 3: an opaque box in the outline colour.
    public var borderStyle = 1
    public var outline: Double = 2
    public var shadow: Double = 2
    /// Numpad layout: 1-3 bottom, 4-6 middle, 7-9 top; left, center, right.
    public var alignment = 2
    public var marginL: Double = 10
    public var marginR: Double = 10
    public var marginV: Double = 10

    public init() {}
}

/// What an ASS script's header says about drawing its lines: the script resolution and the styles.
public struct ASSHeader: Hashable, Sendable {
    public var playResX: Double
    public var playResY: Double
    public var styles: [ASSStyle]

    public init(playResX: Double, playResY: Double, styles: [ASSStyle]) {
        self.playResX = playResX
        self.playResY = playResY
        self.styles = styles
    }

    /// The style by name as VSFilter finds it (any case, a leading `*` ignored), else Default, else the first.
    public func style(named name: String?) -> ASSStyle? {
        func key(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("*") { t.removeFirst() }
            return t.lowercased()
        }
        if let name {
            let k = key(name)
            if let s = styles.first(where: { key($0.name) == k }) { return s }
        }
        return styles.first { key($0.name) == "default" } ?? styles.first
    }

    /// Reads [Script Info] and the styles section of a script or a Matroska track's CodecPrivate.
    public static func parse(_ text: String) -> ASSHeader {
        var resX: Double?, resY: Double?
        var styles: [ASSStyle] = []
        var section = ""
        var format = ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour", "backcolour",
                      "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing", "angle", "borderstyle",
                      "outline", "shadow", "alignment", "marginl", "marginr", "marginv", "encoding"]
        for raw in SubtitleText.normalizeNewlines(text).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.lowercased()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "[script info]":
                if key == "playresx" { resX = Double(value).flatMap { $0 > 0 ? $0 : nil } }
                if key == "playresy" { resY = Double(value).flatMap { $0 > 0 ? $0 : nil } }
            case "[v4+ styles]", "[v4 styles]", "[v4 styles+]":
                if key == "format" {
                    format = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if key == "style" {
                    let fields = value.split(separator: ",", maxSplits: max(0, format.count - 1), omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    styles.append(style(fields, format: format, legacy: section == "[v4 styles]"))
                }
            default: break
            }
        }
        // libass's defaults when the script leaves the resolution out.
        let y = resY ?? resX.map { $0 == 1280 ? 1024 : $0 * 3 / 4 } ?? 288
        let x = resX ?? (resY.map { $0 == 1024 ? 1280 : $0 * 4 / 3 } ?? 384)
        return ASSHeader(playResX: x, playResY: y, styles: styles)
    }

    private static func style(_ fields: [String], format: [String], legacy: Bool) -> ASSStyle {
        var s = ASSStyle()
        for (i, column) in format.enumerated() where i < fields.count {
            let v = fields[i]
            let n = Double(v)
            switch column {
            case "name": s.name = v
            case "fontname": s.fontName = v
            case "fontsize": if let n, n > 0 { s.fontSize = n }
            case "primarycolour": if let c = colour(v) { s.primaryColour = c }
            case "outlinecolour", "tertiarycolour": if let c = colour(v) { s.outlineColour = c }
            case "backcolour": if let c = colour(v) { s.backColour = c }
            case "bold": s.bold = (n ?? 0) != 0
            case "italic": s.italic = (n ?? 0) != 0
            case "scalex": if let n, n > 0 { s.scaleX = n }
            case "scaley": if let n, n > 0 { s.scaleY = n }
            case "spacing": s.spacing = n ?? 0
            case "borderstyle": s.borderStyle = Int(n ?? 1)
            case "outline": s.outline = max(0, n ?? 0)
            case "shadow": s.shadow = max(0, n ?? 0)
            case "alignment":
                let a = Int(n ?? 2)
                s.alignment = legacy ? legacyAlignment(a) : (1...9 ~= a ? a : 2)
            case "marginl": s.marginL = n ?? 0
            case "marginr": s.marginR = n ?? 0
            case "marginv": s.marginV = n ?? 0
            default: break
            }
        }
        return s
    }

    /// SSA numbers alignment 1-3 bottom, 9-11 middle, 5-7 top.
    private static func legacyAlignment(_ a: Int) -> Int {
        let column = a & 3
        guard 1...3 ~= column else { return 2 }
        if a & 8 != 0 { return column + 3 }
        if a & 4 != 0 { return column + 6 }
        return column
    }

    /// `&H00FFFFFF`, `&HFFFFFF&`, `H0000FF` or a decimal number.
    static func colour(_ v: String) -> UInt32? {
        var t = Substring(v.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("&") { t = t.dropFirst() }
        if t.hasSuffix("&") { t = t.dropLast() }
        if t.first == "H" || t.first == "h" {
            t = t.dropFirst()
            return UInt64(t, radix: 16).map { UInt32(truncatingIfNeeded: $0) }
        }
        return Int64(t).map { UInt32(truncatingIfNeeded: $0) }
    }
}
