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
    /// last, so the caller can start fetching the likely winners' .torrent files while the rest are still running.
    public func sources(for details: ShowDetails, season: ShowSeason, episode: ShowEpisode,
                        prefs: SourcePreferences,
                        provisional: (@Sendable ([EpisodeSource]) -> Void)? = nil) async throws -> [EpisodeSource] {
        let queries = Self.queries(details: details, season: season, episode: episode)
        var results = try await search(queries) { partial in
            provisional?(Self.rank(partial, details: details, season: season, episode: episode, prefs: prefs))
        }
        var sources = Self.rank(results, details: details, season: season, episode: episode, prefs: prefs)
        if sources.count < 3 {
            let extra = Self.fallbackQueries(details: details, season: season, episode: episode).filter { !queries.contains($0) }
            if !extra.isEmpty, let more = try? await search(extra, partial: nil) {
                results += more
                sources = Self.rank(results, details: details, season: season, episode: episode, prefs: prefs)
            }
        }
        return sources
    }

    /// Runs searches side by side. Fails only when every one fails.
    private func search(_ queries: [NyaaQuery], partial: (([NyaaResult]) -> Void)?) async throws -> [NyaaResult] {
        try await withThrowingTaskGroup(of: Result<[NyaaResult], Error>.self) { group in
            for q in queries {
                group.addTask {
                    do { return .success(try await self.nyaa.search(q).results) } catch { return .failure(error) }
                }
            }
            var out: [NyaaResult] = []
            var lastError: Error?
            var anySuccess = false
            var answered = 0
            for try await r in group {
                answered += 1
                switch r {
                case .success(let list):
                    out += list
                    anySuccess = true
                    if answered < queries.count, !list.isEmpty { partial?(out) }
                case .failure(let e): lastError = e
                }
            }
            if !anySuccess, let lastError { throw lastError }
            return out
        }
    }

    // MARK: queries

    static let category = NyaaCategory.find("1_2")

    static func queries(details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> [NyaaQuery] {
        let seasonName = searchWords(ShowNames.seasonless(season.media.romaji ?? season.media.title))
        let baseName = searchWords(ShowNames.seasonless(details.show.romaji ?? details.show.title))
        if details.show.isMovie || season.media.isMovie {
            return [NyaaQuery(text: seasonName, category: category)]
        }
        let token = episodeToken(season: season, episode: episode)
        var texts = ["\(seasonName) \(token)"]
        if season.number > 1, baseName != seasonName { texts.append("\(baseName) \(token)") }
        // Whole-season packs rarely carry an episode number.
        texts.append(seasonName)
        return unique(texts).map { NyaaQuery(text: $0, category: category) }
    }

    static func fallbackQueries(details: ShowDetails, season: ShowSeason, episode: ShowEpisode) -> [NyaaQuery] {
        let names = [season.media.english, details.show.english].compactMap { $0 }
            + season.media.synonyms.prefix(1)
        let words = unique(names.map { searchWords(ShowNames.seasonless($0)) }).filter { !$0.isEmpty }
        if details.show.isMovie || season.media.isMovie {
            return words.prefix(2).map { NyaaQuery(text: $0, category: category) }
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
            if extra.range(of: sideStory, options: .regularExpression) != nil,
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
