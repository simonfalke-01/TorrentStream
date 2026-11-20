import Foundation

/// Technical details a release name states: quality, codec, source and languages.
public struct ReleaseTraits: Codable, Hashable, Sendable {
    /// Vertical resolution: 2160, 1080, 720, 576 or 480.
    public var resolution: Int?
    /// "HEVC", "AVC", "AV1" or "VP9".
    public var codec: String?
    public var is10bit = false
    public var hdr = false
    /// "Blu-ray", "Web", "DVD" or "TV".
    public var source: String?
    /// Japanese and English audio.
    public var dualAudio = false
    /// English audio only.
    public var dubbed = false
    public var multiSubs = false
    /// "FLAC", "Opus", "AAC", "E-AC-3", "AC-3", "DTS" or "TrueHD".
    public var audio: String?
    public var remux = false
    /// Release revision, such as v2.
    public var version: Int?

    public init() {}

    /// Has English audio, whether dubbed only or alongside Japanese.
    public var hasEnglishAudio: Bool { dualAudio || dubbed }

    /// "1080p", "4K", or nil.
    public var resolutionLabel: String? {
        guard let r = resolution else { return nil }
        return r >= 2160 ? "4K" : "\(r)p"
    }

    /// Short labels for what sets this release apart, in reading order.
    public var labels: [String] {
        var out: [String] = []
        if let codec { out.append(is10bit ? "\(codec) 10-bit" : codec) } else if is10bit { out.append("10-bit") }
        if hdr { out.append("HDR") }
        if let source { out.append(remux ? "\(source) Remux" : source) }
        if dualAudio { out.append("Dual Audio") } else if dubbed { out.append("English Dub") }
        if multiSubs { out.append("Multi-Sub") }
        if let audio { out.append(audio) }
        return out
    }

    public static func parse(_ name: String) -> ReleaseTraits {
        var t = ReleaseTraits()
        let s = name.replacingOccurrences(of: "_", with: " ")
        if let r = first(#"(?i)\b(2160|1080|720|576|480)[pi]\b"#, in: s).flatMap(Int.init) {
            t.resolution = r
        } else if has(#"(?i)\b(4k|uhd)\b"#, s) {
            t.resolution = 2160
        } else if let r = first(#"\b(?:3840|1920|1280|960|854|848|720|640)\s*[x×]\s*(2160|1080|720|576|540|480)\b"#, in: s).flatMap(Int.init) {
            t.resolution = r == 540 ? 576 : r
        }
        if has(#"(?i)\b(hevc|x\.?265|h\.?265)\b"#, s) {
            t.codec = "HEVC"
        } else if has(#"(?i)\bav1\b"#, s) {
            t.codec = "AV1"
        } else if has(#"(?i)\bvp9\b"#, s) {
            t.codec = "VP9"
        } else if has(#"(?i)\b(avc|x\.?264|h\.?264)\b"#, s) {
            t.codec = "AVC"
        }
        t.is10bit = has(#"(?i)\b(10[ -]?bits?|hi10p?|10bpc|yuv420p10|main ?10)\b"#, s)
        t.hdr = has(#"(?i)\b(hdr10\+?|hdr|dovi|dolby ?vision)\b"#, s)
        t.remux = has(#"(?i)\b(remux|bdmv)\b"#, s)
        if has(#"(?i)\b(blu[ -]?ray|bd ?rip|bd ?remux|bdmv|bd)\b"#, s) {
            t.source = "Blu-ray"
        } else if has(#"(?i)\b(web[ -]?dl|web[ -]?rip|web|cr|amzn|nf|dsnp|hidive|adn|b-global|crunchyroll|netflix)\b"#, s) {
            t.source = "Web"
        } else if has(#"(?i)\b(dvd ?rip|dvd)\b"#, s) {
            t.source = "DVD"
        } else if has(#"(?i)\b(hdtv|tv ?rip|tv)\b"#, s) {
            t.source = "TV"
        }
        t.dualAudio = has(#"(?i)\b(dual[ -]?audio|multi[ -]?audio|jpn?[ +&]eng?)\b"#, s)
        t.dubbed = !t.dualAudio && has(#"(?i)\b(english[ -]?dub(bed)?|eng[ -]?dub|dubbed|dub)\b"#, s)
        t.multiSubs = has(#"(?i)\b(multi[ -]?subs?|multiple[ -]?subtitles?|multi[ -]?subtitles?)\b"#, s)
        if has(#"(?i)\bflac\b"#, s) {
            t.audio = "FLAC"
        } else if has(#"(?i)\btruehd\b"#, s) {
            t.audio = "TrueHD"
        } else if has(#"(?i)\bdts"#, s) {
            t.audio = "DTS"
        } else if has(#"(?i)\b(e-?ac-?3|ddp|dd\+)"#, s) {
            t.audio = "E-AC-3"
        } else if has(#"(?i)\b(ac-?3|dd[ ]?[25]\.[01])\b"#, s) {
            t.audio = "AC-3"
        } else if has(#"(?i)\bopus\b"#, s) {
            t.audio = "Opus"
        } else if has(#"(?i)\baac"#, s) {
            t.audio = "AAC"
        }
        t.version = first(#"(?i)\b\d{1,4}v(\d)\b"#, in: s).flatMap(Int.init)
        return t
    }

    static func has(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func first(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
