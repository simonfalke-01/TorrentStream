import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

/// One AniList entry: a season of a show, or a movie.
public struct Show: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public var malID: Int?
    /// English title when there is one, else the romanized one.
    public var title: String
    public var romaji: String?
    public var english: String?
    /// Other names in Latin script, as release groups might use them.
    public var synonyms: [String]
    /// "TV", "TV_SHORT", "ONA", "OVA", "MOVIE", "SPECIAL".
    public var format: String?
    /// "RELEASING", "FINISHED", "NOT_YET_RELEASED", "CANCELLED", "HIATUS".
    public var status: String?
    public var episodes: Int?
    /// Minutes per episode.
    public var duration: Int?
    public var year: Int?
    /// 0...100.
    public var score: Int?
    public var overview: String?
    public var genres: [String]
    public var posterURL: URL?
    public var bannerURL: URL?
    /// Next episode to air and when, for shows still airing.
    public var nextEpisode: Int?
    public var nextAiringAt: Date?

    public init(id: Int, title: String, malID: Int? = nil, romaji: String? = nil, english: String? = nil,
                synonyms: [String] = [], format: String? = nil, status: String? = nil, episodes: Int? = nil,
                duration: Int? = nil, year: Int? = nil, score: Int? = nil, overview: String? = nil, genres: [String] = [],
                posterURL: URL? = nil, bannerURL: URL? = nil, nextEpisode: Int? = nil, nextAiringAt: Date? = nil) {
        self.id = id
        self.title = title
        self.malID = malID
        self.romaji = romaji
        self.english = english
        self.synonyms = synonyms
        self.format = format
        self.status = status
        self.episodes = episodes
        self.duration = duration
        self.year = year
        self.score = score
        self.overview = overview
        self.genres = genres
        self.posterURL = posterURL
        self.bannerURL = bannerURL
        self.nextEpisode = nextEpisode
        self.nextAiringAt = nextAiringAt
    }

    public var isMovie: Bool { format == "MOVIE" }
    public var isAiring: Bool { status == "RELEASING" }
    public var isUpcoming: Bool { status == "NOT_YET_RELEASED" }

    /// Every name a release might use, romanized first.
    public var names: [String] {
        var seen = Set<String>()
        return ([romaji, english].compactMap { $0 } + synonyms).filter { seen.insert(ReleaseName.normalize($0)).inserted }
    }

    /// Episodes out so far.
    public var airedEpisodes: Int {
        if isUpcoming { return 0 }
        if isAiring, let next = nextEpisode { return max(0, next - 1) }
        return episodes ?? (isMovie ? 1 : 0)
    }
}

public struct ShowEpisode: Codable, Hashable, Identifiable, Sendable {
    /// Number within its season.
    public var number: Int
    /// Number counted from the first episode of the show, as some releases number them.
    public var absolute: Int
    public var title: String?
    public var thumbnailURL: URL?
    /// Air time of the next episode of an airing show.
    public var airsAt: Date?
    public var isAired: Bool
    /// Synopsis of the episode.
    public var overview: String?
    /// Minutes.
    public var runtime: Int?
    public var id: Int { number }

    public init(number: Int, absolute: Int, title: String? = nil, thumbnailURL: URL? = nil, airsAt: Date? = nil, isAired: Bool = true,
                overview: String? = nil, runtime: Int? = nil) {
        self.number = number
        self.absolute = absolute
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.airsAt = airsAt
        self.isAired = isAired
        self.overview = overview
        self.runtime = runtime
    }
}

public struct ShowSeason: Codable, Hashable, Identifiable, Sendable {
    /// The AniList entry for this season.
    public var media: Show
    /// 1-based position in the show.
    public var number: Int
    /// Episodes in earlier seasons.
    public var episodeOffset: Int
    public var episodes: [ShowEpisode]
    public var id: Int { media.id }

    public init(media: Show, number: Int, episodeOffset: Int, episodes: [ShowEpisode]) {
        self.media = media
        self.number = number
        self.episodeOffset = episodeOffset
        self.episodes = episodes
    }
}

/// A show with its seasons in order, or a movie as a single season with one episode.
public struct ShowDetails: Codable, Hashable, Identifiable, Sendable {
    /// First season (or the movie).
    public var show: Show
    public var seasons: [ShowSeason]
    public var fetchedAt: Date
    public var id: Int { show.id }

    public init(show: Show, seasons: [ShowSeason], fetchedAt: Date = Date()) {
        self.show = show
        self.seasons = seasons
        self.fetchedAt = fetchedAt
    }

    public func season(id: Int) -> ShowSeason? { seasons.first { $0.id == id } }

    /// Every name used by any season, for matching releases.
    public var allNames: [String] {
        var seen = Set<String>()
        return seasons.flatMap(\.media.names).filter { seen.insert(ReleaseName.normalize($0)).inserted }
    }

