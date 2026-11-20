import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Poster, backdrop and synopsis for a show or movie.
public struct CatalogEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case series, movie }

    public var title: String
    public var kind: Kind
    public var year: Int?
    public var overview: String?
    public var genres: [String]
    public var episodeCount: Int?
    public var posterURL: URL?
    public var backdropURL: URL?
    /// "AniList" or "Cinemeta".
    public var source: String

    public init(title: String, kind: Kind, year: Int? = nil, overview: String? = nil, genres: [String] = [],
                episodeCount: Int? = nil, posterURL: URL? = nil, backdropURL: URL? = nil, source: String) {
        self.title = title
        self.kind = kind
        self.year = year
        self.overview = overview
        self.genres = genres
        self.episodeCount = episodeCount
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.source = source
    }
}

/// What to look up, derived from a release name.
public struct CatalogQuery: Hashable, Sendable {
    public var title: String
    public var altTitles: [String]
    public var year: Int?
    public var season: Int?
    public var prefersAnime: Bool
    public var isEpisodic: Bool

    /// Cache key: the same show from different release groups shares one entry.
    public var key: String {
        var k = ReleaseName.normalize(title)
        if let season, season > 1 { k += " s\(season)" }
        if let year, !isEpisodic { k += " \(year)" }
        return k
    }

    public init(release: ReleaseInfo, prefersAnime: Bool? = nil) {
        title = release.title
        altTitles = release.altTitles
        year = release.year
        season = release.season
        isEpisodic = release.isEpisodic
        self.prefersAnime = prefersAnime ?? release.isAnimeStyle
    }

    public var isSearchable: Bool { ReleaseName.normalize(title).count >= 2 }
}

public enum CatalogError: Error { case http(Int), unreadable }

