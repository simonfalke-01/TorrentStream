import Foundation
import SwiftUI
import TorrentKit
import NyaaKit
import CatalogKit
import SourceKit

/// The catalog episode a playback request plays.
struct ShowPlayback {
    /// First season of the show (or the movie), which progress and My List are keyed by.
    let show: Show
    let seasonID: Int
    let season: Int
    let episode: Int
    let episodeTitle: String?
    let thumbnailURL: URL?
    let isMovie: Bool
    /// How to find the same release again.
    let source: SavedSource
    var key: String { ShowsModel.key(show.id, seasonID, episode) }
}

struct EpisodeProgress: Codable, Hashable {
    var position: Double
    var duration: Double
    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isWatched: Bool { fraction >= 0.9 }
}

/// The last episode played of a show.
struct WatchEntry: Codable, Identifiable, Hashable {
    var show: Show
    var seasonID: Int
    var season: Int
    var episode: Int
    var watchedAt: Date
    var id: Int { show.id }
}

/// A release that played an episode, kept so the episode starts the same way next time.
struct SavedSource: Codable, Hashable {
    var infoHash: String
    var fileIndex: Int
    var magnet: String?
    var torrentURL: URL?
    var group: String?
    var isBatch: Bool
}

/// A release picked ahead of time for an episode the viewer is likely to play next.
struct PlannedSource: Codable, Hashable {
    var source: SavedSource
    var at: Date
}

/// Something to start: an episode, the show's next episode, or a movie.
struct EpisodeLaunch: Identifiable {
    let id = UUID()
    let show: Show
    /// Season and episode; nil plays what's next for the viewer.
    var seasonID: Int? = nil
    var episode: Int? = nil
    /// A version the viewer chose.
    var source: EpisodeSource? = nil
}

/// An episode resolved to a file in a release.
struct ResolvedEpisode {
    let torrent: Torrent
    let file: TorrentFile
    let source: SavedSource
}

/// What a show's Play button starts.
struct ShowUpNext {
    let season: ShowSeason
    let episode: ShowEpisode
    let resumeAt: Double?
    let remaining: Double?
    /// The viewer has watched something of this show before.
    let isContinuing: Bool
}

enum ShowError: LocalizedError {
    case noSources
    case unplayable
    case notAired

    var errorDescription: String? {
        switch self {
        case .noSources: return "No one is sharing this episode right now."
        case .unplayable: return "None of the versions found would start. Try another version."
        case .notAired: return "This episode hasn't aired yet."
        }
    }
}

/// Shows and movies from the catalog: what to browse, what's in My List, what was watched and how far, and
/// finding a release that plays each episode.
@MainActor
final class ShowsModel: ObservableObject {
    @Published private(set) var rows: [ShowRow] = []
    @Published private(set) var rowsFailed = false
    @Published private(set) var myList: [Show] = []
    /// Most recently watched first.
    @Published private(set) var history: [WatchEntry] = []
    @Published private(set) var progress: [String: EpisodeProgress] = [:]
    @Published private(set) var details: [Int: ShowDetails] = [:]
    /// Shows like each show, by root id.
    @Published private(set) var recommendations: [Int: [Show]] = [:]
    /// Episodes airing from two days ago to a week ahead, by time.
    @Published private(set) var schedule: [AiringEpisode] = []
    @Published private(set) var scheduleFailed = false
    /// When each show was added to My List, by root id.
    @Published private(set) var addedAt: [Int: Date] = [:]

    private unowned let app: AppModel
    /// Episodes kept on the device, which play from there.
    weak var downloads: DownloadsModel?
    private let catalog = ShowCatalog()
    private let defaults = UserDefaults.standard
    private let baseURL: URL
    /// Any season's id to the id of the show's first season.
    private var roots: [Int: Int] = [:]
    private var savedSources: [String: SavedSource] = [:]
    /// Release group last played per show, preferred for its other episodes.
    private var groups: [String: String] = [:]
    private var sourceCache: [String: (at: Date, list: [EpisodeSource])] = [:]
    /// Next episodes already found and partly loaded.
    private var prepared: [String: ResolvedEpisode] = [:]
    private var rowsFetchedAt: Date?
    private var scheduleFetchedAt: Date?
    private var skipCache: [String: [SkipSegment]] = [:]
    private var detailsTasks: [Int: Task<ShowDetails, Error>] = [:]
    /// Shows whose episode names and stills were looked up this session, so a cached copy gets them once.
    private var enriched: Set<Int> = []
    private var prefetchTask: Task<Void, Never>?
    /// Gets likely next episodes ready before Play is pressed.
    private lazy var prewarmer = Prewarmer(app: app)
    /// Warm-ups finding an episode's release, by episode key, so pressing Play joins them instead of searching again.
    private var resolving: [String: Task<ResolvedEpisode?, Never>] = [:]
    /// Releases picked ahead of time, by episode key.
    private var planned: [String: PlannedSource] = [:]
    private var planTask: Task<Void, Never>?
    /// How long a release picked ahead of time is trusted to still be the best one.
    private static let planLifetime: TimeInterval = 6 * 3600

    private struct Saved: Codable {
        var myList: [Show] = []
        var history: [WatchEntry] = []
        var progress: [String: EpisodeProgress] = [:]
        var sources: [String: SavedSource] = [:]
        var groups: [String: String] = [:]
        var roots: [String: Int] = [:]
        var addedAt: [String: Date]? = nil
        var planned: [String: PlannedSource]? = nil
    }

    private struct SavedRows: Codable {
        var rows: [ShowRow]
        var fetchedAt: Date
    }