    /// The episode after this one, crossing into the next season. Nil at the end or before it airs.
    public func episode(after season: ShowSeason, _ episode: ShowEpisode) -> (ShowSeason, ShowEpisode)? {
        if let next = season.episodes.first(where: { $0.number == episode.number + 1 }) {
            return next.isAired ? (season, next) : nil
        }
        guard let i = seasons.firstIndex(where: { $0.id == season.id }), i + 1 < seasons.count,
              let first = seasons[i + 1].episodes.first, first.isAired else { return nil }
        return (seasons[i + 1], first)
    }
}

/// An episode of a season entry going out at a set time.
public struct AiringEpisode: Codable, Hashable, Sendable, Identifiable {
    /// The AniList entry that airs, a season rather than the whole show.
    public var show: Show
    public var episode: Int
    public var airingAt: Date
    public var id: String { "\(show.id).\(episode)" }

    public init(show: Show, episode: Int, airingAt: Date) {
        self.show = show
        self.episode = episode
        self.airingAt = airingAt
    }
}

/// A titled row of shows for browsing.
public struct ShowRow: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var shows: [Show]

    public init(id: String, title: String, shows: [Show]) {
        self.id = id
        self.title = title
        self.shows = shows
    }
}

// MARK: - Client

/// Anime shows and movies from AniList: browse rows, search, and seasons with their episodes.
public final class ShowCatalog: @unchecked Sendable {
    private let session: URLSession
    let skipCache = SkipTimesCache()
    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    /// Formats that make up the seasons of a show.
    static let seasonFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    static let fields = """
    id idMal format status episodes duration seasonYear averageScore isAdult \
    title { romaji english } synonyms description(asHtml: false) genres \
    coverImage { extraLarge large } bannerImage nextAiringEpisode { episode airingAt } startDate { year }
    """

