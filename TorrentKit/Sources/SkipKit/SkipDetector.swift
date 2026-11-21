import Foundation
import CatalogKit

/// What is known about one episode's audio.
public struct EpisodeAudio: Sendable, Codable, Equatable {
    /// Identifies the episode among the others it is compared with.
    public var id: String
    /// Length of the file in seconds.
    public var duration: Double
    public var print: AudioPrint
    /// Openings and endings already known for this episode, from its chapter names. Their bounds are used as given.
    public var themes: [SkipSegment]

    public init(id: String, duration: Double, print: AudioPrint, themes: [SkipSegment] = []) {
        self.id = id
        self.duration = duration
        self.print = print
        self.themes = themes
    }
}

/// Whether an episode has an opening (or an ending) and where.
public enum SkipVerdict: Sendable, Equatable, Codable {
    /// Not enough of this episode or its neighbours has been heard to tell.
    case unknown
    /// The neighbours share one, and all of this episode has been heard without finding it.
    case absent
    case found(SkipSegment)

    public var segment: SkipSegment? {
        if case .found(let s) = self { return s }
        return nil
    }
}

/// Opening and ending of one episode as found in its audio.
public struct ContentSkips: Sendable, Equatable, Codable {
    public var intro: SkipVerdict
    public var credits: SkipVerdict

    public init(intro: SkipVerdict = .unknown, credits: SkipVerdict = .unknown) {
        self.intro = intro
        self.credits = credits
    }

    public subscript(kind: SkipSegment.Kind) -> SkipVerdict {
        get { kind == .intro ? intro : kind == .credits ? credits : .unknown }
        set {
            if kind == .intro { intro = newValue } else if kind == .credits { credits = newValue }
        }
    }

    public var segments: [SkipSegment] { [intro.segment, credits.segment].compactMap { $0 }.sorted { $0.start < $1.start } }
}

/// Finds each episode's opening and ending song by comparing the audio of episodes of the same series.
///
/// A theme song is the longest audio several episodes have in common, wherever it falls: after a cold open of any
/// length, at the very start, or played over the final scene. Each pair of episodes is lined up (`PrintMatcher`);
/// stretches that line up are joined across episodes into groups — one group per song, one stretch per episode it
/// plays in. A group heard in three or more episodes is a theme; one heard in only two is a theme if it falls in
/// the same half of both and lasts at least `pairMinLength`, as a recap (an earlier episode's end replayed at the
/// start of the next) or a preview (the next episode's scenes after the ending) lands in different halves.
/// A theme in the first half of an episode is its intro, in the second half its credits.
public enum SkipDetector {
    /// Shorter shared audio (an eyecatch, a sound logo, a repeated sound effect) is not a theme.
    public static let minLength: Double = 15
    /// Audio only two episodes share must last this long to count as a theme.
    public static let pairMinLength: Double = 20
    /// Longest undecoded stretch an episode can have and still count as fully heard: shorter than any theme.
    static let maxSeam: Double = 2

    /// Whether all of an episode's audio has been decoded, but for seams too short to hide a theme in.
    public static func isFullyHeard(_ e: EpisodeAudio) -> Bool {
        e.duration > 0 && e.print.longestGap(from: 1, to: e.duration - 1) <= maxSeam
    }

