import Foundation
import CatalogKit

/// The release and file an offline copy of an episode comes from.
public struct DownloadRelease: Codable, Hashable, Sendable {
    public var infoHash: String
    public var fileIndex: Int
    public var magnet: String?
    public var torrentURL: URL?
    public var group: String?
    public var isBatch: Bool
    /// Bytes of the episode's file, once known.
    public var length: Int64?

    public init(infoHash: String, fileIndex: Int, magnet: String? = nil, torrentURL: URL? = nil, group: String? = nil,
                isBatch: Bool = false, length: Int64? = nil) {
        self.infoHash = infoHash
        self.fileIndex = fileIndex
        self.magnet = magnet
        self.torrentURL = torrentURL
        self.group = group
        self.isBatch = isBatch
        self.length = length
    }
}

public enum DownloadState: String, Codable, Hashable, Sendable {
    /// Waiting for its turn to find a release.
    case queued
    /// A release is being looked for.
    case finding
    /// The file is being fetched.
    case downloading
    /// Held by the viewer. Nothing sets this yet; it is here for a downloads screen.
    case paused
    case completed
    case failed

    /// States written by a later version decode as `queued`, so the download is picked up rather than lost.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DownloadState(rawValue: raw) ?? .queued
    }

    /// Still on its way to the device.
    public var isPending: Bool { self == .queued || self == .finding || self == .downloading }
}

/// One episode (or movie) kept on the device to watch offline.
public struct DownloadRecord: Codable, Hashable, Identifiable, Sendable {
    /// The episode's key: show, season and episode.
    public var id: String
    /// The show's first season, which progress and My List are keyed by.
    public var show: Show
    public var seasonID: Int
    public var season: Int
    public var episode: Int
    public var episodeTitle: String?
    public var thumbnailURL: URL?
    public var isMovie: Bool
    /// Nil until a release is found.
    public var release: DownloadRelease?
    public var state: DownloadState
    /// Why the last attempt failed, for the viewer.
    public var failure: String?
    public var addedAt: Date
    public var completedAt: Date?
    /// Higher starts first. Everything is 0 today.
    public var priority: Int

    public init(id: String, show: Show, seasonID: Int, season: Int, episode: Int, episodeTitle: String? = nil,
                thumbnailURL: URL? = nil, isMovie: Bool = false, release: DownloadRelease? = nil,
                state: DownloadState = .queued, failure: String? = nil, addedAt: Date = Date(),
                completedAt: Date? = nil, priority: Int = 0) {
        self.id = id
        self.show = show
        self.seasonID = seasonID
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.thumbnailURL = thumbnailURL
        self.isMovie = isMovie
        self.release = release
        self.state = state
        self.failure = failure
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id, show, seasonID, season, episode, episodeTitle, thumbnailURL, isMovie, release, state, failure, addedAt,
             completedAt, priority
    }

    /// Fields added later have defaults, so older files keep reading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        show = try c.decode(Show.self, forKey: .show)
        seasonID = try c.decode(Int.self, forKey: .seasonID)
        season = try c.decodeIfPresent(Int.self, forKey: .season) ?? 1
        episode = try c.decode(Int.self, forKey: .episode)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle)
        thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        isMovie = try c.decodeIfPresent(Bool.self, forKey: .isMovie) ?? false
        release = try? c.decodeIfPresent(DownloadRelease.self, forKey: .release)
        state = try c.decodeIfPresent(DownloadState.self, forKey: .state) ?? .queued
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }
}

/// How many of a show's episodes are kept offline and how many are still coming.
public struct DownloadSummary: Hashable, Sendable {
    public var total = 0
    public var completed = 0
    public var pending = 0
    public var failed = 0
    public var isEmpty: Bool { total == 0 }
    public init() {}
}

/// Every download, as saved to disk. Versioned so later releases (a downloads screen, pausing, ordering, storage
/// limits) can extend it; a record that can't be read is skipped rather than losing the rest.
public struct DownloadLibrary: Sendable {
    public static let currentVersion = 1
    public private(set) var records: [DownloadRecord] = []

    public init(records: [DownloadRecord] = []) {
        self.records = records
    }

    public subscript(id: String) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    /// Adds a record unless the episode is already there. Returns whether it was added.
    @discardableResult
    public mutating func add(_ record: DownloadRecord) -> Bool {
        guard self[record.id] == nil else { return false }
        records.append(record)
        return true
    }

    public mutating func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
    }

    @discardableResult
    public mutating func remove(_ id: String) -> DownloadRecord? {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: i)
    }

    /// Records of a show, in season and episode order.
    public func records(show id: Int) -> [DownloadRecord] {
        records.filter { $0.show.id == id }.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    public func summary(show id: Int) -> DownloadSummary {
        var s = DownloadSummary()
        for r in records where r.show.id == id {
            s.total += 1
            switch r.state {
            case .completed: s.completed += 1
            case .failed: s.failed += 1
            case .paused: break
            default: s.pending += 1
            }
        }
        return s
    }

    /// Shows with at least one download, the most recently added first.
    public var shows: [Show] {
        var seen = Set<Int>()
        return records.sorted { $0.addedAt > $1.addedAt }.compactMap { seen.insert($0.show.id).inserted ? $0.show : nil }
    }

    /// The next record whose release should be found: highest priority, then the show's own order, oldest show first.
    public var nextToFind: DownloadRecord? { nextToFind(skipping: []) }

    /// The next record to find among shows other than `shows`, so shows are found side by side while a show's own
    /// episodes go one at a time (and share a season pack once one is found).
    public func nextToFind(skipping shows: Set<Int>) -> DownloadRecord? {
        let firstAdded = Dictionary(records.map { ($0.show.id, $0.addedAt) }, uniquingKeysWith: min)
        return records.filter { $0.state == .queued && !shows.contains($0.show.id) }.min { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let fa = firstAdded[a.show.id] ?? a.addedAt, fb = firstAdded[b.show.id] ?? b.addedAt
            if a.show.id != b.show.id { return fa != fb ? fa < fb : a.show.id < b.show.id }
            return (a.season, a.episode) < (b.season, b.episode)
        }
    }

    /// Records fetching from (or kept in) a release, except `id`.
    public func others(using infoHash: String, excluding id: String? = nil) -> [DownloadRecord] {
        records.filter { $0.release?.infoHash == infoHash && $0.id != id }
    }

    /// Info hashes of every release a download uses.
    public var infoHashes: Set<String> { Set(records.compactMap { $0.release?.infoHash }) }

    /// Releases of a show's season packs already downloading, which may hold other episodes too.
    public func packs(show id: Int) -> [DownloadRelease] {
        var seen = Set<String>()
        return records.compactMap { r in
            guard r.show.id == id, let rel = r.release, rel.isBatch, seen.insert(rel.infoHash).inserted else { return nil }
            return rel
        }
    }

    // MARK: disk

    private struct File: Codable {
        var version: Int
        var records: [Failable]
    }

    private struct Failable: Codable {
        var record: DownloadRecord?
        init(_ record: DownloadRecord) { self.record = record }
        init(from decoder: Decoder) throws { record = try? DownloadRecord(from: decoder) }
        func encode(to encoder: Encoder) throws { try record?.encode(to: encoder) }
    }

    /// Reads a saved library. Data that can't be read at all gives an empty library.
    public static func decode(_ data: Data) -> DownloadLibrary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return DownloadLibrary() }
        var seen = Set<String>()
        return DownloadLibrary(records: file.records.compactMap(\.record).filter { seen.insert($0.id).inserted })
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(File(version: Self.currentVersion, records: records.map(Failable.init)))
    }
}
