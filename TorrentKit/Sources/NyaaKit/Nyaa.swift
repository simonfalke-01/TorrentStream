import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Search client for nyaa.si.
//
// The HTML listing is used rather than the RSS feed because the feed ignores the sort parameters
// and cannot be paginated. Sorting is done by the server across all results, never client-side.

// MARK: - Query

public enum NyaaSort: String, CaseIterable, Identifiable, Sendable {
    case date = "id"
    case seeders
    case leechers
    case downloads
    case size
    case comments

    public var id: String { rawValue }
}

public enum NyaaFilter: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case noRemakes = 1
    case trustedOnly = 2

    public var id: Int { rawValue }
}

public struct NyaaCategory: Hashable, Identifiable, Sendable {
    /// Nyaa's category code, for example "1_2".
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// True for "All" and top-level categories, whose results span several subcategories.
    public var isBroad: Bool { id == "0_0" || id.hasSuffix("_0") }

    public static let all = NyaaCategory(id: "0_0", title: "All Categories")

    /// Categories grouped as on the site. The first entry of each group is the parent category.
    public static let groups: [[NyaaCategory]] = [
        [NyaaCategory(id: "1_0", title: "Anime"),
         NyaaCategory(id: "1_2", title: "English-translated"),
         NyaaCategory(id: "1_3", title: "Non-English-translated"),
         NyaaCategory(id: "1_4", title: "Raw"),
         NyaaCategory(id: "1_1", title: "Music Video")],
        [NyaaCategory(id: "4_0", title: "Live Action"),
         NyaaCategory(id: "4_1", title: "English-translated"),
         NyaaCategory(id: "4_3", title: "Non-English-translated"),
         NyaaCategory(id: "4_4", title: "Raw"),
         NyaaCategory(id: "4_2", title: "Idol and Promotional Video")],
        [NyaaCategory(id: "2_0", title: "Audio"),
         NyaaCategory(id: "2_1", title: "Lossless"),
         NyaaCategory(id: "2_2", title: "Lossy")],
    ]

    public static func find(_ id: String) -> NyaaCategory {
        if id == all.id { return all }
        return groups.joined().first { $0.id == id } ?? all
    }
}

public struct NyaaQuery: Hashable, Sendable {
    public var text: String
    public var category: NyaaCategory
    public var filter: NyaaFilter
    public var sort: NyaaSort
    public var ascending: Bool
    /// Searches Sukebei, Nyaa's adult site, instead.
    public var adult: Bool

    public init(text: String, category: NyaaCategory = .all, filter: NyaaFilter = .all,
                sort: NyaaSort = .seeders, ascending: Bool = false, adult: Bool = false) {
        self.text = text
        self.category = category
        self.filter = filter
        self.sort = sort
        self.ascending = ascending
        self.adult = adult
    }

    public func url(base: URL, page: Int) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if c.path.isEmpty { c.path = "/" }
        c.queryItems = [
            URLQueryItem(name: "f", value: String(filter.rawValue)),
            URLQueryItem(name: "c", value: category.id),
            URLQueryItem(name: "q", value: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "s", value: sort.rawValue),
            URLQueryItem(name: "o", value: ascending ? "asc" : "desc"),
            URLQueryItem(name: "p", value: String(max(1, page))),
        ]
        return c.url!
    }
}

// MARK: - Results

public struct NyaaResult: Identifiable, Hashable, Sendable {
    public enum Trust: Sendable { case normal, trusted, remake }

    /// Nyaa's numeric torrent id.
    public let id: Int
    public let title: String
    public let category: NyaaCategory
    public let size: Int64
    public let date: Date
    public let seeders: Int
    public let leechers: Int
    public let downloads: Int
    public let comments: Int
    public let trust: Trust
    public let magnet: String?
    /// Lowercase hex, taken from the magnet link.
    public let infoHash: String?
    public let torrentURL: URL?
    public let pageURL: URL
}

public struct NyaaPage: Sendable {
    public let results: [NyaaResult]
    public let hasNextPage: Bool
    /// The count the site reports. It caps at 1,000.
    public let totalResults: Int?
}

public enum NyaaError: LocalizedError {
    case http(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .http(429): return "Nyaa is limiting requests. Wait a moment and try again."
        case .http(let code): return "Nyaa returned an error (HTTP \(code))."
        case .unreadable: return "Nyaa sent a page TorrentStream couldn't read."
        }
    }
}

// MARK: - Client

public final class NyaaClient: @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "https://nyaa.si")!
    /// Sukebei, where adult anime is released.
    public static let adultBaseURL = URL(string: "https://sukebei.nyaa.si")!

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = NyaaClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func search(_ query: NyaaQuery, page: Int = 1) async throws -> NyaaPage {
        let base = query.adult ? Self.adultBaseURL : baseURL
        let data = try await get(query.url(base: base, page: page))
        guard let html = String(data: data, encoding: .utf8) else { throw NyaaError.unreadable }
        return try NyaaParser.parse(html: html, base: base)
    }

    /// Downloads the .torrent file, which gives the file list immediately instead of waiting for peers.
    public func torrentData(for result: NyaaResult) async throws -> Data {
        guard let url = result.torrentURL else { throw NyaaError.unreadable }
        return try await get(url)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("TorrentStream/2 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NyaaError.http(http.statusCode)
        }
        return data
    }
}

