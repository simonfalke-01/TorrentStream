import Foundation
import CatalogKit
import NyaaKit

/// One release that plays a given episode or movie.
public struct EpisodeSource: Identifiable, Hashable, Sendable {
    public let result: NyaaResult
    public let release: ReleaseInfo
    public let traits: ReleaseTraits
    /// A pack of episodes; the episode is one file inside it.
    public let isBatch: Bool
    public let score: Double
    public var id: Int { result.id }
    public var group: String? { release.group }
}

/// What the viewer prefers when several releases play the same episode.
public struct SourcePreferences: Codable, Hashable, Sendable {
    /// Wanted vertical resolution. Nil picks the best that streams well (1080p).
    public var resolution: Int?
    /// English audio over Japanese.
    public var preferDub: Bool
    /// Release group chosen for this show before.
    public var group: String?

    public init(resolution: Int? = 1080, preferDub: Bool = false, group: String? = nil) {
        self.resolution = resolution
        self.preferDub = preferDub
        self.group = group
    }
}

/// Finds the releases on Nyaa that play an episode of a catalog show, best first.
public final class SourceFinder: @unchecked Sendable {
    private let nyaa: NyaaClient

    public init(nyaa: NyaaClient) {
        self.nyaa = nyaa
    }

    /// `provisional` is called with the releases ranked so far each time one of the searches answers before the
    /// last (and before a second round of searches), so the caller can start fetching the likely winners' .torrent
    /// files while the rest are still running.
    public func sources(for details: ShowDetails, season: ShowSeason, episode: ShowEpisode,
                        prefs: SourcePreferences,
                        provisional: (@Sendable ([EpisodeSource]) -> Void)? = nil) async throws -> [EpisodeSource] {
        try await run(details: details, season: season, episode: episode, prefs: prefs) { partial, _ in provisional?(partial) }
    }

    /// Like `sources`, but returns as soon as a confident pick is ranked first (`isConfident`): once the episode's
    /// own search has answered, or earlier when an answer already on hand (the season-wide search a warm-up made)
    /// holds a single-episode release with a large swarm. The other searches go on; `completed` gets the full list
    /// (also when it is what's returned).
    public func quickSources(for details: ShowDetails, season: ShowSeason, episode: ShowEpisode,
                             prefs: SourcePreferences,
                             provisional: (@Sendable ([EpisodeSource]) -> Void)? = nil,
                             completed: (@Sendable ([EpisodeSource]) -> Void)? = nil) async throws -> [EpisodeSource] {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { cont in
            gate.set(cont)
            Task {
                do {
                    let list = try await self.run(details: details, season: season, episode: episode, prefs: prefs) { partial, specific in
                        provisional?(partial)
                        if let top = partial.first, Self.isConfident(top, prefs: prefs, episodeSearched: specific) {
                            gate.finish(.success(partial))
                        }
                    }
                    gate.finish(.success(list))
                    completed?(list)
                } catch {
                    gate.finish(.failure(error))
                }
            }
        }
    }

    /// A release worth starting without waiting for the remaining searches: the wanted resolution (and audio, and
    /// the show's group when one was chosen) with a healthy swarm. Before the episode's own search answered, only a
    /// single-episode release with a large swarm qualifies, since that search may still find a better one.
    static func isConfident(_ s: EpisodeSource, prefs: SourcePreferences, episodeSearched: Bool) -> Bool {
        guard s.traits.resolution == (prefs.resolution ?? 1080) else { return false }
        if let g = prefs.group, ReleaseName.normalize(g) != ReleaseName.normalize(s.release.group ?? "") { return false }
        if prefs.preferDub && !s.traits.hasEnglishAudio { return false }
        if episodeSearched { return s.result.seeders >= 10 }
        return !s.isBatch && s.result.seeders >= 30
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<[EpisodeSource], Error>?
        func set(_ c: CheckedContinuation<[EpisodeSource], Error>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ r: Result<[EpisodeSource], Error>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(with: r)
        }
    }

