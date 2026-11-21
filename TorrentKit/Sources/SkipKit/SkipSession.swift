import Foundation
import CatalogKit

/// Finds the opening and ending of the episode being played, while it downloads, by comparing its audio with other
/// episodes of the same series: ones heard before (kept in a `SkipLibrary`) and any other files being listened to
/// (`addReference`, e.g. the next episode while it prefetches).
public actor SkipSession {
    /// Episodes compared with the one playing, at most.
    public static let maxReferences = 3
    /// More audio than this must have been decoded in an episode before its comparisons are redone.
    static let rematchSeconds: Double = 45

    public nonisolated let series: String?
    public nonisolated let episode: Int?
    private let target: EpisodeListener
    private var themes: [SkipSegment]
    private let library: SkipLibrary?
    private var references: [(listener: EpisodeListener, episode: Int?)] = []
    private var matches: [String: (a: Double, b: Double, complete: Bool, stretches: [SharedStretch])] = [:]
    private var stored: [String: (seconds: Double, complete: Bool)] = [:]
    public private(set) var result: ContentSkips?

    /// `themes` are the openings and endings the target's chapters name, if any. Without a `series` and `episode`,
    /// only the references added here are compared, and nothing is remembered for later episodes.
    public init(target: EpisodeListener, series: String?, episode: Int?, themes: [SkipSegment] = [], library: SkipLibrary?) {
        self.target = target
        self.series = series
        self.episode = episode
        self.themes = themes
        self.library = library
    }

    public func addReference(_ listener: EpisodeListener, episode: Int?) {
        guard listener.id != target.id, !references.contains(where: { $0.listener.id == listener.id }) else { return }
        references.append((listener, episode))
    }

    /// The openings and endings the target's chapters name, once they are known.
    public func setThemes(_ themes: [SkipSegment]) {
        self.themes = themes
    }

    /// Whether the playing file's audio can be analysed at all; false for unsupported files.
    public func isSupported() async -> Bool { await target.state != .unsupported }

    /// Decodes whatever has downloaded since the last call and looks again. Nil when the file can't be analysed
    /// (pass that to `SkipResolver.segments` as is).
    public func refresh() async -> ContentSkips? {
        await target.update()
        guard await target.state != .unsupported else { return nil }
        for r in references { await r.listener.update() }
        guard let mine = await target.audio(themes: themes) else { return ContentSkips() }

        var group = [mine]
        var live: [(EpisodeAudio, Int?)] = []
        for r in references {
            if let a = await r.listener.audio() { live.append((a, r.episode)) }
        }
        group += live.map(\.0).prefix(Self.maxReferences)
        if let library, let series, group.count <= Self.maxReferences {
            let taken = Set(live.compactMap(\.1) + [episode].compactMap { $0 })
            let stored = await library.episodes(series: series).filter { !taken.contains($0.key) }
            // Nearest episodes first: songs change between seasons and cours.
            let nearest = stored.sorted { a, b in
                let da = abs(a.key - (episode ?? 0)), db = abs(b.key - (episode ?? 0))
                return da != db ? da < db : a.key < b.key
            }
            for (n, audio) in nearest.prefix(Self.maxReferences + 1 - group.count) {
                var a = audio
                a.id = "library-\(n)"
                group.append(a)
            }
        }
        guard group.count >= 2 else { return ContentSkips() }

        let found = SkipDetector.analyze(group) { i, j in self.shared(group[i], group[j]) }
        let skips = found[mine.id] ?? ContentSkips()
        result = skips
        await remember(mine, episode: episode)
        for (audio, n) in live { await remember(audio, episode: n) }
        return skips
    }

    private func shared(_ a: EpisodeAudio, _ b: EpisodeAudio) -> [SharedStretch] {
        let key = a.id + "\u{1}" + b.id
        let da = a.print.decodedSeconds, db = b.print.decodedSeconds
        let complete = SkipDetector.isFullyHeard(a) && SkipDetector.isFullyHeard(b)
        if let m = matches[key], da - m.a < Self.rematchSeconds, db - m.b < Self.rematchSeconds, complete == m.complete {
            return m.stretches
        }
        let stretches = PrintMatcher.shared(a.print, b.print, minLength: SkipDetector.minLength)
        matches[key] = (da, db, complete, stretches)
        return stretches
    }

    /// Saves what has been heard of every episode for later sessions, however little was added since the last
    /// save. Call when playback stops.
    public func finish() async {
        await target.update()
        if let a = await target.audio(themes: themes) { await remember(a, episode: episode, always: true) }
        for r in references {
            if let a = await r.listener.audio() { await remember(a, episode: r.episode, always: true) }
        }
    }

    /// Saves an episode's print for later sessions once a good part more of it has been heard.
    private func remember(_ audio: EpisodeAudio, episode: Int?, always: Bool = false) async {
        guard let library, let series, let episode else { return }
        let seconds = audio.print.decodedSeconds
        let complete = SkipDetector.isFullyHeard(audio)
        let last = stored[audio.id] ?? (0, false)
        let enough = always ? seconds > last.seconds : seconds - last.seconds >= 120
        guard enough || (complete && !last.complete) else { return }
        stored[audio.id] = (seconds, complete)
        await library.store(audio, series: series, episode: episode)
    }
}
