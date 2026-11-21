import Foundation
import CatalogKit

/// Decides which skip segments to offer for an episode from everything known about it.
public enum SkipResolver {
    /// The segments to offer, by start. In order of trust:
    /// 1. chapters named like an opening, ending, recap or preview — cut for this very file;
    /// 2. the opening and ending found in the episode's audio (`content`), with edges within a few seconds of a
    ///    chapter boundary moved onto it; when the audio shows the episode has no opening (or ending), none is offered;
    /// 3. AniSkip (`catalog`) for what the audio hasn't settled yet, and for recaps and previews. While the audio is
    ///    being analysed, openings AniSkip has only for neighbouring episodes (`isInferred`) are held back: where an
    ///    opening falls depends on the cold open before it, which changes from episode to episode. Pass nil `content`
    ///    when the episode's audio can't be analysed at all (an unsupported container or codec) to use them anyway.
    public static func segments(catalog: [SkipSegment], content: ContentSkips?,
                                chapters: [(name: String, start: Double, end: Double?)], duration: Double) -> [SkipSegment] {
        let analysed = content != nil
        let content = content ?? ContentSkips()
        var decided = Set<SkipSegment.Kind>()
        var fromAudio: [SkipSegment] = []
        for kind in [SkipSegment.Kind.intro, .credits] {
            switch content[kind] {
            case .found(var s):
                // Edges the fingerprint can't reach exactly (its first frame, the end of the file).
                if s.start <= 1 { s.start = 0 }
                if duration > 0 && s.end >= duration - 1 { s.end = duration }
                fromAudio.append(s)
                decided.insert(kind)
            case .absent:
                decided.insert(kind)
            case .unknown:
                break
            }
        }
        let catalog = catalog.filter { s in
            !decided.contains(s.kind) && !(analysed && s.kind == .intro && s.isInferred)
        }
        return ChapterSkips.merged(catalog: fromAudio + catalog, chapters: chapters, duration: duration)
    }

    /// When to offer the next episode: where the ending starts, if one is known in the second half of the episode.
    /// Nil when it isn't (yet) — the player then waits for the end of the file rather than guessing. When story
    /// follows the ending (an epilogue), the card would cover it, so it waits for the preview or the end instead.
    public static func nextEpisodeCue(_ segments: [SkipSegment], duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        let late = segments.filter { $0.start > duration / 2 && $0.start < duration }
        guard let credits = late.filter({ $0.kind == .credits }).min(by: { $0.start < $1.start }) else { return nil }
        let preview = late.filter { $0.kind == .preview && $0.start >= credits.end - 5 }.map(\.start).min()
        if (preview ?? duration) - credits.end > epilogueMinimum { return preview }
        return credits.start
    }

    /// Anything shorter after the ending is a title card or a logo, not story.
    static let epilogueMinimum: Double = 20
}