    init(app: AppModel) {
        self.app = app
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: detailsDirectory, withIntermediateDirectories: true)
        restore()
    }

    nonisolated static func key(_ show: Int, _ season: Int, _ episode: Int) -> String { "\(show).\(season).\(episode)" }

    func rootID(_ show: Show) -> Int { roots[show.id] ?? show.id }

    // MARK: browsing

    /// Loads the home rows, from disk first, then from the catalog when they are a few hours old.
    func loadRows(force: Bool = false) async {
        if !force, let at = rowsFetchedAt, Date().timeIntervalSince(at) < 6 * 3600, !rows.isEmpty { return }
        do {
            let fresh = try await catalog.browse()
            rows = fresh
            rowsFailed = false
            rowsFetchedAt = Date()
            if let data = try? JSONEncoder().encode(SavedRows(rows: fresh, fetchedAt: Date())) {
                try? data.write(to: rowsURL, options: .atomic)
            }
        } catch {
            rowsFailed = rows.isEmpty
        }
    }

    func search(_ text: String) async throws -> [Show] {
        try await catalog.search(text)
    }

    /// Shows the app already knows whose names hold every word typed: My List and started shows first, then
    /// the home shelves and shows seen this session. Shown while the catalog is asked.
    func localMatches(_ text: String, limit: Int = 12) -> [Show] {
        var seen = Set<Int>()
        var out: [Show] = []
        func consider(_ show: Show) {
            guard out.count < limit, Self.matches(show, text), seen.insert(rootID(show)).inserted else { return }
            out.append(show)
        }
        myList.forEach(consider)
        history.forEach { consider(details[$0.show.id]?.show ?? $0.show) }
        rows.forEach { $0.shows.forEach(consider) }
        details.values.forEach { consider($0.show) }
        recommendations.values.forEach { $0.forEach(consider) }
        return out
    }

    nonisolated static func matches(_ show: Show, _ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return false }
        let names = ([show.title, show.romaji, show.english].compactMap { $0 } + show.synonyms).joined(separator: " ")
        return words.allSatisfy { names.localizedStandardContains($0) }
    }

    /// Loads shows like this one for the bottom of its page. Waits behind what the viewer is waiting on when
    /// AniList's request budget is low.
    func loadRecommendations(_ show: Show) async {
        let root = rootID(show)
        guard recommendations[root] == nil else { return }
        let catalog = self.catalog
        do {
            let list = try await CatalogPriority.$isBackground.withValue(true) { try await catalog.recommendations(id: root) }
            recommendations[root] = list.filter { $0.id != root && !$0.isUpcoming }
        } catch CatalogError.rateLimited {
            // Tried again next time the page opens.
        } catch {
            recommendations[root] = []
        }
    }

    /// What airs from two days ago to six days ahead. Refreshed every half hour.
    func loadSchedule(force: Bool = false) async {
        if !force, let at = scheduleFetchedAt, Date().timeIntervalSince(at) < 1800, !schedule.isEmpty { return }
        let today = Calendar.current.startOfDay(for: Date())
        guard let from = Calendar.current.date(byAdding: .day, value: -2, to: today),
              let to = Calendar.current.date(byAdding: .day, value: 7, to: today) else { return }
        do {
            schedule = try await catalog.schedule(from: from, to: to).sorted { $0.airingAt < $1.airingAt }
            scheduleFailed = false
            scheduleFetchedAt = Date()
        } catch {
            scheduleFailed = schedule.isEmpty
        }
    }

    /// Intro, recap, credits and preview times for an episode, when the community has marked them.
    func skipSegments(_ ctx: ShowPlayback, duration: Double) async -> [SkipSegment] {
        guard let d = details[ctx.show.id], let s = d.season(id: ctx.seasonID), let mal = s.media.malID else { return [] }
        let key = "\(mal).\(ctx.episode).\(Int(duration))"
        if let hit = skipCache[key] { return hit }
        guard let list = try? await catalog.skipSegments(malID: mal, episode: ctx.episode, duration: duration) else { return [] }
        skipCache[key] = list
        return list
    }

    /// Seasons and episodes. A copy from memory or disk is returned at once unless an episode has aired since it
    /// was fetched; an old copy is then refreshed in the background (the page updates when it arrives). A stale
    /// copy is also returned when the catalog can't be reached.
    @discardableResult
    func loadDetails(_ show: Show, force: Bool = false) async throws -> ShowDetails {
        let root = rootID(show)
        if !force, let d = cachedDetails(show), !Self.hasAiredSinceFetch(d) {
            if !isFresh(d) {
                refreshDetails(show)
            } else if !enriched.contains(root), Self.missesEpisodeInfo(d) {
                Task { await enrich(d) }
            }
            return d
        }
        return try await fetchDetails(show, background: false)
    }

    /// Brings a show's details up to date without anyone waiting on it.
    func refreshDetails(_ show: Show) {
        guard detailsTasks[rootID(show)] == nil else { return }
        Task { _ = try? await fetchDetails(show, background: true) }
    }

    /// Details of shows the viewer is likely to open next, fetched while AniList's request budget has room.
    func prefetchDetails(_ list: [Show]) {
        var started = 0
        for show in list where details[rootID(show)] == nil && detailsTasks[rootID(show)] == nil {
            // Known spare requests, or a couple when nothing is known yet.
            guard started < (AniListBudget.shared.spare.map { $0 / 2 } ?? 2) else { return }
            guard cachedDetails(show) == nil else { continue }
            started += 1
            Task { _ = try? await fetchDetails(show, background: true) }
        }
    }

    /// Continue Watching needs each started show's episodes to know what plays next. All are brought up to date
    /// at once; ones on disk without newly aired episodes don't hold anything up.
    func refreshContinueWatching() async {
        let list = history.prefix(10).map(\.show)
        await withTaskGroup(of: Void.self) { group in
            for show in list {
                group.addTask { @MainActor in _ = try? await self.loadDetails(show) }
            }
        }
    }

    /// "New Episode" in My List needs each airing show's episodes. Copies on disk show at once; old ones are
    /// brought up to date together in the background.
    func refreshMyList() {
        for show in myList.prefix(30) where show.isAiring {
            if let d = cachedDetails(show), isFresh(d), !Self.hasAiredSinceFetch(d) { continue }
            refreshDetails(show)
        }
    }

    private func fetchDetails(_ show: Show, background: Bool) async throws -> ShowDetails {
        let root = rootID(show)
        if let running = detailsTasks[root] {
            do {
                return try await running.value
            } catch CatalogError.rateLimited where !background {
                // That was a background request giving way; this one is wanted now.
            } catch {
                if let d = cachedDetails(show) { return d }
                throw error
            }
        }
        let catalog = self.catalog
        let id = show.id
        let started = Date()
        let task = Task { try await CatalogPriority.$isBackground.withValue(background) { try await catalog.details(id: id) } }
        detailsTasks[root] = task
        defer { if detailsTasks[root] == task { detailsTasks[root] = nil } }
        do {
            // Keep the names and stills found last time while the new copy is looked up again.
            let fetched = try await task.value
            PlaybackTrace.shared.timing("details \(fetched.show.title) (\(background ? "background" : "waited on"))", since: started)
            let d = Self.carryingEpisodeInfo(from: details[root], into: fetched)
            store(d)
            Task { await enrich(d) }
            return d
        } catch {
            if let d = cachedDetails(show) { return d }
            throw error
        }
    }

    func cachedDetails(_ show: Show) -> ShowDetails? {
        let root = rootID(show)
        if let d = details[root] { return d }
        guard let data = try? Data(contentsOf: detailsURL(root)),
              let d = try? JSONDecoder().decode(ShowDetails.self, from: data) else { return nil }
        details[root] = d
        return d
    }

    private func isFresh(_ d: ShowDetails) -> Bool {
        let airing = d.seasons.contains { $0.media.isAiring || $0.media.isUpcoming }
        return Date().timeIntervalSince(d.fetchedAt) < (airing ? 6 * 3600 : 7 * 86400)
    }

    /// An airing season's next episode was due before now, so the copy lacks an episode the viewer may want.
    static func hasAiredSinceFetch(_ d: ShowDetails, now: Date = Date()) -> Bool {
        d.seasons.contains { s in s.media.nextAiringAt.map { $0 <= now } ?? false }
    }

    private func store(_ d: ShowDetails) {
        details[d.show.id] = d
        for s in d.seasons { roots[s.media.id] = d.show.id }
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: detailsURL(d.show.id), options: .atomic) }
        save()
    }

    /// Adds episode names and stills the main catalog lacks.
    private func enrich(_ d: ShowDetails) async {
        enriched.insert(d.show.id)
        let full = await catalog.withEpisodeInfo(d)
        guard full != d else { return }
        // The page may have been refreshed meanwhile; fill that copy rather than replace it.
        store(Self.carryingEpisodeInfo(from: full, into: details[d.show.id] ?? full))
    }

    private static func missesEpisodeInfo(_ d: ShowDetails) -> Bool {
        d.seasons.contains { $0.episodes.contains { $0.isAired && ($0.thumbnailURL == nil || $0.overview == nil) } }
    }

    /// `new` with episode names, stills, synopses and runtimes it lacks taken from `old`.
    private static func carryingEpisodeInfo(from old: ShowDetails?, into new: ShowDetails) -> ShowDetails {
        guard let old else { return new }
        var out = new
        for i in out.seasons.indices {
            guard let before = old.seasons.first(where: { $0.media.id == out.seasons[i].media.id }) else { continue }
            let byNumber = Dictionary(before.episodes.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
            out.seasons[i].episodes = out.seasons[i].episodes.map { e in
                guard let b = byNumber[e.number] else { return e }
                var e = e
                e.title = e.title ?? b.title
                e.thumbnailURL = e.thumbnailURL ?? b.thumbnailURL
                e.overview = e.overview ?? b.overview
                e.runtime = e.runtime ?? b.runtime
                return e
            }
        }
        return out
    }

    // MARK: My List

    func isInMyList(_ show: Show) -> Bool {
        let root = rootID(show)
        return myList.contains { $0.id == root || $0.id == show.id }
    }

    func toggleMyList(_ show: Show) {
        let root = rootID(show)
        if isInMyList(show) {
            myList.removeAll { $0.id == root || $0.id == show.id }
            addedAt[root] = nil
        } else {
            myList.insert(details[root]?.show ?? show, at: 0)
            addedAt[root] = Date()
        }
        save()
    }

    /// An aired episode the viewer hasn't seen follows the last one they finished.
    func hasNewEpisode(_ show: Show) -> Bool {
        let root = rootID(show)
        guard let d = details[root], d.seasons.last?.media.isAiring == true,
              let h = history.first(where: { $0.show.id == root }),
              let s = d.season(id: h.seasonID), let e = s.episodes.first(where: { $0.number == h.episode }),
              progress[Self.key(root, s.id, e.number)]?.isWatched == true else { return false }
        return d.episode(after: s, e) != nil
    }

    // MARK: progress

    func progress(_ show: Show, _ season: ShowSeason, _ episode: ShowEpisode) -> EpisodeProgress? {
        progress[Self.key(rootID(show), season.id, episode.number)]
    }

    func setWatched(_ watched: Bool, show: Show, season: ShowSeason, episode: ShowEpisode) {
        let key = Self.key(rootID(show), season.id, episode.number)
        if watched {
            let d = max(progress[key]?.duration ?? 1, 1)
            progress[key] = EpisodeProgress(position: d, duration: d)
            // Marking a later episode watched moves the show's place forward.
            let root = rootID(show)
            if let i = history.firstIndex(where: { $0.show.id == root }),
               (season.number, episode.number) >= (history[i].season, history[i].episode) {
                history[i].seasonID = season.id
                history[i].season = season.number
                history[i].episode = episode.number
            }
        } else {
            progress[key] = nil
        }
        save()
    }

    /// The episode the show's Play button starts: the one in progress, the one after the last finished, or the first.
    func upNext(_ d: ShowDetails) -> ShowUpNext? {
        let resume = defaults.bool(forKey: SettingsKey.resumePlayback)
        func make(_ s: ShowSeason, _ e: ShowEpisode, continuing: Bool) -> ShowUpNext {
            let p = progress[Self.key(d.show.id, s.id, e.number)]
            let resumeAt = resume ? p.flatMap { $0.position > 20 && !$0.isWatched ? $0.position : nil } : nil
            return ShowUpNext(season: s, episode: e, resumeAt: resumeAt,
                              remaining: resumeAt.flatMap { at in p.map { $0.duration - at } }, isContinuing: continuing)
        }
        if let h = history.first(where: { $0.show.id == d.show.id }),
           let s = d.season(id: h.seasonID), let e = s.episodes.first(where: { $0.number == h.episode }) {
            if progress[Self.key(d.show.id, s.id, e.number)]?.isWatched == true {
                if let next = d.episode(after: s, e) { return make(next.0, next.1, continuing: true) }
            } else {
                return make(s, e, continuing: true)
            }
        }
        guard let s = d.seasons.first(where: { $0.episodes.contains(where: \.isAired) }),
              let e = s.episodes.first(where: \.isAired) else { return nil }
        return make(s, e, continuing: false)
    }

    /// Shows started and not finished, with what plays next, most recent first.
    var continueWatching: [(entry: WatchEntry, next: ShowUpNext?)] {
        history.compactMap { h -> (entry: WatchEntry, next: ShowUpNext?)? in
            guard let d = details[h.show.id] else { return (entry: h, next: nil) }
            guard let next = upNext(d), next.isContinuing else { return nil }
            return (entry: h, next: next)
        }
    }

    func removeFromContinueWatching(_ show: Show) {
        history.removeAll { $0.show.id == rootID(show) }
        save()
    }

    // MARK: playback

    func playbackStarted(_ request: PlaybackRequest) {
        // Every request for data now goes to what's on screen.
        prewarmer.releaseAll()
        guard let ctx = request.show else { return }
        history.removeAll { $0.show.id == ctx.show.id }
        history.insert(WatchEntry(show: ctx.show, seasonID: ctx.seasonID, season: ctx.season, episode: ctx.episode,
                                  watchedAt: Date()), at: 0)
        savedSources[ctx.key] = ctx.source
        if let g = ctx.source.group { groups[String(ctx.show.id)] = g }
        prepared[ctx.key] = nil
        save()
    }

    func playbackEnded(_ request: PlaybackRequest, position: Double, duration: Double) {
        guard let ctx = request.show, position > 0 else { return }
        let old = progress[ctx.key]
        progress[ctx.key] = EpisodeProgress(position: position, duration: duration > 0 ? duration : (old?.duration ?? 0))
        if let i = history.firstIndex(where: { $0.show.id == ctx.show.id }) { history[i].watchedAt = Date() }
        save()
    }

    // MARK: getting ready ahead of time

    /// Gets the episode the Play button would start ready while its page is open: finds the release, joins the
    /// swarm and loads the container's head and index and the opening seconds (or the resume point), so pressing
    /// Play starts at once. The episode after it is readied too when its release is already known.
    func warm(_ d: ShowDetails) {
        guard let next = upNext(d) else { return }
        var targets = [warmTarget(d, next.season, next.episode, reason: .primary, searching: true)]
        if let after = d.episode(after: next.season, next.episode) {
            targets.append(warmTarget(d, after.0, after.1, reason: .prominent, searching: false))
        }
        prewarmer.warm(targets.compactMap { $0 }, scope: Self.warmScope(d))
    }

    /// Readies the front of Continue Watching: the first show's next episode, then the next two shows' when their
    /// releases are already known (played before or picked ahead).
    func warmHome() {
        let targets = continueWatching.prefix(3).enumerated().compactMap { i, c -> Prewarmer.Target? in
            guard let next = c.next, let d = details[c.entry.show.id] else { return nil }
            return warmTarget(d, next.season, next.episode, reason: i == 0 ? .primary : .likely, searching: i == 0)
        }
        prewarmer.warm(targets, scope: Self.homeScope)
    }

    /// A finger came down on an episode's row on its show page.
    func warmTouched(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) {
        guard let t = warmTarget(d, s, e, reason: .touch, searching: true) else { return }
        prewarmer.warm([t], scope: Self.warmScope(d), lane: "touch")
    }

    /// A finger came down on a Continue Watching card.
    func warmTouched(_ entry: WatchEntry, next: ShowUpNext?) {
        guard let next, let d = details[entry.show.id],
              let t = warmTarget(d, next.season, next.episode, reason: .touch, searching: true) else { return }
        prewarmer.warm([t], scope: Self.homeScope, lane: "touch")
    }

    /// The show page closed: what it readied goes quiet after a short grace.
    func stopWarming(_ d: ShowDetails) { prewarmer.release(scope: Self.warmScope(d)) }

    func stopWarmingHome() { prewarmer.release(scope: Self.homeScope) }

    /// An episode is being opened from the launcher; warm-ups being released wait for it.
    func launchBegan() { prewarmer.beginLaunch() }

    func launchEnded() { prewarmer.endLaunch() }

    private static let homeScope = "home"
    private static func warmScope(_ d: ShowDetails) -> String { "show.\(d.show.id)" }

    private func warmTarget(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, reason: Prewarmer.Reason,
                            searching: Bool) -> Prewarmer.Target? {
        guard e.isAired else { return nil }
        let key = Self.key(d.show.id, s.id, e.number)
        let resume = defaults.bool(forKey: SettingsKey.resumePlayback)
            ? progress[key].flatMap { $0.position > 20 && !$0.isWatched ? $0 : nil } : nil
        return Prewarmer.Target(key: key, label: "\(d.show.title) \(Self.episodeLabel(d, s, e))",
                                resumeAt: resume?.position,
                                resumeFraction: resume.flatMap { $0.duration > 0 ? $0.position / $0.duration : nil },
                                reason: reason) { [weak self] in
            await self?.warmResolve(d, s, e, key: key, searching: searching)
        }
    }

    /// Finds the release for a warm-up, sharing the search with a Play pressed meanwhile.
    private func warmResolve(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, key: String,
                             searching: Bool) async -> ResolvedEpisode? {
        if let job = resolving[key] { return await job.value }
        let job = Task { [weak self] () -> ResolvedEpisode? in
            guard let self else { return nil }
            return try? await self.resolve(d, s, e, source: nil, searching: searching, status: { _ in })
        }
        resolving[key] = job
        let r = await job.value
        if resolving[key] == job { resolving[key] = nil }
        if let r { prepared[key] = r }
        return r
    }

    /// Loads the start of the next episode once the current one's bitrate is known.
    func prefetchNext(after request: PlaybackRequest, duration: Double) {
        guard let ctx = request.show, let d = details[ctx.show.id], let s = d.season(id: ctx.seasonID),
              let e = s.episodes.first(where: { $0.number == ctx.episode }),
              let next = d.episode(after: s, e) else { return }
        let (ns, ne) = next
        let key = Self.key(d.show.id, ns.id, ne.number)
        let bytes = AppModel.prefetchBytes(fileLength: request.file.length, seconds: duration)
        prefetchTask?.cancel()
        prefetchTask = Task {
            if prepared[key] == nil, let r = try? await resolve(d, ns, ne, source: nil, status: { _ in }) {
                prepared[key] = r
            }
            guard !Task.isCancelled, let r = prepared[key] else { return }
            r.torrent.prefetch(fileIndex: r.file.index, bytes: bytes)
        }
    }

    /// The next episode for the player's Up Next card.
    func upNextItem(after request: PlaybackRequest) -> UpNextItem? {
        guard let ctx = request.show, let d = details[ctx.show.id], let s = d.season(id: ctx.seasonID),
              let e = s.episodes.first(where: { $0.number == ctx.episode }),
              let next = d.episode(after: s, e) else { return nil }
        let (ns, ne) = next
        return UpNextItem(title: Self.episodeLabel(d, ns, ne), subtitle: ne.title, imageURL: ne.thumbnailURL) { [weak self] in
            guard let self else { return nil }
            return try? await self.request(d, ns, ne, source: nil, resumeAt: nil, status: { _ in })
        }
    }

    /// The next episode's file once `prefetchNext` has found it, to compare the playing episode's audio with; its
    /// number is given when it's in the same season.
    func preparedNext(after request: PlaybackRequest) -> SkipReference? {
        guard let ctx = request.show, let d = details[ctx.show.id], let s = d.season(id: ctx.seasonID),
              let e = s.episodes.first(where: { $0.number == ctx.episode }),
              let next = d.episode(after: s, e) else { return nil }
        let (ns, ne) = next
        guard let r = prepared[Self.key(d.show.id, ns.id, ne.number)] else { return nil }
        return SkipReference(torrent: r.torrent, file: r.file, episode: ns.id == s.id ? ne.number : nil)
    }

    // MARK: finding releases

    var preferences: SourcePreferences {
        let res = defaults.integer(forKey: SettingsKey.preferredResolution)
        return SourcePreferences(resolution: res > 0 ? res : 1080, preferDub: defaults.bool(forKey: SettingsKey.preferDub))
    }

    /// Versions are ranked by preference when found, so forget the ranked lists.
    func preferencesChanged() {
        sourceCache.removeAll()
        prepared.removeAll()
        planned.removeAll()
        save()
    }

    /// Releases that play an episode, best first. Kept for ten minutes. The likeliest picks' .torrent files start
    /// downloading as soon as the first search answers, so opening one doesn't wait for a download.
    func sources(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, refresh: Bool = false) async throws -> [EpisodeSource] {
        let key = Self.key(d.show.id, s.id, e.number)
        if !refresh, let c = sourceCache[key], Date().timeIntervalSince(c.at) < 600 { return c.list }
        var prefs = preferences
        prefs.group = groups[String(d.show.id)]
        let store = app.torrentFiles
        let list = try await SourceFinder(nyaa: app.nyaa).sources(for: d, season: s, episode: e, prefs: prefs) { partial in
            store.prefetch(partial.prefix(2).compactMap(\.result.torrentURL))
        }
        store.prefetch(list.prefix(2).compactMap(\.result.torrentURL))
        sourceCache[key] = (Date(), list)
        return list
    }

    /// The releases to try for Play: returns as soon as the best one is clear (`SourceFinder.quickSources`), without
    /// waiting for the slower searches; the full list is kept for the versions sheet when they finish.
    private func quickSources(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) async throws -> [EpisodeSource] {
        let key = Self.key(d.show.id, s.id, e.number)
        if let c = sourceCache[key], Date().timeIntervalSince(c.at) < 600 { return c.list }
        var prefs = preferences
        prefs.group = groups[String(d.show.id)]
        let store = app.torrentFiles
        let started = Date()
        let list = try await SourceFinder(nyaa: app.nyaa).quickSources(for: d, season: s, episode: e, prefs: prefs, provisional: { partial in
            store.prefetch(partial.prefix(2).compactMap(\.result.torrentURL))
        }, completed: { [weak self] full in
            Task { @MainActor in self?.sourceCache[key] = (Date(), full) }
        })
        PlaybackTrace.shared.timing("search settled on \(list.first?.result.title ?? "nothing")", since: started)
        store.prefetch(list.prefix(2).compactMap(\.result.torrentURL))
        return list
    }

    /// Release and file used for an episode last time, if it was saved.
    func savedSource(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) -> SavedSource? {
        savedSources[Self.key(d.show.id, s.id, e.number)]
    }

    /// Finds a file that plays the episode: the one prepared ahead, the one played before, the next file of the
    /// season pack being watched, else the best release found (unless `searching` is false).
    func resolve(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, source: EpisodeSource?, searching: Bool = true,
                 status: @escaping (String) -> Void) async throws -> ResolvedEpisode {
        guard e.isAired else { throw ShowError.notAired }
        let key = Self.key(d.show.id, s.id, e.number)
        let isMovie = d.show.isMovie || s.media.isMovie
        if source == nil {
            if let rel = downloads?.release(forKey: key) {
                PlaybackTrace.shared.mark("resolve: playing the download")
                if let r = await open(SavedSource(infoHash: rel.infoHash, fileIndex: rel.fileIndex, magnet: rel.magnet,
                                                  torrentURL: rel.torrentURL, group: rel.group, isBatch: rel.isBatch)) {
                    return r
                }
                PlaybackTrace.shared.mark("resolve: the download didn't open")
            }
            if let r = prepared[key], app.client.torrent(infoHashHex: r.torrent.infoHashHex) != nil {
                if r.torrent.isPaused { r.torrent.resume() }
                PlaybackTrace.shared.mark("resolve: ready ahead of time (\(r.torrent.infoHashHex.prefix(8)))")
                return r
            }
            if let saved = savedSources[key] {
                PlaybackTrace.shared.mark("resolve: reopening the release played before")
                if let r = await open(saved) {
                    PlaybackTrace.shared.mark("resolve: reopened")
                    return r
                }
                PlaybackTrace.shared.mark("resolve: release played before didn't open")
            }
            // Packs hold the next episodes too.
            if let r = packEpisode(d, s, e, isMovie: isMovie) {
                PlaybackTrace.shared.mark("resolve: next file of a pack already added")
                if r.torrent.isPaused { r.torrent.resume() }
                return r
            }
            if let p = planned[key], Date().timeIntervalSince(p.at) < Self.planLifetime {
                PlaybackTrace.shared.mark("resolve: opening the release picked ahead of time")
                planned[key] = nil
                if let r = await open(p.source) {
                    PlaybackTrace.shared.mark("resolve: opened")
                    return r
                }
                PlaybackTrace.shared.mark("resolve: release picked ahead of time didn't open")
            }
        }

        guard searching || source != nil else { throw ShowError.noSources }
        status("Finding the best version")
        PlaybackTrace.shared.mark("resolve: searching Nyaa")
        let candidates: [EpisodeSource]
        if let source {
            candidates = [source]
        } else {
            candidates = Array(try await quickSources(d, s, e).prefix(4))
        }
        PlaybackTrace.shared.mark("resolve: \(candidates.count) candidates; first: \(candidates.first?.result.title ?? "none")")
        guard !candidates.isEmpty else { throw ShowError.noSources }
        status("Starting")
        for c in candidates {
            guard let t = await app.addSource(torrentURL: c.result.torrentURL, magnet: c.result.magnet,
                                              infoHash: c.result.infoHash) else {
                PlaybackTrace.shared.mark("resolve: couldn't add \(c.result.title)")
                continue
            }
            guard let info = await Self.info(t, timeout: 25),
                  let f = Self.pickFile(info, s, e, isMovie: isMovie) else {
                PlaybackTrace.shared.mark("resolve: no metadata or no matching file in \(c.result.title)")
                app.discardSource(t)
                continue
            }
            PlaybackTrace.shared.mark("resolve: playing \(f.displayPath) (\(f.length / 1_000_000) MB, pieces \(info.pieceLength / 1024) KB)")
            let saved = SavedSource(infoHash: t.infoHashHex, fileIndex: f.index, magnet: c.result.magnet ?? t.magnetLink,
                                    torrentURL: c.result.torrentURL, group: c.group, isBatch: c.isBatch)
            if source == nil, savedSources[key] == nil {
                // Found by searching: kept so a later launch opens it without searching again.
                planned[key] = PlannedSource(source: saved, at: Date())
                save()
            }
            return ResolvedEpisode(torrent: t, file: f, source: saved)
        }
        throw ShowError.unplayable
    }

    /// A ready-to-play request for an episode, resuming where the viewer stopped unless told otherwise.
    func request(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, source: EpisodeSource?, resumeAt: Double?,
                 status: @escaping (String) -> Void) async throws -> PlaybackRequest {
        let key = Self.key(d.show.id, s.id, e.number)
        if source == nil, let job = resolving[key] {
            PlaybackTrace.shared.mark("resolve: joining the warm-up already finding it")
            _ = await job.value
        }
        let r = try await resolve(d, s, e, source: source, status: status)
        prewarmer.launching(r.torrent)
        let p = progress[key]
        let saved = defaults.bool(forKey: SettingsKey.resumePlayback)
            ? p.flatMap { $0.position > 20 && !$0.isWatched ? $0.position : nil } : nil
        let isMovie = d.show.isMovie || s.media.isMovie
        let ctx = ShowPlayback(show: d.show, seasonID: s.id, season: s.number, episode: e.number, episodeTitle: e.title,
                               thumbnailURL: e.thumbnailURL, isMovie: isMovie, source: r.source)
        let label = isMovie ? nil : [Self.episodeLabel(d, s, e), e.title].compactMap { $0 }.joined(separator: ": ")
        return app.playbackRequest(torrent: r.torrent, file: r.file)
            .with(title: isMovie ? s.media.title : d.show.title, episode: label, resumeAt: resumeAt ?? saved, show: ctx)
    }

    /// The episode's file in a season pack played before, if one holds it.
    private func packEpisode(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, isMovie: Bool) -> ResolvedEpisode? {
        var tried = Set<String>()
        for other in savedSources.filter({ $0.key.hasPrefix("\(d.show.id).") && $0.value.isBatch }).map(\.value)
        where tried.insert(other.infoHash).inserted {
            // Read the file list without starting a source that doesn't hold the episode.
            guard let info = app.sourceInfo(other.infoHash), let f = Self.pickFile(info, s, e, isMovie: isMovie),
                  let t = app.sourceTorrent(other.infoHash) else { continue }
            return ResolvedEpisode(torrent: t, file: f, source: SavedSource(infoHash: other.infoHash, fileIndex: f.index,
                                                                              magnet: other.magnet, torrentURL: other.torrentURL,
                                                                              group: other.group, isBatch: true))
        }
        return nil
    }

    // MARK: picking ahead of time

    /// Picks the release for what plays next in the first Continue Watching shows: searches Nyaa, downloads the
    /// best release's .torrent and finds the episode's file, so Play skips straight to joining the swarm. Shows are
    /// done one after another, in the background.
    func planContinueWatching(limit: Int = 4) {
        let targets = continueWatching.prefix(limit).compactMap { c -> (ShowDetails, ShowSeason, ShowEpisode)? in
            guard let next = c.next, next.episode.isAired, let d = details[c.entry.show.id] else { return nil }
            return (d, next.season, next.episode)
        }
        planTask?.cancel()
        planTask = Task {
            for (d, s, e) in targets {
                guard !Task.isCancelled else { return }
                await plan(d, s, e)
            }
            // Releases just picked can be readied now, if Home is still showing.
            if !Task.isCancelled, prewarmer.holds(lane: Self.homeScope) { warmHome() }
        }
    }

    private func plan(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) async {
        let key = Self.key(d.show.id, s.id, e.number)
        let isMovie = d.show.isMovie || s.media.isMovie
        if savedSources[key] != nil || prepared[key] != nil { return }
        if let p = planned[key], Date().timeIntervalSince(p.at) < Self.planLifetime { return }
        if packEpisode(d, s, e, isMovie: isMovie) != nil { return }
        let started = Date()
        guard let list = try? await sources(d, s, e) else { return }
        for c in list.prefix(2) {
            guard let url = c.result.torrentURL, let data = try? await app.torrentFiles.data(for: url),
                  let descriptor = try? TorrentDescriptor.parse(torrentData: data), let info = descriptor.info,
                  let f = Self.pickFile(info, s, e, isMovie: isMovie) else { continue }
            planned[key] = PlannedSource(source: SavedSource(infoHash: descriptor.infoHashHex, fileIndex: f.index,
                                                             magnet: c.result.magnet ?? descriptor.magnetURI, torrentURL: url,
                                                             group: c.group, isBatch: c.isBatch), at: Date())
            save()
            PlaybackTrace.shared.timing("picked ahead: \(d.show.title) \(Self.episodeLabel(d, s, e)) → \(c.result.title)", since: started)
            return
        }
    }

    /// Adds back a release played before.
    private func open(_ saved: SavedSource) async -> ResolvedEpisode? {
        guard let t = await app.addSource(torrentURL: saved.torrentURL, magnet: saved.magnet, infoHash: saved.infoHash),
              let info = await Self.info(t, timeout: 20),
              let f = info.files.first(where: { $0.index == saved.fileIndex }) else { return nil }
        return ResolvedEpisode(torrent: t, file: f, source: saved)
    }

    private static func info(_ t: Torrent, timeout: TimeInterval) async -> TorrentInfo? {
        if let info = t.torrentInfo { return info }
        return await Task.detached { t.waitForInfo(timeout: timeout) }.value
    }

    static func pickFile(_ info: TorrentInfo, _ s: ShowSeason, _ e: ShowEpisode, isMovie: Bool) -> TorrentFile? {
        let files = info.files.filter { !$0.isPadding }
        let list = files.map { EpisodeFilePicker.File(index: $0.index, path: $0.displayPath, length: $0.length) }
        guard let index = EpisodeFilePicker.pick(list, season: s.number, episode: e.number, absolute: e.absolute,
                                                 seasonEpisodes: s.media.episodes ?? s.episodes.count, isMovie: isMovie)
        else { return nil }
        return files.first { $0.index == index }
    }

    // MARK: titles added by link

    private enum Adoption { case adopted, noMatch, retry }

    /// Titles added by link before 4.0 move into their show in the catalog: each becomes the saved version of
    /// the episodes it holds, with their progress, and the show takes its place in My List and Continue
    /// Watching. Runs once per title; titles added by link later stay as they are.
    func adoptLinkedTitles() async {
        var pending: [String]
        if let saved = defaults.stringArray(forKey: SettingsKey.linkAdoption) {
            pending = saved
        } else {
            pending = app.items.map(\.id)
            defaults.set(pending, forKey: SettingsKey.linkAdoption)
        }
        for hash in pending {
            let result: Adoption
            if let item = app.item(hash) {
                result = await adopt(item)
            } else {
                result = .noMatch
            }
            if result != .retry {
                pending.removeAll { $0 == hash }
                defaults.set(pending, forKey: SettingsKey.linkAdoption)
            }
        }
    }

    private func adopt(_ item: LibraryItem) async -> Adoption {
        if case .failed = item.status.phase { return .noMatch }
        guard let info = item.torrent.torrentInfo else { return .retry }
        let name = item.status.name
        let query = ShowNames.seasonless(app.release(name).title)
        guard !query.isEmpty else { return .noMatch }
        let found: [Show]
        do { found = try await search(query) } catch { return .retry }

        for show in found.prefix(3) {
            guard let d = try? await loadDetails(show) else { continue }
            var matches: [(season: ShowSeason, episode: ShowEpisode, file: TorrentFile)] = []
            for s in d.seasons {
                let isMovie = d.show.isMovie || s.media.isMovie
                for e in s.episodes where SourceMatcher.match(name, details: d, season: s, episode: e) != nil {
                    if let f = Self.pickFile(info, s, e, isMovie: isMovie),
                       !matches.contains(where: { $0.file.index == f.index }) {
                        matches.append((s, e, f))
                    }
                }
            }
            guard !matches.isEmpty else { continue }

            let hash = item.id
            let group = app.release(name).group
            for m in matches {
                let key = Self.key(d.show.id, m.season.id, m.episode.number)
                if savedSources[key] == nil {
                    savedSources[key] = SavedSource(infoHash: hash, fileIndex: m.file.index, magnet: item.torrent.magnetLink,
                                                    torrentURL: nil, group: group, isBatch: matches.count > 1)
                }
                if progress[key] == nil, let p = app.storedProgress(torrent: item.torrent, file: m.file) {
                    progress[key] = EpisodeProgress(position: p.position, duration: p.duration)
                }
            }
            if let group, groups[String(d.show.id)] == nil { groups[String(d.show.id)] = group }

            // Where the viewer was in this title becomes where they are in the show.
            if let at = app.watchedAt(hash) {
                let last = app.lastPlayedIndex(hash)
                let m = matches.first { $0.file.index == last } ?? matches[0]
                let existing = history.first { $0.show.id == d.show.id }
                if existing.map({ $0.watchedAt < at }) ?? true {
                    history.removeAll { $0.show.id == d.show.id }
                    history.append(WatchEntry(show: d.show, seasonID: m.season.id, season: m.season.number,
                                              episode: m.episode.number, watchedAt: at))
                    history.sort { $0.watchedAt > $1.watchedAt }
                }
            }
            if !isInMyList(d.show) { myList.append(d.show) }
            save()
            app.makeSource(hash)
            return .adopted
        }
        return .noMatch
    }

    // MARK: labels

    /// "Episode 5" for single-season shows, "S2 E5" otherwise.
    static func episodeLabel(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) -> String {
        d.seasons.count > 1 ? "S\(s.number) E\(e.number)" : "Episode \(e.number)"
    }

    static func shortLabel(_ d: ShowDetails?, season: Int, episode: Int) -> String {
        (d?.seasons.count ?? 1) > 1 ? "S\(season) E\(episode)" : "Episode \(episode)"
    }

    // MARK: persistence

    private var stateURL: URL { baseURL.appendingPathComponent("shows.json") }
    private var rowsURL: URL { baseURL.appendingPathComponent("browse.json") }
    private var detailsDirectory: URL { baseURL.appendingPathComponent("details", isDirectory: true) }
    private func detailsURL(_ id: Int) -> URL { detailsDirectory.appendingPathComponent("\(id).json") }

    private func save() {
        var s = Saved()
        s.myList = myList
        s.history = Array(history.prefix(60))
        s.progress = progress
        s.sources = savedSources
        s.groups = groups
        s.roots = Dictionary(uniqueKeysWithValues: roots.map { (String($0.key), $0.value) })
        s.addedAt = Dictionary(uniqueKeysWithValues: addedAt.map { (String($0.key), $0.value) })
        s.planned = planned.filter { Date().timeIntervalSince($0.value.at) < Self.planLifetime }
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func restore() {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            myList = s.myList
            history = s.history
            progress = s.progress
            savedSources = s.sources
            groups = s.groups
            roots = Dictionary(uniqueKeysWithValues: s.roots.compactMap { k, v in Int(k).map { ($0, v) } })
            addedAt = Dictionary(uniqueKeysWithValues: (s.addedAt ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
            planned = (s.planned ?? [:]).filter { Date().timeIntervalSince($0.value.at) < Self.planLifetime }
        }
        if let data = try? Data(contentsOf: rowsURL), let r = try? JSONDecoder().decode(SavedRows.self, from: data) {
            rows = r.rows
            rowsFetchedAt = r.fetchedAt
        }
        // Continue Watching needs each show's episodes to know what's next.
        for h in history.prefix(20) { _ = cachedDetails(h.show) }
    }
}
