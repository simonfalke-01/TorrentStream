import Foundation

/// What a release or file name says about the show or movie inside it.
public struct ReleaseInfo: Hashable, Sendable {
    /// Show or movie title without group, episode, quality or codec tags. Empty when the name is only a number.
    public var title: String
    /// Other titles found in parentheses, such as an English name after a romanized one.
    public var altTitles: [String] = []
    public var group: String?
    public var season: Int?
    public var episode: Int?
    /// Last episode of a range such as "01-12".
    public var lastEpisode: Int?
    /// Episode name from scene-style names ("S01E05 The Pilot").
    public var episodeTitle: String?
    /// "2160p", "1080p", "720p" or "480p".
    public var resolution: String?
    public var year: Int?
    /// A whole season or series rather than one episode.
    public var isBatch = false
    /// Named like a fansub release: "[Group] Title - 01".
    public var isAnimeStyle = false

    public init(title: String) { self.title = title }

    /// True when the name points at a series rather than a single film.
    public var isEpisodic: Bool { season != nil || episode != nil || isBatch }
}

public enum ReleaseName {
    private static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "ogv", "rmvb",
        "mp3", "m4a", "flac", "aac", "ogg", "opus", "wav", "srt", "ass", "ssa", "vtt", "sub", "torrent",
    ]

    /// Words that end a title in scene names: quality, source, codec and audio tags.
    private static let junk = #"(?i)\b(2160p|1080p|1080i|720p|576p|480p|4k|uhd|web[ -]?dl|web[ -]?rip|web|blu[ -]?ray|bdrip|brrip|bdremux|bd|hdtv|dvdrip|dvd|remux|x264|x265|h[ .]?264|h[ .]?265|hevc|avc|av1|10 ?bit|8 ?bit|hdr10|hdr|dovi|aac\S*|ac3|e?ac3|ddp?[0-9. ]*|dts\S*|truehd|atmos|flac|opus|dual[ -]audio|multi[ -]?audio|multi[ -]?subs?|eng[ -]?subs?|proper|repack|internal|amzn|nf|dsnp|hmax|atvp|cr|uncensored|batch|complete)\b"#

    public static func parse(_ name: String) -> ReleaseInfo {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (s as NSString).pathExtension.lowercased()
        if mediaExtensions.contains(ext) { s = (s as NSString).deletingPathExtension }

        var info = ReleaseInfo(title: "")
        info.resolution = resolution(in: s)

        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let g = String(s[s.index(after: s.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: close)...])
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                info.group = g.isEmpty ? nil : g
                info.isAnimeStyle = true
                s = rest
            }
        }

        // Bracketed tags: read what they say, then drop them.
        for tag in matches(#"[\[({]([^\])}]*)[\])}]"#, in: s) {
            let t = (tag[1] ?? "").trimmingCharacters(in: .whitespaces)
            if let y = Int(t), (1920...2099).contains(y) { info.year = y; continue }
            if t.range(of: #"(?i)\b(batch|complete)\b"#, options: .regularExpression) != nil { info.isBatch = true }
            if let n = firstInt(#"(?i)\bseason\s*(\d{1,2})\b"#, in: t) ?? firstInt(#"(?i)^s(\d{1,2})$"#, in: t) {
                info.season = n
                continue
            }
            if let r = matches(#"^(\d{1,4})\s*[-~]\s*(\d{1,4})$"#, in: t).first {
                info.episode = r[1].flatMap(Int.init); info.lastEpisode = r[2].flatMap(Int.init); info.isBatch = true
                continue
            }
            let isTechnical = t.range(of: junk, options: .regularExpression) != nil
                || t.range(of: #"^[0-9A-Fa-f]{8}$"#, options: .regularExpression) != nil
            if !isTechnical, t.range(of: #"\p{L}{3}"#, options: .regularExpression) != nil, tag[0]?.hasPrefix("(") == true {
                info.altTitles.append(t)
            }
        }
        s = s.replacingOccurrences(of: #"[\[({][^\])}]*[\])}]"#, with: " ", options: .regularExpression)
        s = sceneSpaces(s)

        var title = s
        if let m = matches(#"(?i)\bS(\d{1,2})[ ._-]?E(\d{1,4})(?:-?E(\d{1,4}))?\b"#, in: s, ranges: true).first {
            info.season = m.groups[1].flatMap(Int.init); info.episode = m.groups[2].flatMap(Int.init)
            if let last = m.groups[3].flatMap(Int.init), last > (info.episode ?? 0) { info.lastEpisode = last }
            title = String(s[..<m.range.lowerBound])
            let after = cutAtJunk(String(s[m.range.upperBound...]))
            if after.range(of: #"\p{L}{2}"#, options: .regularExpression) != nil { info.episodeTitle = after }
        } else if let m = matches(#"\b(\d{1,2})x(\d{2,3})\b"#, in: s, ranges: true).first {
            info.season = m.groups[1].flatMap(Int.init); info.episode = m.groups[2].flatMap(Int.init)
            title = String(s[..<m.range.lowerBound])
        } else if let m = matches(#"\s[-–]\s*(\d{1,4})(?:v\d)?(?:\s*[-~]\s*(\d{1,4})(?:v\d)?)?(?=\s|$)"#, in: s, ranges: true).last,
                  let n = Int(m.groups[1]!), !isYear(n) {
            info.episode = n
            if let last = m.groups[2].flatMap(Int.init) { info.lastEpisode = last; info.isBatch = true }
            title = String(s[..<m.range.lowerBound])
        } else if let m = matches(#"(?i)(?:^|\s)(?:episode|ep\.?|e)\s?(\d{1,4})\b"#, in: s, ranges: true).first {
            info.episode = Int(m.groups[1]!)
            title = String(s[..<m.range.lowerBound])
        } else if let m = matches(#"第\s*(\d{1,4})\s*[話话集]"#, in: s, ranges: true).first {
            info.episode = Int(m.groups[1]!)
            title = String(s[..<m.range.lowerBound])
        } else if let m = matches(#"(?i)\bS(\d{1,2})\b(?!\w)"#, in: s, ranges: true).first {
            info.season = Int(m.groups[1]!)
            info.isBatch = true
            title = String(s[..<m.range.lowerBound])
        } else {
            title = cutAtJunk(s)
            if let m = matches(#"(?:^|\s)(\d{1,4})(?:v\d)?\s*$"#, in: title, ranges: true).last,
               let n = Int(m.groups[1]!), !isYear(n) {
                info.episode = n
                title = String(title[..<m.range.lowerBound])
            }
        }
        title = cutAtJunk(title)

        // "Title 2019" in scene movie names.
        if let m = matches(#"\s((?:19|20)\d\d)\s*$"#, in: title, ranges: true).last {
            let before = String(title[..<m.range.lowerBound])
            if !clean(before).isEmpty {
                info.year = info.year ?? Int(m.groups[1]!)
                title = before
            }
        }
        // "Title S2", "Title Season 2", "Title 2nd Season".
        if let m = matches(#"(?i)\s(?:S|Season\s*)(\d{1,2})\s*$"#, in: title, ranges: true).last {
            info.season = info.season ?? Int(m.groups[1]!)
            title = String(title[..<m.range.lowerBound])
        } else if let m = matches(#"(?i)\s(\d{1,2})(?:st|nd|rd|th)\s+season\s*$"#, in: title, ranges: true).last {
            info.season = info.season ?? Int(m.groups[1]!)
            title = String(title[..<m.range.lowerBound])
        }

        info.title = clean(title)
        if info.season != nil && info.episode == nil { info.isBatch = true }
        return info
    }

    /// Lowercased words without punctuation or accents, for comparing titles.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// 0...1 word overlap between two titles (Dice coefficient).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(normalize(a).split(separator: " ")), y = Set(normalize(b).split(separator: " "))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    // MARK: helpers

    private static func isYear(_ n: Int) -> Bool { (1920...2099).contains(n) }

    private static func resolution(in s: String) -> String? {
        guard let m = matches(#"(?i)\b(2160|1080|720|576|480)[pi]\b|\b(4K|UHD)\b"#, in: s).first else { return nil }
        if let r = m[1], !r.isEmpty { return r + "p" }
        return "2160p"
    }

    /// Turns dots and underscores used as word separators into spaces, keeping "5.1" and "H.264".
    private static func sceneSpaces(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "_", with: " ")
        let dots = s.filter { $0 == "." }.count
        let spaces = s.filter { $0 == " " }.count
        guard dots >= 2, dots > spaces else { return s }
        let mark = "\u{1}"
        s = s.replacingOccurrences(of: #"(?<![0-9])([0-9])\.([0-9])(?![0-9])"#, with: "$1\(mark)$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b([Hh])\.(26[456])\b"#, with: "$1\(mark)$2", options: .regularExpression)
        return s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: mark, with: ".")
    }

    private static func cutAtJunk(_ s: String) -> String {
        guard let r = s.range(of: junk, options: .regularExpression) else { return clean(s) }
        return clean(String(s[..<r.lowerBound]))
    }

    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_:|.,~+").union(.whitespaces))
        return t
    }

    private static func firstInt(_ pattern: String, in s: String) -> Int? {
        matches(pattern, in: s).first.flatMap { $0[1] }.flatMap(Int.init)
    }

    private static func matches(_ pattern: String, in s: String) -> [[String?]] {
        matches(pattern, in: s, ranges: true).map(\.groups)
    }

    private struct Match {
        let range: Range<String.Index>
        let groups: [String?]
    }

    private static func matches(_ pattern: String, in s: String, ranges: Bool) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: ns).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            let groups: [String?] = (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: s).map { String(s[$0]) }
            }
            return Match(range: r, groups: groups)
        }
    }
}

