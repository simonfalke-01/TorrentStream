import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Who a show is for, from MyAnimeList's rating. AniList has none.
public enum ContentRating: String, Codable, Sendable, CaseIterable {
    case allAges = "G"
    case children = "PG"
    case teens = "PG-13"
    case older17 = "R"
    case mildNudity = "R+"
    case adult = "Rx"

    /// MyAnimeList's rating as Jikan spells it, "PG-13 - Teens 13 or older". Nil for "None" and anything unknown.
    public init?(mal: String) {
        let code = mal.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let rating = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(code) == .orderedSame }) else { return nil }
        self = rating
    }

    /// What the outlined badge says. MyAnimeList's codes, except "Rx", which reads as a prescription.
    public var badge: String { self == .adult ? "18+" : rawValue }

    /// Who it's for, in words.
    public var summary: String {
        switch self {
        case .allAges: return "All ages"
        case .children: return "Children"
        case .teens: return "Teens 13 or older"
        case .older17: return "17 or older"
        case .mildNudity: return "17 or older, mild nudity"
        case .adult: return "Adults only"
        }
    }

    /// What VoiceOver says for the badge.
    public var spokenLabel: String { self == .adult ? "Adults only" : "Rated \(badge)" }

    /// The rating a show's page shows: AniList's adult flag marks explicit content whatever MyAnimeList says, and
    /// stands in when MyAnimeList's rating isn't known.
    public static func shown(mal: ContentRating?, isAdult: Bool?) -> ContentRating? {
        isAdult == true ? .adult : mal
    }
}

/// Jikan, which serves MyAnimeList's data, allows 3 requests a second and 60 a minute and answers past that with a
/// 429. Requests are spaced to stay under both; after a 429, or when the next free slot is too far off, they fail at
/// once instead of waiting, so nothing on screen waits on a rating.
final class JikanBudget: @unchecked Sendable {
    static let shared = JikanBudget()

    private let lock = NSLock()
    /// Start times booked in the last minute, oldest first. Some may be just ahead of now.
    private var starts: [Date] = []
    private var blockedUntil = Date.distantPast

    static let spacing: TimeInterval = 0.4
    /// Under Jikan's 60, for requests other apps on the network make.
    static let perMinute = 50
    /// Longest a request waits for its slot before giving up.
    static let maxWait: TimeInterval = 4

    init() {}

    func admit() async throws {
        let wait = try reserve(now: Date())
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// Books the next free slot and returns how long until it.
    func reserve(now: Date) throws -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard now >= blockedUntil else { throw CatalogError.rateLimited }
        starts.removeAll { now.timeIntervalSince($0) >= 60 }
        var slot = max(now, (starts.last ?? .distantPast).addingTimeInterval(Self.spacing))
        if starts.count >= Self.perMinute {
            slot = max(slot, starts[starts.count - Self.perMinute].addingTimeInterval(60))
        }
        let wait = slot.timeIntervalSince(now)
        guard wait <= Self.maxWait else { throw CatalogError.rateLimited }
        starts.append(slot)
        return wait
    }

    func finished(_ response: URLResponse?, now: Date = Date()) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 429 else { return }
        let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 60
        hold(for: wait, now: now)
    }

    /// Jikan couldn't be reached; it's left alone for a couple of minutes.
    func unreachable(now: Date = Date()) { hold(for: 120, now: now) }

    private func hold(for seconds: TimeInterval, now: Date) {
        lock.lock(); defer { lock.unlock() }
        blockedUntil = max(blockedUntil, now.addingTimeInterval(min(max(seconds, 5), 300)))
    }
}

extension ShowCatalog {
    /// MyAnimeList's rating of an entry, from Jikan, else from Kitsu, which copies MyAnimeList's scale and has no
    /// request limit. Nil when neither has one. Never waits on Jikan's limit: a held-off Jikan goes straight to Kitsu.
    public func contentRating(malID: Int?, anilistID: Int) async throws -> ContentRating? {
        if let malID {
            // Bounded here too: a connection that never opens can outlast the request's own timeout.
            let jikan = await Self.within(Self.jikanWait) { try? await self.jikanRating(malID: malID) }
            if jikan == nil { JikanBudget.shared.unreachable() }
            if let rating = jikan ?? nil { return rating }
        }
        return try await kitsuRating(anilistID: anilistID)
    }

    static let jikanWait: TimeInterval = 6

    /// MyAnimeList's rating from Jikan. Throws `rateLimited` without waiting while Jikan is holding requests off.
    func jikanRating(malID: Int) async throws -> ContentRating? {
        guard let url = URL(string: "https://api.jikan.moe/v4/anime/\(malID)") else { throw CatalogError.unreadable }
        try await JikanBudget.shared.admit()
        var request = URLRequest(url: url, timeoutInterval: Self.jikanWait)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TorrentStream/4 (iOS)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse?
        do {
            (data, response) = try await HTTP.data(session, for: request)
        } catch {
            if !Task.isCancelled { JikanBudget.shared.unreachable() }
            throw error
        }
        JikanBudget.shared.finished(response)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw CatalogError.rateLimited }
            if http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else { throw CatalogError.http(http.statusCode) }
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CatalogError.unreadable }
        return Self.malRating(root)
    }

    static func malRating(_ root: [String: Any]) -> ContentRating? {
        ((root["data"] as? [String: Any])?["rating"] as? String).flatMap(ContentRating.init(mal:))
    }

    private func kitsuRating(anilistID: Int) async throws -> ContentRating? {
        let link = "https://kitsu.app/api/edge/mappings?filter%5BexternalSite%5D=anilist/anime&filter%5BexternalId%5D=\(anilistID)"
            + "&include=item&fields%5Banime%5D=ageRating,ageRatingGuide"
        guard let url = URL(string: link) else { throw CatalogError.unreadable }
        return Self.kitsuRating(try await json(url))
    }

    /// Kitsu folds MyAnimeList's PG and PG-13 into "PG" and R and R+ into "R"; its guide text tells them apart. A
    /// "PG" whose guide doesn't say which is left unrated rather than guessed.
    static func kitsuRating(_ root: [String: Any]) -> ContentRating? {
        guard let item = ((root["included"] as? [[String: Any]]) ?? []).first(where: { $0["type"] as? String == "anime" }),
              let a = item["attributes"] as? [String: Any] else { return nil }
        let guide = ((a["ageRatingGuide"] as? String) ?? "").lowercased()
        switch (a["ageRating"] as? String)?.uppercased() {
        case "G": return .allAges
        case "PG":
            if guide.contains("13") || guide.contains("teen") { return .teens }
            return guide.contains("child") ? .children : nil
        case "R": return guide.contains("nudity") ? .mildNudity : .older17
        case "R18": return .adult
        default: return nil
        }
    }
}
