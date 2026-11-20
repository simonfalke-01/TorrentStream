import Foundation

/// One subtitle line shown from `start` to `end` (seconds). `text` is plain: markup removed, lines joined by "\n".
public struct SubtitleCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Text subtitle syntaxes the parser understands.
public enum SubtitleFormat: String, Sendable {
    case srt, vtt, ass

    /// Accepts srt, vtt, webvtt, ass and ssa (case-insensitive, with or without a leading dot).
    public init?(fileExtension: String) {
        var ext = fileExtension.lowercased()
        if ext.hasPrefix(".") { ext.removeFirst() }
        switch ext {
        case "srt": self = .srt
        case "vtt", "webvtt": self = .vtt
        case "ass", "ssa": self = .ass
        default: return nil
        }
    }

    /// Maps a Matroska CodecID. S_TEXT/UTF8 and S_TEXT/ASCII carry SRT-style plain text, S_TEXT/WEBVTT and
    /// WebM's D_WEBVTT/SUBTITLES carry WebVTT cue text, and the ASS/SSA IDs carry ASS event lines.
    public init?(codecID: String) {
        switch codecID.uppercased() {
        case "S_TEXT/UTF8", "S_TEXT/ASCII": self = .srt
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA": self = .ass
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES": self = .vtt
        default: return nil
        }
    }
}

/// A text subtitle track of a Matroska file.
public struct SubtitleTrackInfo: Hashable, Sendable, Identifiable {
    /// Matroska TrackNumber, as used by `MatroskaSubtitleReader.cues(track:from:to:)`.
    public var number: Int
    public var codecID: String
    public var format: SubtitleFormat
    /// BCP-47 from LanguageIETF when present, else the ISO 639-2 Language ("eng" when the element is absent).
    public var language: String?
    public var name: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var id: Int { number }

    public init(number: Int, codecID: String, format: SubtitleFormat, language: String?, name: String?,
                isDefault: Bool, isForced: Bool) {
        self.number = number
        self.codecID = codecID
        self.format = format
        self.language = language
        self.name = name
        self.isDefault = isDefault
        self.isForced = isForced
    }
}