    /// `partial` gets the ranking so far and whether the episode's own search (the first query) has answered.
    private func run(details: ShowDetails, season: ShowSeason, episode: ShowEpisode, prefs: SourcePreferences,
                     partial: @escaping @Sendable ([EpisodeSource], Bool) -> Void) async throws -> [EpisodeSource] {
        let queries = Self.queries(details: details, season: season, episode: episode)
        var results = try await search(queries) { found, answered in
            partial(Self.rank(found, details: details, season: season, episode: episode, prefs: prefs), answered.contains(0))
        }
        var sources = Self.rank(results, details: details, season: season, episode: episode, prefs: prefs)
        if sources.count < 3 {
            let extra = Self.fallbackQueries(details: details, season: season, episode: episode).filter { !queries.contains($0) }
            if !extra.isEmpty {
                // What the first round found may already do.
                if !sources.isEmpty { partial(sources, true) }
                if let more = try? await search(extra, partial: nil) {
                    results += more
                    sources = Self.rank(results, details: details, season: season, episode: episode, prefs: prefs)
                }
            }
        }
        return sources
    }

    /// Answers by query, kept a few minutes: a show page's warm-up searches the whole season, and an episode tapped
    /// next reuses that answer.
    private final class AnswerCache: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [NyaaQuery: (at: Date, results: [NyaaResult])] = [:]

        func get(_ q: NyaaQuery) -> [NyaaResult]? {
            lock.lock(); defer { lock.unlock() }
            guard let a = answers[q], Date().timeIntervalSince(a.at) < SourceFinder.answerLifetime else { return nil }
            return a.results
        }

        func put(_ q: NyaaQuery, _ results: [NyaaResult]) {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            answers = answers.filter { now.timeIntervalSince($0.value.at) < SourceFinder.answerLifetime }
            answers[q] = (now, results)
        }