    /// The intro and credits of each of `episodes`, by id. `shared(i, j)` gives the stretches episodes `i` and `j`
    /// have in common, timed in `i` (callers cache these; by default they are computed).
    public static func analyze(_ episodes: [EpisodeAudio],
                               shared: ((Int, Int) -> [SharedStretch])? = nil) -> [String: ContentSkips] {
        let match = shared ?? { PrintMatcher.shared(episodes[$0].print, episodes[$1].print, minLength: minLength) }
        var nodes: [Node] = []
        var edges: [(Int, Int)] = []
        for i in episodes.indices {
            for j in episodes.indices where j > i {
                for s in match(i, j) where s.length >= minLength {
                    let a = nodes.count
                    nodes.append(Node(episode: i, start: s.start, end: s.end))
                    nodes.append(Node(episode: j, start: s.otherStart, end: s.otherEnd))
                    edges.append((a, a + 1))
                }
            }
        }
        var groups = UnionFind(nodes.count)
        for (a, b) in edges { groups.union(a, b) }
        // Stretches of one episode that overlap are the same audio heard from different partners.
        for a in nodes.indices {
            for b in nodes.indices where b > a && nodes[a].episode == nodes[b].episode {
                let overlap = min(nodes[a].end, nodes[b].end) - max(nodes[a].start, nodes[b].start)
                if overlap > 0.5 * min(nodes[a].end - nodes[a].start, nodes[b].end - nodes[b].start) { groups.union(a, b) }
            }
        }

        // Each episode's estimate of the group's span, one per partner it was matched with.
        struct Estimate { var start: Double; var end: Double; var cleanStart: Bool; var cleanEnd: Bool }
        var estimates: [Int: [Int: [Estimate]]] = [:]   // group -> episode -> estimates
        for (a, b) in edges {
            for (x, y) in [(a, b), (b, a)] {
                let nx = nodes[x], ny = nodes[y]
                var start = nx.start, end = nx.end
                // A partner's known theme bounds the song in this episode too.
                let offset = nx.start - ny.start
                if let known = episodes[ny.episode].themes.first(where: { $0.start < ny.end && ny.start < $0.end }) {
                    start = max(start, known.start + offset)
                    end = min(end, known.end + offset)
                }
                guard end - start >= minLength else { continue }
                let px = episodes[nx.episode].print, py = episodes[ny.episode].print
                let cleanStart = heardBefore(px, start) && heardBefore(py, start - offset)
                let cleanEnd = heardAfter(px, end, duration: episodes[nx.episode].duration)
                    && heardAfter(py, end - offset, duration: episodes[ny.episode].duration)
                estimates[groups.find(x), default: [:]][nx.episode, default: []]
                    .append(Estimate(start: start, end: end, cleanStart: cleanStart, cleanEnd: cleanEnd))
            }
        }

        var candidates: [Int: [Candidate]] = [:]   // episode -> candidates
        for (_, byEpisode) in estimates {
            let support = byEpisode.count
            guard support >= 2 else { continue }
            var spans: [Int: (start: Double, end: Double, clean: Bool, kind: SkipSegment.Kind)] = [:]
            for (e, list) in byEpisode {
                // The lower median of what the partners say. Partners can disagree by several seconds where the
                // song is talked over in one episode, or one shares a few more seconds after it (a recurring title
                // card, a scene replayed from the previous episode); with two, the earlier start and the earlier end
                // are taken, as offering the skip a little early costs less than skipping past the start of the story.
                let starts = list.filter(\.cleanStart).map(\.start).sorted()
                let ends = list.filter(\.cleanEnd).map(\.end).sorted()
                let start = starts.isEmpty ? list.map(\.start).min()! : starts[(starts.count - 1) / 2]
                let end = ends.isEmpty ? list.map(\.end).max()! : ends[(ends.count - 1) / 2]
                let kind: SkipSegment.Kind = (start + end) / 2 < episodes[e].duration / 2 ? .intro : .credits
                spans[e] = (start, end, !starts.isEmpty && !ends.isEmpty, kind)
            }
            let knownTheme = byEpisode.keys.contains { e in
                let s = spans[e]!
                return episodes[e].themes.contains { $0.start < s.end && s.start < $0.end }
            }
            if support == 2 && !knownTheme {
                let kinds = Set(spans.values.map(\.kind))
                guard kinds.count == 1, spans.values.allSatisfy({ $0.end - $0.start >= pairMinLength }) else { continue }
            }
            for (e, s) in spans where s.end - s.start >= minLength {
                candidates[e, default: []].append(Candidate(segment: SkipSegment(kind: s.kind, start: s.start, end: s.end),
                                                            support: support, clean: s.clean))
            }
        }

        var out: [String: ContentSkips] = [:]
        for (e, episode) in episodes.enumerated() {
            var skips = ContentSkips()
            for kind in [SkipSegment.Kind.intro, .credits] {
                let mine = (candidates[e] ?? []).filter { $0.segment.kind == kind }
                if let best = mine.max(by: { ($0.support, $0.segment.end - $0.segment.start) < ($1.support, $1.segment.end - $1.segment.start) }) {
                    skips[kind] = best.clean ? .found(best.segment) : .unknown
                } else if hasTheme(kind, besides: e, episodes: episodes, candidates: candidates), isFullyHeard(episode) {
                    skips[kind] = .absent
                }
            }
            out[episode.id] = skips
        }
        return out
    }

    /// Whether episodes other than `e` show the series has a theme of `kind`: two of them share one, or one has it in
    /// its chapters and has been heard there.
    private static func hasTheme(_ kind: SkipSegment.Kind, besides e: Int, episodes: [EpisodeAudio],
                                 candidates: [Int: [Candidate]]) -> Bool {
        let found = candidates.filter { $0.key != e && $0.value.contains { $0.clean && $0.segment.kind == kind } }.count
        if found >= 2 { return true }
        return episodes.indices.contains { i in
            i != e && episodes[i].themes.contains { $0.kind == kind && episodes[i].print.coverage(from: $0.start, to: $0.end) >= 0.95 }
        }
    }

    private struct Candidate { var segment: SkipSegment; var support: Int; var clean: Bool }

    /// Whether the second before `t` has been decoded, so a stretch starting at `t` really starts there.
    static func heardBefore(_ p: AudioPrint, _ t: Double) -> Bool {
        t <= 1 || p.coverage(from: t - 1, to: t) >= 0.75
    }

    static func heardAfter(_ p: AudioPrint, _ t: Double, duration: Double) -> Bool {
        t >= duration - 1 || p.coverage(from: t, to: t + 1) >= 0.75
    }

    private struct Node {
        var episode: Int
        var start: Double
        var end: Double
    }
}

struct UnionFind {
    private var parent: [Int]

    init(_ n: Int) { parent = Array(0..<n) }

    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var y = x
        while parent[y] != r { let next = parent[y]; parent[y] = r; y = next }
        return r
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
}
