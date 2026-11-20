import Foundation

/// Display strings for subtitle tracks.
public enum SubtitleLabels {
    private static let iso639_2to1: [String: String] = [
        "eng": "en", "jpn": "ja", "spa": "es", "por": "pt", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
        "ita": "it", "rus": "ru", "ara": "ar", "chi": "zh", "zho": "zh", "kor": "ko", "pol": "pl", "tur": "tr",
        "vie": "vi", "tha": "th", "ind": "id", "may": "ms", "msa": "ms", "hin": "hi", "heb": "he", "dut": "nl",
        "nld": "nl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "ukr": "uk", "cze": "cs", "ces": "cs",
        "hun": "hu", "rum": "ro", "ron": "ro", "gre": "el", "ell": "el",
    ]

    private static let english = Locale(identifier: "en")

    /// Human label: "English", "English (Signs & Songs)", "Japanese", "Track 3". Language display name via
    /// Locale(identifier: "en") with ISO 639-2 -> 639-1 mapping for common codes; a track name that is just the
    /// language again isn't repeated, and one that already starts with it is used as is.
    public static func label(language: String?, name: String?, fallbackIndex: Int) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? nil : trimmed
        guard let lang = languageName(language) else { return title ?? "Track \(fallbackIndex)" }
        guard let title = title else { return lang }
        let code = language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let folded = title.lowercased()
        if folded == lang.lowercased() || folded == code || folded == iso639_2to1[code] { return lang }
        if folded.hasPrefix(lang.lowercased()) { return title }
        return "\(lang) (\(title))"
    }

    /// English display name of an ISO 639-1/639-2 code or BCP-47 tag; nil for missing or undetermined languages.
    static func languageName(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first?.lowercased(), !["und", "zxx", "mis", "mul", "qaa"].contains(first) else { return nil }
        let primary = iso639_2to1[first] ?? first
        if parts.count > 1 {
            let tag = ([primary] + parts.dropFirst()).joined(separator: "-")
            if let name = english.localizedString(forIdentifier: tag), !name.isEmpty, name.lowercased() != tag.lowercased() {
                return name
            }
        }
        if let name = english.localizedString(forLanguageCode: primary), !name.isEmpty, name.lowercased() != primary {
            return name
        }
        return raw
    }

    private static let signWords: Set<String> = ["sign", "signs", "song", "songs", "forced"]

    /// True for "Signs & Songs", "Signs/Songs", "Signs", "Songs", "Forced", "S&S" style tracks (case-insensitive,
    /// word-ish match). Names that also say "Full" or "Dialogue" describe complete tracks and return false.
    public static func isSignsOnly(name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        let words = name.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if words.contains(where: { ["full", "dialogue", "dialog"].contains($0) }) { return false }
        if words.contains(where: { signWords.contains($0) }) { return true }
        let ampersandTokens = name.replacingOccurrences(of: " &", with: "&").replacingOccurrences(of: "& ", with: "&")
            .split { !($0.isLetter || $0.isNumber || $0 == "&") }
        return ampersandTokens.contains("s&s")
    }
}
