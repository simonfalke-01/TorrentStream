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
    public var id: Int { number }

    public init(number: Int, absolute: Int, title: String? = nil, thumbnailURL: URL? = nil, airsAt: Date? = nil, isAired: Bool = true) {
        self.number = number
        self.absolute = absolute
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.airsAt = airsAt
        self.isAired = isAired
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

    /// Shows and movies matching what the user typed, best match first.
    public func search(_ text: String) async throws -> [Show] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
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
        let start = try await node(id)
        guard Self.seasonFormats.contains(start.show.format ?? "") else {
            // Movies, OVAs and specials stand alone.
            let count = start.show.isMovie ? 1 : max(1, start.show.episodes ?? start.show.airedEpisodes)
            return ShowDetails(show: start.show, seasons: [season(start, number: 1, offset: 0, count: count)])
        }
        var chain = [start]
        var visited: Set<Int> = [start.show.id]
        // Walk back to the first season, then forward to the last.
        while chain.count < 24, let prev = chain[0].prequel, visited.insert(prev).inserted {
            chain.insert(try await node(prev), at: 0)
        }
        while chain.count < 24, let next = chain[chain.count - 1].sequel, visited.insert(next).inserted {
            let n = try await node(next)
            if n.show.isUpcoming && n.show.nextAiringAt == nil { break }
            chain.append(n)
        }
        var seasons: [ShowSeason] = []
        var offset = 0
        for (i, n) in chain.enumerated() {
            let s = season(n, number: i + 1, offset: offset, count: nil)
            offset += s.media.episodes ?? s.episodes.count
            seasons.append(s)
        }
        return ShowDetails(show: chain[0].show, seasons: seasons)
    }

    /// Fills in episode titles and stills AniList lacks, from Kitsu. Best effort: seasons that fail keep what they had.
    public func withEpisodeInfo(_ details: ShowDetails) async -> ShowDetails {
        var out = details
        for i in out.seasons.indices.prefix(8) {
            let eps = out.seasons[i].episodes
            guard !eps.isEmpty, eps.contains(where: { $0.title == nil || $0.thumbnailURL == nil }),
                  let info = try? await kitsuEpisodes(anilistID: out.seasons[i].media.id, count: eps.count) else { continue }
            for j in eps.indices {
                guard let k = info[eps[j].number] else { continue }
                if out.seasons[i].episodes[j].title == nil { out.seasons[i].episodes[j].title = k.title }
                if out.seasons[i].episodes[j].thumbnailURL == nil { out.seasons[i].episodes[j].thumbnailURL = k.thumbnail }
            }
        }
        return out
    }

    // MARK: details helpers

    struct Node {
        var show: Show
        var prequel: Int?
        var sequel: Int?
        /// Episode number to title and thumbnail, from streaming services.
        var streaming: [Int: (title: String?, thumbnail: URL?)]
    }

    private func node(_ id: Int) async throws -> Node {
        let query = """
        query ($id: Int) {
          m: Media(id: $id, type: ANIME) {
            \(Self.fields)
            streamingEpisodes { title thumbnail }
            relations { edges { relationType node { id format status nextAiringEpisode { airingAt } startDate { year month day } } } }
          }
        }
        """
        let data = try await graphQL(query, variables: ["id": id])
        guard let m = data["m"] as? [String: Any], let show = Self.show(m) else { throw CatalogError.unreadable }
        let edges = ((m["relations"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        func related(_ type: String) -> Int? {
            let nodes = edges.filter { $0["relationType"] as? String == type }.compactMap { $0["node"] as? [String: Any] }
                .filter { Self.seasonFormats.contains($0["format"] as? String ?? "") }
            let sorted = nodes.sorted { Self.startKey($0) < Self.startKey($1) }
            return (type == "PREQUEL" ? sorted.last : sorted.first)?["id"] as? Int
        }
        let streaming = Self.streamingEpisodes(m["streamingEpisodes"] as? [[String: Any]] ?? [], count: show.episodes)
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
        let candidates = [titles["en"], titles["en_us"], a["canonicalTitle"], titles["en_jp"]].compactMap { $0 as? String }
        // Kitsu fills missing names with "Episode 5"; those say nothing.
        let title = candidates.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.range(of: #"^(?i)episode\s*\d+$"#, options: .regularExpression) == nil }
        let thumb = ((a["thumbnail"] as? [String: Any])?["original"] as? String).flatMap(URL.init(string:))
        return (title, thumb)
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
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
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else { throw CatalogError.unreadable }
        return payload
    }

    /// Sends a request, waiting out one rate limit response.
    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("TorrentStream/4 (iOS)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
                session.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error); return }
                    cont.resume(returning: (data ?? Data(), response))
                }.resume()
            }
            guard let http = response as? HTTPURLResponse else { return data }
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