// MARK: - Parser

public enum NyaaParser {
    public static func parse(html: String, base: URL = NyaaClient.defaultBaseURL) throws -> NyaaPage {
        let body: Substring
        if let start = html.range(of: "<tbody>"), let end = html.range(of: "</tbody>", range: start.upperBound..<html.endIndex) {
            body = html[start.upperBound..<end.lowerBound]
        } else if html.contains("torrent-list") || html.contains("No results found") || html.contains("pagination") {
            body = ""
        } else {
            throw NyaaError.unreadable
        }

        var results: [NyaaResult] = []
        for row in matches(#"<tr class="([a-z]*)">(.*?)</tr>"#, in: String(body)) {
            if let r = parseRow(rowClass: row[0], html: row[1], base: base) { results.append(r) }
        }

        let hasNext = html.range(of: #"<li class="next">\s*<a href="#, options: .regularExpression) != nil
        let total = first(#"out of ([0-9,]+) results"#, in: html).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        return NyaaPage(results: results, hasNextPage: hasNext, totalResults: total)
    }

    private static func parseRow(rowClass: String, html: String, base: URL) -> NyaaResult? {
        guard let titleMatch = matches(#"<a href="/view/([0-9]+)" title="([^"]*)""#, in: html).first,
              let id = Int(titleMatch[0]) else { return nil }
        let title = decodeEntities(titleMatch[1])

        let categoryID = first(#"href="/\?c=([0-9]_[0-9])""#, in: html) ?? "0_0"
        let categoryTitle = first(#"href="/\?c=[0-9]_[0-9]" title="([^"]*)""#, in: html).map(decodeEntities) ?? ""
        let known = NyaaCategory.find(categoryID)
        let category = known.id == categoryID ? known : NyaaCategory(id: categoryID, title: categoryTitle)

        let magnet = first(#"href="(magnet:[^"]+)""#, in: html).map(decodeEntities)
        let infoHash = magnet.flatMap { first(#"btih:([0-9a-fA-F]{40})"#, in: $0) }?.lowercased()
        let torrentPath = first(#"href="(/download/[0-9]+\.torrent)""#, in: html)
        let comments = first(#"class="comments" title="([0-9]+) comments?""#, in: html).flatMap(Int.init) ?? 0
        let timestamp = first(#"data-timestamp="([0-9]+)""#, in: html).flatMap(TimeInterval.init) ?? 0

        // Text cells in order: size, date, seeders, leechers, downloads.
        let cells = matches(#"<td class="text-center"[^>]*>([^<]*)</td>"#, in: html).map {
            $0[0].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cells.count >= 5 else { return nil }
        let n = cells.count

        let trust: NyaaResult.Trust = rowClass == "success" ? .trusted : rowClass == "danger" ? .remake : .normal
        return NyaaResult(
            id: id,
            title: title,
            category: category,
            size: parseSize(cells[n - 5]),
            date: Date(timeIntervalSince1970: timestamp),
            seeders: Int(cells[n - 3]) ?? 0,
            leechers: Int(cells[n - 2]) ?? 0,
            downloads: Int(cells[n - 1]) ?? 0,
            comments: comments,
            trust: trust,
            magnet: magnet,
            infoHash: infoHash,
            torrentURL: torrentPath.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
            pageURL: URL(string: "/view/\(id)", relativeTo: base)!.absoluteURL
        )
    }

    /// "1.4 GiB" to bytes. Nyaa uses binary units.
    static func parseSize(_ text: String) -> Int64 {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return 0 }
        let exponent: Double
        switch parts[1] {
        case "Bytes", "B": exponent = 0
        case "KiB": exponent = 1
        case "MiB": exponent = 2
        case "GiB": exponent = 3
        case "TiB": exponent = 4
        default: return 0
        }
        return Int64(value * pow(1024, exponent))
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(10).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                if let decoded = decodeEntity(entity) {
                    out.append(decoded)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ e: String) -> String? {
        switch e {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            let scalar: UInt32?
            if e.hasPrefix("#x") || e.hasPrefix("#X") { scalar = UInt32(e.dropFirst(2), radix: 16) }
            else if e.hasPrefix("#") { scalar = UInt32(e.dropFirst()) }
            else { scalar = nil }
            return scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    // MARK: regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = cache[pattern] { return r }
        let r = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        cache[pattern] = r
        return r
    }

    /// Capture groups of every match.
    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        let ns = s as NSString
        return regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        matches(pattern, in: s).first?.first
    }
}