    /// Rows for the home screen.
    public func browse(now: Date = Date()) async throws -> [ShowRow] {
        let (season, year) = Self.currentSeason(now)
        let series = "format_in: [TV, TV_SHORT, ONA]"
        let query = """
        query ($season: MediaSeason, $year: Int) {
          trending: Page(perPage: 20) { media(type: ANIME, sort: TRENDING_DESC, isAdult: false, format_in: [TV, TV_SHORT, ONA, MOVIE]) { ...S } }
          season: Page(perPage: 20) { media(type: ANIME, season: $season, seasonYear: $year, sort: POPULARITY_DESC, isAdult: false, \(series)) { ...S } }
          popular: Page(perPage: 20) { media(type: ANIME, sort: POPULARITY_DESC, isAdult: false, \(series)) { ...S } }
          top: Page(perPage: 20) { media(type: ANIME, sort: SCORE_DESC, isAdult: false, \(series)) { ...S } }
          movies: Page(perPage: 20) { media(type: ANIME, sort: POPULARITY_DESC, isAdult: false, format: MOVIE) { ...S } }
        }
        fragment S on Media { \(Self.fields) }
        """
        let data = try await graphQL(query, variables: ["season": season, "year": year])
        let rows: [(String, String)] = [
            ("trending", "Trending Now"), ("season", "New This Season"), ("popular", "Popular"),
            ("top", "Top Rated"), ("movies", "Movies"),
        ]
        return rows.compactMap { key, title in
            let media = ((data[key] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
            let shows = media.compactMap(Self.show)
            return shows.isEmpty ? nil : ShowRow(id: key, title: title, shows: shows)
        }
    }

    /// Shows and movies matching what the user typed, best match first. Searches Kitsu, which has no request
    /// limit, and falls back to AniList when Kitsu can't be reached. Kitsu often takes over a second, so when it
    /// hasn't answered after `hedgeDelay` and AniList's request budget has room, AniList is asked too and whichever
    /// answers first is used.
    public func search(_ text: String) async throws -> [Show] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        return try await hedged(primary: { try await self.kitsuSearch(t) },
                                fallback: { try await self.anilistSearch(t) },
                                delay: Self.hedgeDelay,
                                hedgeAllowed: { (AniListBudget.shared.spare ?? .max) > 6 })
    }

    static let hedgeDelay: TimeInterval = 0.7

    private enum Answer: Sendable { case primary([Show]?), fallback(Result<[Show], Error>), skipped }

    /// `primary`'s answer, or `fallback`'s when the primary fails, or when it is slower than `delay` and the fallback
    /// answers first.
    func hedged(primary: @escaping @Sendable () async throws -> [Show], fallback: @escaping @Sendable () async throws -> [Show],
                delay: TimeInterval, hedgeAllowed: @escaping @Sendable () -> Bool) async throws -> [Show] {
        let started = Flag()
        let runFallback: @Sendable () async -> Answer = {
            do { return .fallback(.success(try await fallback())) } catch { return .fallback(.failure(error)) }
        }
        return try await withThrowingTaskGroup(of: Answer.self) { group in
            group.addTask { .primary(try? await primary()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, hedgeAllowed(), started.setOnce() else { return .skipped }
                return await runFallback()
            }
            var lastError: Error = CatalogError.unreadable
            var primaryFailed = false
            var fallbackDone = false
            while let answer = try await group.next() {
                switch answer {
                case .primary(let list?):
                    group.cancelAll()
                    return list
                case .primary(nil):
                    primaryFailed = true
                    if started.setOnce() { group.addTask { await runFallback() } }
                    else if fallbackDone { throw lastError }
                case .fallback(.success(let list)):
                    group.cancelAll()
                    return list
                case .fallback(.failure(let e)):
                    lastError = e
                    fallbackDone = true
                    if primaryFailed { throw e }
                case .skipped:
                    break
                }
            }
            throw lastError
        }
    }

    func kitsuSearch(_ text: String) async throws -> [Show] {
        var c = URLComponents(string: "\(Self.kitsu)/anime")!
        c.queryItems = [
            URLQueryItem(name: "filter[text]", value: text),
            URLQueryItem(name: "page[limit]", value: "20"),
            URLQueryItem(name: "include", value: "mappings"),
            URLQueryItem(name: "fields[mappings]", value: "externalSite,externalId"),
        ]
        guard let url = c.url else { throw CatalogError.unreadable }
        return Self.kitsuShows(try await json(url))
    }

    /// Kitsu entries that map to AniList, which keys seasons, episodes and progress everywhere else.
    static func kitsuShows(_ root: [String: Any]) -> [Show] {
        var mappings: [String: (site: String, id: String)] = [:]
        for i in (root["included"] as? [[String: Any]]) ?? [] where i["type"] as? String == "mappings" {
            guard let id = i["id"] as? String, let a = i["attributes"] as? [String: Any],
                  let site = a["externalSite"] as? String, let ext = a["externalId"] as? String else { continue }
            mappings[id] = (site, ext)
        }
        var seen = Set<Int>()
        return ((root["data"] as? [[String: Any]]) ?? []).compactMap { item -> Show? in
            let refs = (((item["relationships"] as? [String: Any])?["mappings"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            let linked = refs.compactMap { ($0["id"] as? String).flatMap { mappings[$0] } }
            guard let anilist = linked.first(where: { $0.site == "anilist/anime" }).flatMap({ Int($0.id) }),
                  seen.insert(anilist).inserted,
                  let a = item["attributes"] as? [String: Any] else { return nil }
            let mal = linked.first(where: { $0.site == "myanimelist/anime" }).flatMap { Int($0.id) }
            return kitsuShow(a, anilistID: anilist, malID: mal)
        }
    }

    static func kitsuShow(_ a: [String: Any], anilistID: Int, malID: Int?) -> Show? {
        let formats = ["TV": "TV", "ONA": "ONA", "OVA": "OVA", "movie": "MOVIE", "special": "SPECIAL"]
        guard let format = formats[a["subtype"] as? String ?? ""], a["ageRating"] as? String != "R18",
              a["nsfw"] as? Bool != true else { return nil }
        let titles = a["titles"] as? [String: Any] ?? [:]
        let english = (titles["en"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let romaji = (titles["en_jp"] as? String) ?? (a["canonicalTitle"] as? String)
        guard let title = english ?? romaji else { return nil }
        let statuses = ["current": "RELEASING", "finished": "FINISHED", "upcoming": "NOT_YET_RELEASED",
                        "unreleased": "NOT_YET_RELEASED", "tba": "NOT_YET_RELEASED"]
        func image(_ key: String) -> URL? {
            let i = a[key] as? [String: Any]
            return ((i?["large"] as? String) ?? (i?["original"] as? String)).flatMap(URL.init(string:))
        }
        return Show(
            id: anilistID,
            title: title,
            malID: malID,
            romaji: romaji,
            english: english,
            synonyms: ((a["abbreviatedTitles"] as? [String]) ?? []).filter(isLatin),
            format: format,
            status: statuses[a["status"] as? String ?? ""],
            episodes: a["episodeCount"] as? Int,
            duration: a["episodeLength"] as? Int,
            year: (a["startDate"] as? String).flatMap { Int($0.prefix(4)) },
            score: (a["averageRating"] as? String).flatMap(Double.init).map { Int($0.rounded()) },
            overview: (a["synopsis"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            posterURL: image("posterImage"),
            bannerURL: image("coverImage")
        )
    }

    func anilistSearch(_ t: String) async throws -> [Show] {
        let query = """
        query ($q: String) {
          r: Page(perPage: 30) { media(search: $q, type: ANIME, sort: SEARCH_MATCH, isAdult: false, format_in: [TV, TV_SHORT, ONA, OVA, MOVIE]) { ...S } }
        }
        fragment S on Media { \(Self.fields) }
        """
        let data = try await graphQL(query, variables: ["q": t])
        let media = ((data["r"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
        return media.compactMap(Self.show)
    }

    /// The whole show an entry belongs to: earlier and later seasons in order, with episode titles where known.
    public func details(id: Int) async throws -> ShowDetails {
        // The first request returns the entry, its neighbours in full, and the ids of everything one step further
        // (a franchise's manga links every season). When the chain runs past the neighbours, all of those are fetched
        // in one more request; anything still missing is walked back and forward at the same time.
        let first = try await nodes(id)
        var known = first.nodes
        guard let start = known[id] else { throw CatalogError.unreadable }
        let wanted = first.nearby.filter { known[$0] == nil }
        if Self.seasonFormats.contains(start.show.format ?? ""), Self.chainContinues(from: start, known: known), !wanted.isEmpty,
           let more = try? await nodes(ids: Array(wanted.prefix(50))) {
            known.merge(more) { old, _ in old }
        }
        guard Self.seasonFormats.contains(start.show.format ?? "") else {
            // Movies, OVAs and specials stand alone.
            let count = start.show.isMovie ? 1 : max(1, start.show.episodes ?? start.show.airedEpisodes)
            return ShowDetails(show: start.show, seasons: [season(start, number: 1, offset: 0, count: count)])
        }
        let resolved = known
        async let back = walk(from: start, known: resolved, forward: false)
        async let ahead = walk(from: start, known: resolved, forward: true)
        var chain: [Node] = []
        var seen = Set<Int>()
        for n in (try await back).reversed() + [start] + (try await ahead) where seen.insert(n.show.id).inserted {
            chain.append(n)
        }
        chain = Array(chain.prefix(24))
        var seasons: [ShowSeason] = []
        var offset = 0
        for (i, n) in chain.enumerated() {
            let s = season(n, number: i + 1, offset: offset, count: nil)
            offset += s.media.episodes ?? s.episodes.count
            seasons.append(s)
        }
        return ShowDetails(show: chain[0].show, seasons: seasons)
    }

    /// Fills in episode titles, synopses, stills and runtimes AniList lacks, from ani.zip and then Kitsu.
    /// Best effort: seasons that fail keep what they had.
    public func withEpisodeInfo(_ details: ShowDetails) async -> ShowDetails {
        var out = details
        let targets = out.seasons.indices.prefix(8).filter {
            out.seasons[$0].episodes.contains { $0.title == nil || $0.thumbnailURL == nil || $0.overview == nil }
        }
        let ids = targets.map { out.seasons[$0].media.id }
        let found = await withTaskGroup(of: (Int, [Int: EpisodeInfo]?).self) { group -> [Int: [Int: EpisodeInfo]] in
            for id in ids { group.addTask { (id, try? await self.aniZipEpisodes(anilistID: id)) } }
            var all: [Int: [Int: EpisodeInfo]] = [:]
            for await (id, info) in group { all[id] = info }
            return all
        }
        for i in targets {
            if let info = found[out.seasons[i].media.id] {
                out.seasons[i].episodes = Self.merged(out.seasons[i].episodes, with: info)
            }
        }
        // Kitsu for what ani.zip lacked, all seasons at once.
        let gaps = targets.filter { out.seasons[$0].episodes.contains { $0.title == nil || $0.thumbnailURL == nil } }
        let wanted = gaps.map { (out.seasons[$0].media.id, out.seasons[$0].episodes.count) }
        let kitsu = await withTaskGroup(of: (Int, [Int: (title: String?, thumbnail: URL?)]?).self) { group -> [Int: [Int: EpisodeInfo]] in
            for (id, count) in wanted { group.addTask { (id, try? await self.kitsuEpisodes(anilistID: id, count: count)) } }
            var all: [Int: [Int: EpisodeInfo]] = [:]
            for await (id, info) in group {
                if let info { all[id] = info.mapValues { EpisodeInfo(title: $0.title, thumbnail: $0.thumbnail) } }
            }
            return all
        }
        for i in gaps {
            if let info = kitsu[out.seasons[i].media.id] {
                out.seasons[i].episodes = Self.merged(out.seasons[i].episodes, with: info)
            }
        }
        return out
    }

    /// Shows AniList users recommend alongside this one, best rated first.
    public func recommendations(id: Int) async throws -> [Show] {
        let query = """
        query ($id: Int) {
          m: Media(id: $id, type: ANIME) { recommendations(sort: RATING_DESC, perPage: 15) { nodes { mediaRecommendation { \(Self.fields) } } } }
        }
        """
        return Self.recommendations(try await graphQL(query, variables: ["id": id]), excluding: id)
    }

    static func recommendations(_ data: [String: Any], excluding id: Int) -> [Show] {
        let nodes = (((data["m"] as? [String: Any])?["recommendations"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        var seen: Set<Int> = [id]
        let shows = nodes.compactMap { ($0["mediaRecommendation"] as? [String: Any]).flatMap(show) }
        return Array(shows.filter { seen.insert($0.id).inserted }.prefix(12))
    }

    /// Episodes airing from `from` up to but not including `to`, in airing order. One request per week of the range.
    public func schedule(from: Date, to: Date) async throws -> [AiringEpisode] {
        var out: [AiringEpisode] = []
        var seen = Set<String>()
        var start = from
        while start < to {
            let end = min(to, start.addingTimeInterval(7 * 86400))
            let variables = ["from": Int(start.timeIntervalSince1970.rounded(.up)) - 1, "to": Int(end.timeIntervalSince1970.rounded(.up))]
            let data = try await graphQL(Self.scheduleQuery, variables: variables)
            for a in Self.airingEpisodes(data) where a.airingAt >= start && a.airingAt < end && seen.insert(a.id).inserted {
                out.append(a)
            }
            start = end
        }
        return out.sorted { ($0.airingAt, $0.show.id, $0.episode) < ($1.airingAt, $1.show.id, $1.episode) }
    }

    static let schedulePages = 6
    static let scheduleFormats: Set<String> = ["TV", "TV_SHORT", "ONA", "OVA", "SPECIAL", "MOVIE"]

    /// Up to six pages of 50 in one request; AniList bounds are exclusive.
    static let scheduleQuery: String = {
        let pages = (1...schedulePages).map { p in
            "p\(p): Page(page: \(p), perPage: 50) { airingSchedules(airingAt_greater: $from, airingAt_lesser: $to, sort: TIME) { episode airingAt media { ...S } } }"
        }
        return "query ($from: Int, $to: Int) {\n\(pages.joined(separator: "\n"))\n}\nfragment S on Media { \(fields) }"
    }()

    static func airingEpisodes(_ data: [String: Any]) -> [AiringEpisode] {
        (1...schedulePages).flatMap { p -> [AiringEpisode] in
            let list = ((data["p\(p)"] as? [String: Any])?["airingSchedules"] as? [[String: Any]]) ?? []
            return list.compactMap { a in
                guard let episode = a["episode"] as? Int, let at = a["airingAt"] as? Int, let m = a["media"] as? [String: Any],
                      scheduleFormats.contains(m["format"] as? String ?? ""), let show = show(m) else { return nil }
                return AiringEpisode(show: show, episode: episode, airingAt: Date(timeIntervalSince1970: TimeInterval(at)))
            }
        }
    }

    // MARK: details helpers

    struct Node {
        var show: Show
        var prequel: Int?
        var sequel: Int?
        /// Episode number to title and thumbnail, from streaming services.
        var streaming: [Int: (title: String?, thumbnail: URL?)]
    }

    /// Prequels (`forward` false, nearest first) or sequels of `start`, one request per two seasons not yet known.
    private func walk(from start: Node, known: [Int: Node], forward: Bool) async throws -> [Node] {
        var known = known
        var out: [Node] = []
        var visited: Set<Int> = [start.show.id]
        var current = start
        while out.count < 23, let id = forward ? current.sequel : current.prequel, visited.insert(id).inserted {
            if known[id] == nil { known.merge(try await nodes(id).nodes) { old, _ in old } }
            guard let n = known[id] else { throw CatalogError.unreadable }
            if forward && n.show.isUpcoming && n.show.nextAiringAt == nil { break }
            out.append(n)
            current = n
        }
        return out
    }

    /// An entry with what it links to (for walking seasons) and its streaming episode list.
    private static let nodeFields = """
    \(fields) streamingEpisodes { title thumbnail } \
    relations { edges { relationType node { id format status nextAiringEpisode { airingAt } startDate { year month day } } } }
    """

    /// An entry and its neighbours in full, and the ids of seasons one step beyond them. AniList leaves relations
    /// nested deeper than that empty, so those can't be read in the same request.
    private func nodes(_ id: Int) async throws -> (nodes: [Int: Node], nearby: [Int]) {
        let query = """
        query ($id: Int) {
          m: Media(id: $id, type: ANIME) {
            \(Self.fields)
            streamingEpisodes { title thumbnail }
            relations { edges { relationType node { \(Self.nodeFields) } } }
          }
        }
        """
        let data = try await graphQL(query, variables: ["id": id])
        guard let m = data["m"] as? [String: Any] else { throw CatalogError.unreadable }
        return Self.nodes(m)
    }

    /// Several entries in full, in one request.
    private func nodes(ids: [Int]) async throws -> [Int: Node] {
        let query = """
        query ($ids: [Int]) { p: Page(perPage: 50) { media(id_in: $ids, type: ANIME) { \(Self.nodeFields) } } }
        """
        let data = try await graphQL(query, variables: ["ids": ids])
        let media = ((data["p"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
        var out: [Int: Node] = [:]
        for m in media { if let n = Self.node(m) { out[n.show.id] = n } }
        return out
    }

    /// The entry and its neighbours keyed by id, and the ids of season-like entries the neighbours link to that
    /// aren't among them.
    static func nodes(_ m: [String: Any]) -> (nodes: [Int: Node], nearby: [Int]) {
        var out: [Int: Node] = [:]
        func edges(_ m: [String: Any]) -> [[String: Any]] {
            (((m["relations"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []).compactMap { $0["node"] as? [String: Any] }
        }
        guard let root = node(m) else { return ([:], []) }
        out[root.show.id] = root
        let neighbours = edges(m)
        for child in neighbours {
            if let n = node(child), out[n.show.id] == nil { out[n.show.id] = n }
        }
        var nearby: [Int] = []
        var seen = Set(out.keys)
        for child in neighbours {
            for far in edges(child) where seasonFormats.contains(far["format"] as? String ?? "") {
                if let id = far["id"] as? Int, seen.insert(id).inserted { nearby.append(id) }
            }
        }
        return (out, nearby)
    }

    /// Whether walking prequels or sequels from `start` reaches an entry that isn't in `known`.
    static func chainContinues(from start: Node, known: [Int: Node]) -> Bool {
        for forward in [false, true] {
            var visited: Set<Int> = [start.show.id]
            var current = start
            while let id = forward ? current.sequel : current.prequel, visited.insert(id).inserted {
                guard let n = known[id] else { return true }
                current = n
            }
        }
        return false
    }

    static func node(_ m: [String: Any]) -> Node? {
        guard let show = show(m), m["relations"] != nil else { return nil }
        let edges = ((m["relations"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        func related(_ type: String) -> Int? {
            let nodes = edges.filter { $0["relationType"] as? String == type }.compactMap { $0["node"] as? [String: Any] }
                .filter { seasonFormats.contains($0["format"] as? String ?? "") }
            let sorted = nodes.sorted { startKey($0) < startKey($1) }
            return (type == "PREQUEL" ? sorted.last : sorted.first)?["id"] as? Int
        }
        let streaming = streamingEpisodes(m["streamingEpisodes"] as? [[String: Any]] ?? [], count: show.episodes)
        return Node(show: show, prequel: related("PREQUEL"), sequel: related("SEQUEL"), streaming: streaming)
    }

    private static func startKey(_ m: [String: Any]) -> Int {
        let d = m["startDate"] as? [String: Any]
        return ((d?["year"] as? Int) ?? 9999) * 10000 + ((d?["month"] as? Int) ?? 12) * 100 + ((d?["day"] as? Int) ?? 31)
    }

    private func season(_ n: Node, number: Int, offset: Int, count: Int?) -> ShowSeason {
        let show = n.show
        let aired = show.isMovie ? 1 : show.airedEpisodes
        let total = count ?? max(aired, show.episodes ?? 0, n.streaming.keys.max() ?? 0)
        var episodes: [ShowEpisode] = []
        // Aired episodes, plus the next one for a show that is airing.
        let listed = show.isAiring ? min(total, aired + 1) : (show.isUpcoming ? 0 : max(aired, min(total, n.streaming.keys.max() ?? 0)))
        if listed > 0 {
            for k in 1...listed {
                let s = n.streaming[k]
                let isAired = !show.isAiring || k <= aired
                episodes.append(ShowEpisode(number: k, absolute: offset + k, title: s?.title, thumbnailURL: s?.thumbnail,
                                            airsAt: isAired ? nil : show.nextAiringAt, isAired: isAired))
            }
        }
        return ShowSeason(media: show, number: number, episodeOffset: offset, episodes: episodes)
    }

    /// "Episode 5 - Phantoms of the Dead" entries keyed by episode number. Numbers counted across seasons
    /// are shifted to start at 1.
    static func streamingEpisodes(_ list: [[String: Any]], count: Int?) -> [Int: (title: String?, thumbnail: URL?)] {
        var parsed: [(Int, String?, URL?)] = []
        guard let re = try? NSRegularExpression(pattern: #"^(?:Episode|Ep\.?|E)\s*(\d+)(?:\s*[-–:]\s*(.+))?$"#,
                                                options: [.caseInsensitive]) else { return [:] }
        for e in list {
            guard let raw = e["title"] as? String else { continue }
            let s = raw.trimmingCharacters(in: .whitespaces)
            let ns = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: ns), let r1 = Range(m.range(at: 1), in: s), let n = Int(s[r1]) else { continue }
            let title = Range(m.range(at: 2), in: s).map { String(s[$0]).trimmingCharacters(in: .whitespaces) }
            parsed.append((n, title?.isEmpty == false ? title : nil, (e["thumbnail"] as? String).flatMap(URL.init(string:))))
        }
        guard let lo = parsed.map(\.0).min(), let hi = parsed.map(\.0).max() else { return [:] }
        let shift = (lo > 1 && (count.map { hi > $0 } ?? false)) ? lo - 1 : 0
        var out: [Int: (title: String?, thumbnail: URL?)] = [:]
        for (n, t, u) in parsed where n - shift >= 1 { out[n - shift] = (t, u) }
        return out
    }

    struct EpisodeInfo: Equatable, Sendable {
        var title: String?
        var overview: String?
        var thumbnail: URL?
        var runtime: Int?
    }

    /// Episodes with gaps filled from `info`, keyed by number within the season. Values already there are kept.
    static func merged(_ episodes: [ShowEpisode], with info: [Int: EpisodeInfo]) -> [ShowEpisode] {
        episodes.map { e in
            guard let i = info[e.number] else { return e }
            var e = e
            e.title = e.title ?? i.title
            e.thumbnailURL = e.thumbnailURL ?? i.thumbnail
            e.overview = e.overview ?? i.overview
            e.runtime = e.runtime ?? i.runtime
            return e
        }
    }

    /// Episode names, synopses and stills from ani.zip, which collects them from TheTVDB and AniDB.
    private func aniZipEpisodes(anilistID: Int) async throws -> [Int: EpisodeInfo] {
        Self.aniZipEpisodes(try await json(URL(string: "https://api.ani.zip/mappings?anilist_id=\(anilistID)")!, accept: "application/json"))
    }

    /// Regular episodes keyed by number within the AniList entry. Specials ("S1") are left out.
    static func aniZipEpisodes(_ root: [String: Any]) -> [Int: EpisodeInfo] {
        var out: [Int: EpisodeInfo] = [:]
        for (key, value) in (root["episodes"] as? [String: Any]) ?? [:] {
            guard let n = Int(key), n > 0, let e = value as? [String: Any] else { continue }
            let titles = e["title"] as? [String: Any] ?? [:]
            let info = EpisodeInfo(
                title: episodeTitle(latin: [titles["en"], titles["x-jat"]], japanese: [titles["ja"]]),
                overview: (e["overview"] as? String).flatMap(episodeOverview),
                thumbnail: (e["image"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                runtime: [e["runtime"], e["length"]].compactMap(integer).first { $0 > 0 }
            )
            if info != EpisodeInfo() { out[n] = info }
        }
        return out
    }

    /// The first title worth showing, from English and romanized names in order of preference, then Japanese ones.
    static func episodeTitle(latin: [Any?], japanese: [Any?]) -> String? {
        latin.lazy.compactMap { ($0 as? String).flatMap { episodeTitle($0) } }.first
            ?? japanese.lazy.compactMap { ($0 as? String).flatMap { episodeTitle($0, allowJapanese: true) } }.first
    }

    /// A title worth showing: not empty, not "Episode 5", and in Japanese script only when that is allowed.
    static func episodeTitle(_ raw: String, allowJapanese: Bool = false) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "`", with: "'")
        guard !t.isEmpty, t.range(of: #"^(?i)(episode|第)\s*\d+\s*(話)?$"#, options: .regularExpression) == nil else { return nil }
        if !allowJapanese, t.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil { return nil }
        return t
    }

    /// A synopsis worth showing: not empty and not a placeholder like "TBA".
    static func episodeOverview(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "`", with: "'")
        let placeholder = #"^(?i)(no (overview|description|synopsis|summary)( (available|yet))?|tba|tbd|to be (announced|determined)|n/?a|coming soon|-+)[.!]?$"#
        guard !t.isEmpty, t.range(of: placeholder, options: .regularExpression) == nil else { return nil }
        return t
    }

    static func integer(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d.isFinite { return Int(d.rounded()) }
        return (v as? String).flatMap { Int($0) }
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return (v as? String).flatMap { Double($0) }
    }

    private static let kitsu = "https://kitsu.app/api/edge"

    /// Episode titles and stills from Kitsu, which maps AniList ids to its own. First 200 episodes.
    private func kitsuEpisodes(anilistID: Int, count: Int) async throws -> [Int: (title: String?, thumbnail: URL?)] {
        let mapping = "\(Self.kitsu)/mappings?filter%5BexternalSite%5D=anilist/anime&filter%5BexternalId%5D=\(anilistID)&include=item"
            + "&fields%5Banime%5D=id"
        let root = try await json(URL(string: mapping)!)
        guard let item = ((root["included"] as? [[String: Any]]) ?? []).first(where: { $0["type"] as? String == "anime" }),
              let kitsuID = item["id"] as? String else { return [:] }
        var out: [Int: (title: String?, thumbnail: URL?)] = [:]
        let pages = min(10, max(1, (count + 19) / 20))
        try await withThrowingTaskGroup(of: [[String: Any]].self) { group in
            for p in 0..<pages {
                let url = URL(string: "\(Self.kitsu)/anime/\(kitsuID)/episodes?page%5Blimit%5D=20&page%5Boffset%5D=\(p * 20)&sort=number"
                    + "&fields%5Bepisodes%5D=number,canonicalTitle,titles,thumbnail")!
                group.addTask { ((try await self.json(url))["data"] as? [[String: Any]]) ?? [] }
            }
            for try await list in group {
                for e in list {
                    guard let a = e["attributes"] as? [String: Any], let n = a["number"] as? Int else { continue }
                    out[n] = Self.kitsuEpisode(a)
                }
            }
        }
        return out
    }

    static func kitsuEpisode(_ a: [String: Any]) -> (title: String?, thumbnail: URL?) {
        let titles = a["titles"] as? [String: Any] ?? [:]
        let title = episodeTitle(latin: [titles["en"], titles["en_us"], a["canonicalTitle"], titles["en_jp"]],
                                 japanese: [titles["ja_jp"], a["canonicalTitle"]])
        let thumb = ((a["thumbnail"] as? [String: Any])?["original"] as? String).flatMap(URL.init(string:))
        return (title, thumb)
    }

    func json(_ url: URL, accept: String = "application/vnd.api+json") async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let data = try await send(request, aniList: false)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CatalogError.unreadable }
        return root
    }

    // MARK: parsing

    static func show(_ m: [String: Any]) -> Show? {
        guard let id = m["id"] as? Int, (m["isAdult"] as? Bool) != true else { return nil }
        let titles = m["title"] as? [String: Any] ?? [:]
        let romaji = titles["romaji"] as? String
        let english = titles["english"] as? String
        guard let title = english ?? romaji else { return nil }
        let cover = m["coverImage"] as? [String: Any]
        let next = m["nextAiringEpisode"] as? [String: Any]
        let latin = ((m["synonyms"] as? [String]) ?? []).filter(isLatin)
        return Show(
            id: id,
            title: title,
            malID: m["idMal"] as? Int,
            romaji: romaji,
            english: english,
            synonyms: latin,
            format: m["format"] as? String,
            status: m["status"] as? String,
            episodes: m["episodes"] as? Int,
            duration: m["duration"] as? Int,
            year: (m["seasonYear"] as? Int) ?? ((m["startDate"] as? [String: Any])?["year"] as? Int),
            score: m["averageScore"] as? Int,
            overview: (m["description"] as? String).map(CatalogClient.plainText),
            genres: (m["genres"] as? [String]) ?? [],
            posterURL: ((cover?["extraLarge"] as? String) ?? (cover?["large"] as? String)).flatMap(URL.init(string:)),
            bannerURL: (m["bannerImage"] as? String).flatMap(URL.init(string:)),
            nextEpisode: next?["episode"] as? Int,
            nextAiringAt: (next?["airingAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    static func isLatin(_ s: String) -> Bool {
        s.range(of: #"^[\p{Latin}\p{Common}\p{Inherited}]+$"#, options: .regularExpression) != nil
    }

    static func currentSeason(_ date: Date) -> (String, Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let c = cal.dateComponents([.year, .month], from: date)
        let month = c.month ?? 1
        let season = ["WINTER", "WINTER", "WINTER", "SPRING", "SPRING", "SPRING", "SUMMER", "SUMMER", "SUMMER", "FALL", "FALL", "FALL"][month - 1]
        return (season, c.year ?? 2026)
    }

    // MARK: networking

    private func graphQL(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await send(request, aniList: true)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else { throw CatalogError.unreadable }
        return payload
    }

    /// Sends a request, waiting out one rate limit response. AniList requests go through its request budget:
    /// background ones fail rather than wait.
    private func send(_ request: URLRequest, aniList: Bool) async throws -> Data {
        var request = request
        request.setValue("TorrentStream/4 (iOS)", forHTTPHeaderField: "User-Agent")
        let background = CatalogPriority.isBackground
        for attempt in 0..<2 {
            if aniList { try await AniListBudget.shared.admit(background: background) }
            let data: Data, response: URLResponse?
            do {
                (data, response) = try await HTTP.data(session, for: request)
            } catch {
                if aniList { AniListBudget.shared.finished(nil) }
                throw error
            }
            if aniList { AniListBudget.shared.finished(response) }
            guard let http = response as? HTTPURLResponse else { return data }
            if http.statusCode == 429, aniList {
                // The budget now knows how long to hold off; the viewer's request waits for that once.
                if attempt == 0 && !background { continue }
                throw CatalogError.rateLimited
            }
            if http.statusCode == 429, attempt == 0 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw CatalogError.http(http.statusCode) }
            return data
        }
        throw CatalogError.http(429)
    }
}