public final class CatalogClient: @unchecked Sendable {
    private let session: URLSession
    /// Below this word overlap a search hit is treated as a different title.
    static let minimumSimilarity = 0.5

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Looks up several anime in one AniList request. Keys missing from the result could not be checked
    /// (network failure); keys mapped to nil were checked and not found.
    public func lookupAnime(_ queries: [CatalogQuery]) async throws -> [String: CatalogEntry?] {
        guard !queries.isEmpty else { return [:] }
        var fields: [String] = []
        var variables: [String: String] = [:]
        var params: [String] = []
        for (i, q) in queries.enumerated() {
            params.append("$s\(i): String")
            variables["s\(i)"] = Self.animeSearchText(q)
            fields.append("q\(i): Page(perPage: 4) { media(search: $s\(i), type: ANIME, sort: SEARCH_MATCH, isAdult: false) { ...M } }")
        }
        let query = """
        query (\(params.joined(separator: ", "))) { \(fields.joined(separator: " ")) }
        fragment M on Media { title { romaji english } synonyms format episodes seasonYear description(asHtml: false) genres coverImage { extraLarge large } bannerImage }
        """
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await send(request, accept: [200, 404])

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else { throw CatalogError.unreadable }
        var out: [String: CatalogEntry?] = [:]
        for (i, q) in queries.enumerated() {
            let media = ((payload["q\(i)"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
            out[q.key] = Self.bestAnime(media, for: q)
        }
        return out
    }

    /// Looks up a live-action show or movie on Cinemeta, trying the type the release name suggests first.
    public func lookupLiveAction(_ q: CatalogQuery) async throws -> CatalogEntry? {
        let order: [CatalogEntry.Kind] = q.isEpisodic ? [.series, .movie] : [.movie, .series]
        for kind in order {
            if let hit = try await cinemeta(q, kind: kind) { return hit }
        }
        return nil
    }

    // MARK: AniList

    static func animeSearchText(_ q: CatalogQuery) -> String {
        if let season = q.season, season > 1 { return "\(q.title) season \(season)" }
        return q.title
    }

    static func bestAnime(_ media: [[String: Any]], for q: CatalogQuery) -> CatalogEntry? {
        var best: (score: Double, entry: CatalogEntry)?
        for m in media {
            let titles = m["title"] as? [String: Any] ?? [:]
            let romaji = titles["romaji"] as? String
            let english = titles["english"] as? String
            let names = [romaji, english].compactMap { $0 } + ((m["synonyms"] as? [String]) ?? [])
            let wanted = [q.title] + q.altTitles
            var score = names.flatMap { n in wanted.map { ReleaseName.similarity($0, n) } }.max() ?? 0
            let year = m["seasonYear"] as? Int
            if let y = q.year, let year, y == year { score += 0.1 }
            guard score >= minimumSimilarity, score > (best?.score ?? 0) else { continue }
            let cover = m["coverImage"] as? [String: Any]
            let poster = (cover?["extraLarge"] as? String) ?? (cover?["large"] as? String)
            let format = m["format"] as? String
            best = (score, CatalogEntry(
                title: english ?? romaji ?? q.title,
                kind: format == "MOVIE" ? .movie : .series,
                year: year,
                overview: (m["description"] as? String).map(plainText),
                genres: (m["genres"] as? [String]) ?? [],
                episodeCount: m["episodes"] as? Int,
                posterURL: poster.flatMap(URL.init(string:)),
                backdropURL: (m["bannerImage"] as? String).flatMap(URL.init(string:)),
                source: "AniList"
            ))
        }
        return best?.entry
    }

    // MARK: Cinemeta

    private static let cinemeta = "https://v3-cinemeta.strem.io"

    private func cinemeta(_ q: CatalogQuery, kind: CatalogEntry.Kind) async throws -> CatalogEntry? {
        let type = kind == .movie ? "movie" : "series"
        let term = q.title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q.title
        let url = URL(string: "\(Self.cinemeta)/catalog/\(type)/top/search=\(term).json")!
        let data = try await send(URLRequest(url: url, timeoutInterval: 20), accept: [200])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metas = root["metas"] as? [[String: Any]] else { return nil }
        guard let pick = Self.bestCinemeta(metas, for: q), let id = pick["imdb_id"] as? String ?? pick["id"] as? String else {
            return nil
        }
        var entry = CatalogEntry(
            title: pick["name"] as? String ?? q.title,
            kind: kind,
            year: Self.year(pick["releaseInfo"] as? String ?? pick["year"] as? String),
            posterURL: Self.metahub(pick["poster"] as? String, size: "medium"),
            backdropURL: Self.metahub(pick["background"] as? String, size: "medium"),
            source: "Cinemeta"
        )
        // The detail record adds the synopsis and genres.
        if let detail = try? await send(URLRequest(url: URL(string: "\(Self.cinemeta)/meta/\(type)/\(id).json")!, timeoutInterval: 20),
                                        accept: [200]),
           let meta = (try? JSONSerialization.jsonObject(with: detail) as? [String: Any])?["meta"] as? [String: Any] {
            entry.overview = (meta["description"] as? String).map(Self.plainText)
            entry.genres = (meta["genres"] as? [String]) ?? (meta["genre"] as? [String]) ?? []
        }
        return entry
    }

    static func bestCinemeta(_ metas: [[String: Any]], for q: CatalogQuery) -> [String: Any]? {
        var best: (score: Double, meta: [String: Any])?
        for m in metas.prefix(6) {
            guard let name = m["name"] as? String else { continue }
            var score = ([q.title] + q.altTitles).map { ReleaseName.similarity($0, name) }.max() ?? 0
            if let y = q.year, let year = year(m["releaseInfo"] as? String ?? m["year"] as? String) {
                if y == year { score += 0.2 } else if !q.isEpisodic && abs(y - year) > 1 { score -= 0.3 }
            }
            if score >= minimumSimilarity, score > (best?.score ?? 0) { best = (score, m) }
        }
        return best?.meta
    }

    /// Cinemeta lists small images; metahub serves larger ones at the same path.
    static func metahub(_ s: String?, size: String) -> URL? {
        guard let s else { return nil }
        let resized = s.replacingOccurrences(of: #"/(small|medium|large)/"#, with: "/\(size)/", options: .regularExpression)
        return URL(string: resized)
    }

    // MARK: helpers

    private func send(_ request: URLRequest, accept: Set<Int>) async throws -> Data {
        var request = request
        request.setValue("TorrentStream/3 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), response))
            }.resume()
        }
        if let http = response as? HTTPURLResponse, !accept.contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        return data
    }

    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// Strips HTML tags, entities and source credits from a synopsis.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"(?i)\s*[\[(](source|written by)[^\])]*[\])]\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