        func clear() { lock.lock(); answers.removeAll(); lock.unlock() }
    }

    private static let answers = AnswerCache()
    static let answerLifetime: TimeInterval = 300

    /// Forgets the search answers kept, so the next search asks Nyaa again.
    public static func forgetSearches() { answers.clear() }

    /// Runs searches side by side, answers kept from a moment ago first. Fails only when every one fails. `partial`
    /// gets what was found so far and which queries (by position) answered, each time before the last.
    private func search(_ queries: [NyaaQuery], partial: (([NyaaResult], Set<Int>) -> Void)?) async throws -> [NyaaResult] {
        var out: [NyaaResult] = []
        var answered = Set<Int>()
        for (i, q) in queries.enumerated() {
            if let r = Self.answers.get(q) { out += r; answered.insert(i) }
        }
        if answered.count == queries.count { return out }
        if !out.isEmpty { partial?(out, answered) }
        let pending = queries.enumerated().filter { !answered.contains($0.offset) }
        return try await withThrowingTaskGroup(of: (Int, Result<[NyaaResult], Error>).self) { group in
            for (i, q) in pending {
                group.addTask {
                    do {
                        let r = try await self.nyaa.search(q).results
                        Self.answers.put(q, r)
                        return (i, .success(r))
                    } catch { return (i, .failure(error)) }
                }
            }
            var lastError: Error?
            var anySuccess = !answered.isEmpty
            for try await (i, r) in group {
                answered.insert(i)
                switch r {
                case .success(let list):
                    out += list
                    anySuccess = true
                    if answered.count < queries.count, !list.isEmpty { partial?(out, answered) }
                case .failure(let e): lastError = e
                }
            }
            if !anySuccess, let lastError { throw lastError }
            return out
        }
    }

    // MARK: queries

    static let category = NyaaCategory.find("1_2")
    /// Sukebei's anime category.
    static let adultCategory = NyaaCategory(id: "1_1", title: "Anime")

    /// Adult shows are searched on Nyaa and on Sukebei, where uncensored releases go.
    static func queries(details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> [NyaaQuery] {
        withSukebei(nyaaQueries(details: details, season: season, episode: episode), details: details, season: season)
    }

    static func withSukebei(_ queries: [NyaaQuery], details: ShowDetails, season: ShowSeason) -> [NyaaQuery] {
        guard details.show.isAdult == true || season.media.isAdult == true else { return queries }
        return queries + queries.map { NyaaQuery(text: $0.text, category: adultCategory, adult: true) }
    }

    private static func nyaaQueries(details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> [NyaaQuery] {
        let seasonName = searchWords(ShowNames.seasonless(season.media.romaji ?? season.media.title))
        let baseName = searchWords(ShowNames.seasonless(details.show.romaji ?? details.show.title))
        if details.show.isMovie || season.media.isMovie {
            return [NyaaQuery(text: seasonName, category: category)]
        }
        if SourceMatcher.isSideEntry(season) {
            return sideQueries(details: details, season: season, names: [season.media.romaji ?? season.media.title])
        }
        let token = episodeToken(season: season, episode: episode)
        var texts = ["\(seasonName) \(token)"]
        if season.number > 1, baseName != seasonName { texts.append("\(baseName) \(token)") }
        // Whole-season packs rarely carry an episode number.
        texts.append(seasonName)
        return unique(texts).map { NyaaQuery(text: $0, category: category) }
    }

    /// What an OVA or special is filed under: its own name without the "OVA" AniList adds (releases say "Specials",
    /// "OVA 02" or "S00E02" instead, and Nyaa wants every word of a search), then the series' name, then the
    /// name's core ("Nukitashi" for "Nukitashi THE ANIMATION"), each with the words releases mark specials by.
    /// An entry whose own name differs from the series' ("Shingeki no Kyojin: Lost Girls") is also searched as is.
    static func sideQueries(details: ShowDetails, season: ShowSeason, names: [String]) -> [NyaaQuery] {
        let own = names.map { searchWords(ShowNames.withoutSideMarker($0)) }.filter { !$0.isEmpty }
        let parent = (details.parent.map { [$0.romaji ?? $0.title, $0.english].compactMap { $0 } } ?? [])
            .map { searchWords(ShowNames.seasonless($0)) }.filter { !$0.isEmpty }
        let cores = (own + parent).map { searchWords(ShowNames.core($0)) }.filter { !$0.isEmpty }
        var texts = unique(own + parent.prefix(1) + cores).prefix(3).map { "\($0) \(specialWords)" }
        let parentKeys = Set(parent.map { ReleaseName.normalize($0) })
        texts += own.prefix(1).filter { !parentKeys.contains(ReleaseName.normalize($0)) }
        return unique(texts).map { NyaaQuery(text: $0, category: category) }
    }

    /// Nyaa reads `|` as "or" and a trailing `*` as any ending: "OVA", "OVAs", "Specials", "SP01", "S00E01".
    static let specialWords = "(OVA*|OAD*|special*|SP*|S00*)"

    static func fallbackQueries(details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> [NyaaQuery] {
        withSukebei(nyaaFallbackQueries(details: details, season: season, episode: episode), details: details, season: season)
    }

    private static func nyaaFallbackQueries(details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> [NyaaQuery] {
        let names = [season.media.english, details.show.english].compactMap { $0 }
            + season.media.synonyms.prefix(1)
        let words = unique(names.map { searchWords(ShowNames.seasonless($0)) }).filter { !$0.isEmpty }
        if details.show.isMovie || season.media.isMovie {
            return words.prefix(2).map { NyaaQuery(text: $0, category: category) }
        }
        if SourceMatcher.isSideEntry(season) {
            return words.prefix(2).map { NyaaQuery(text: "\(searchWords(ShowNames.withoutSideMarker($0))) \(specialWords)", category: category) }
        }
        let token = episodeToken(season: season, episode: episode)
        return words.prefix(2).map { NyaaQuery(text: "\($0) \(token)", category: category) }
    }

    static func episodeToken(season: ShowSeason, episode: ShowEpisode) -> String {
        let n = pad(episode.number)
        if season.number > 1, episode.absolute != episode.number { return "(\(n)|\(pad(episode.absolute)))" }
        return n
    }

    static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Words only: Nyaa reads a leading dash as "exclude" and quotes as phrases.
    static func searchWords(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 || Int($0) != nil }
        return words.joined(separator: " ")
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: ranking

    static func rank(_ results: [NyaaResult], details: ShowDetails, season: ShowSeason, episode: ShowEpisode,
                     prefs: SourcePreferences) -> [EpisodeSource] {
        var seen = Set<String>()
        var out: [EpisodeSource] = []
        for r in results {
            guard r.seeders > 0, seen.insert(r.infoHash ?? "id\(r.id)").inserted,
                  let match = SourceMatcher.match(r.title, details: details, season: season, episode: episode) else { continue }
            let traits = ReleaseTraits.parse(r.title)
            let s = score(r, release: match.release, traits: traits, isBatch: match.isBatch, prefs: prefs)
            out.append(EpisodeSource(result: r, release: match.release, traits: traits, isBatch: match.isBatch, score: s))
        }
        return out.sorted { $0.score > $1.score }
    }

    static func score(_ r: NyaaResult, release: ReleaseInfo, traits: ReleaseTraits, isBatch: Bool,
                      prefs: SourcePreferences) -> Double {
        var s = log2(Double(r.seeders) + 1) * 10
        let target = Double(prefs.resolution ?? 1080)
        if let res = traits.resolution {
            s -= abs(log2(Double(res) / target)) * 25
        } else {
            s -= 10
        }
        switch r.trust {
        case .trusted: s += 10
        case .remake: s -= 20
        case .normal: break
        }
        if let g = prefs.group, let rg = release.group, ReleaseName.normalize(g) == ReleaseName.normalize(rg) { s += 40 }
        if prefs.preferDub {
            s += traits.hasEnglishAudio ? 25 : -10
        } else if traits.dubbed {
            s -= 25
        }
        if traits.codec == "AV1" { s -= 5 }
        if traits.remux { s -= 10 }
        if traits.multiSubs { s += 3 }
        if isBatch { s -= 8 }
        return s
    }
}

/// Name helpers shared by searching and matching.
public enum ShowNames {
    private static let seasonSuffix =
        #"(?i)[\s:\-–]*(\b\d{1,2}(st|nd|rd|th)\s+(season|cour)\b|\bseason\s*\d{1,2}\b|\bpart\s*\d{1,2}\b|\bcour\s*\d{1,2}\b|\bs\d{1,2}\b|\b(ii|iii|iv|v|vi)\b)\s*$"#

    /// The name without a trailing "2nd Season", "Season 2", "Part 2", "S2" or "II".
    public static func seasonless(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: seasonSuffix, options: .regularExpression), r.lowerBound > s.startIndex {
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// The season a name says it is: "2nd Season", "Season 2", "S2", "II", or a trailing "2". Nil for none.
    public static func seasonNumber(_ name: String) -> Int? {
        let s = name.trimmingCharacters(in: .whitespaces)
        let patterns = [#"(?i)\b(\d{1,2})(?:st|nd|rd|th)\s+season\b"#, #"(?i)\bseason\s*(\d{1,2})\b"#,
                        #"(?i)\bs(\d{1,2})\s*$"#, #"\s([2-9])\s*$"#]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression),
               let n = Int(s[r].filter(\.isNumber)) { return n }
        }
        let roman = ["ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6]
        if let last = s.split(separator: " ").last.map({ $0.lowercased() }), let n = roman[last] { return n }
        return nil
    }

    private static let sideSuffix = #"(?i)[\s:\-–]*\b(ovas?|oads?|specials?|sp|picture drama|recaps?)\b\s*$"#

    /// The name without the "OVA", "OVAs", "Specials" or "OAD" that AniList ends a side entry's name with.
    public static func withoutSideMarker(_ name: String) -> String {
        var s = seasonless(name)
        while let r = s.range(of: sideSuffix, options: .regularExpression), r.lowerBound > s.startIndex {
            s = seasonless(String(s[..<r.lowerBound]))
        }
        return s
    }

    /// The heart of a name, which short release names keep: no subtitle after a colon, no "The Animation".
    /// Empty when that leaves the name as it was or nothing distinctive.
    public static func core(_ name: String) -> String {
        var s = name
        if let colon = s.range(of: ": ") { s = String(s[..<colon.lowerBound]) }
        s = s.replacingOccurrences(of: #"(?i)\s*\bthe animation\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let normalized = ReleaseName.normalize(s)
        guard normalized != ReleaseName.normalize(name), normalized.count >= 4 else { return "" }
        return s
    }
}

/// Decides whether a release name plays a given episode of a show.
public enum SourceMatcher {
    public struct Match: Hashable, Sendable {
        public var release: ReleaseInfo
        public var isBatch: Bool
    }

    /// Words that mark a release as something other than the main series.
    private static let sideStory = #"(?i)\b(ova|oad|ona|movie|film|gekijouban|special|specials|recap|picture drama|chibi|mini|prologue)\b"#
    private static let notVideo = #"(?i)\b(ncop|nced|ost|soundtrack|fonts?|scans?|artbook|manga|light novel|raw)\b|\.(zip|rar|7z|cbz|pdf|epub)$"#

    public static func match(_ name: String, details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> Match? {
        guard name.range(of: notVideo, options: .regularExpression) == nil else { return nil }
        let r = ReleaseName.parse(name)
        let titles = [r.title] + r.altTitles
        guard !r.title.isEmpty else { return nil }
        if isSideEntry(season) && !details.show.isMovie {
            return matchSide(r, titles: titles, details: details, season: season, episode: episode)
        }

        // Which entry of the show the name looks like, and how closely.
        var best: (season: Int, sim: Double) = (0, 0)
        for s in details.seasons {
            let sim = similarity(titles, s.media.names)
            if sim > best.sim + 0.001 { best = (s.number, sim) }
        }
        if best.sim < 0.5 {
            // Names like "Sousou no Frieren" for "Sousou no Frieren 2nd Season" only match without the suffix.
            for s in details.seasons {
                let sim = similarity(titles, s.media.names.map(ShowNames.seasonless))
                if sim > best.sim + 0.001 { best = (s.number, sim) }
            }
        }
        guard best.sim >= 0.5 else { return nil }

        let isMovie = details.show.isMovie || season.media.isMovie
        let allowsSide = isMovie || ["OVA", "SPECIAL", "ONA"].contains(season.media.format ?? "")
        if !allowsSide {
            // "Show OAD - 05" or "Show Movie" share the name but aren't the series.
            let extra = titles.joined(separator: " ")
            let own = season.media.names.joined(separator: " ")
            if r.isSpecial || extra.range(of: sideStory, options: .regularExpression) != nil,
               own.range(of: sideStory, options: .regularExpression) == nil { return nil }
        }

        if isMovie {
            guard r.season == nil, r.lastEpisode == nil, r.episode == nil || r.episode == 1, best.sim >= 0.6 else { return nil }
            return Match(release: r, isBatch: false)
        }

        let wanted = season.number
        let isBatch = r.isBatch || r.lastEpisode != nil || r.episode == nil
        if !isBatch, let n = r.episode {
            let fits = n == episode.number || n == episode.absolute
            if let x = r.season {
                return x == wanted && fits ? Match(release: r, isBatch: false) : nil
            }
            if best.season == wanted { return fits ? Match(release: r, isBatch: false) : nil }
            // Counted from the first episode of the show.
            if best.season == 1, episode.absolute != episode.number, n == episode.absolute {
                return Match(release: r, isBatch: false)
            }
            return nil
        }

        if let a = r.episode, let b = r.lastEpisode {
            let range = min(a, b)...max(a, b)
            if let x = r.season {
                return x == wanted && (range.contains(episode.number) || range.contains(episode.absolute))
                    ? Match(release: r, isBatch: true) : nil
            }
            if best.season == wanted, range.contains(episode.number) || range.contains(episode.absolute) {
                return Match(release: r, isBatch: true)
            }
            if best.season == 1, range.contains(episode.absolute) { return Match(release: r, isBatch: true) }
            return nil
        }
        if let x = r.season { return x == wanted ? Match(release: r, isBatch: true) : nil }
        return best.season == wanted && best.sim >= 0.8 ? Match(release: r, isBatch: true) : nil
    }

    /// An OVA or special: AniList files it as an entry of its own, while releases mostly go by the series' name and
    /// mark it ("Series - Specials 01-02", "Series S00E01-E04", "Series OVA"), or come in a pack of the series that
    /// says it holds it ("Series (11 EPs + 4 OVA)").
    public static func isSideEntry(_ season: ShowSeason) -> Bool {
        ["OVA", "SPECIAL"].contains(season.media.format ?? "")
    }

    static func matchSide(_ r: ReleaseInfo, titles: [String], details: ShowDetails, season: ShowSeason,
                          episode: ShowEpisode) -> Match? {
        let own = season.media.names
        // The names it shares with its series: its own without "OVA", where that differs, and the series'.
        let ownKeys = Set(own.map(ReleaseName.normalize))
        var shared = own.map(ShowNames.withoutSideMarker).filter { !ownKeys.contains(ReleaseName.normalize($0)) }
        if let p = details.parent { shared += p.names + p.names.map(ShowNames.seasonless) }
        let simOwn = similarity(titles, own)
        let simShared = shared.isEmpty ? 0 : similarity(titles, shared)
        guard max(simOwn, simShared) >= 0.5 else { return nil }
        // A season number must be the series' own ("Title 2 - OVA" belongs to the second season), or part of a name.
        let seriesSeason = details.parent.flatMap { $0.names.compactMap(ShowNames.seasonNumber).max() } ?? 1
        if let x = r.season, x != 0, x != seriesSeason, !(x == 1 && simOwn > simShared + 0.001),
           !(own + shared).contains(where: { ReleaseName.normalize($0).split(separator: " ").contains(Substring(String(x))) }) {
            return nil
        }
        // Named after this entry rather than the series ("Hellsing Ultimate - 03", "Lost Girls - 01").
        let named = simOwn > simShared + 0.001
        let isPack = r.episode == nil || r.lastEpisode != nil || r.isBatch
        if !r.isSpecial && !named {
            // The series' own release: only a pack that says it holds the specials.
            return isPack && r.includesSpecials && simShared >= 0.8 ? Match(release: r, isBatch: true) : nil
        }
        if !r.isSpecial && simOwn < 0.75 { return nil }
        let n = episode.number
        if let a = r.episode, let b = r.lastEpisode {
            return (min(a, b)...max(a, b)).contains(n) ? Match(release: r, isBatch: true) : nil
        }
        if let a = r.episode, !r.isBatch { return a == n ? Match(release: r, isBatch: false) : nil }
        // No number: the entry's one episode, or all of them.
        return Match(release: r, isBatch: season.episodes.count > 1)
    }

    static func similarity(_ titles: [String], _ names: [String]) -> Double {
        var best = 0.0
        for t in titles where !t.isEmpty {
            let nt = ReleaseName.normalize(t)
            for n in names {
                let nn = ReleaseName.normalize(n)
                if nt == nn { return 1 }
                best = max(best, ReleaseName.similarity(nt, nn))
            }
        }
        return best
    }
}
