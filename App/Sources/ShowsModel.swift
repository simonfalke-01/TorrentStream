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

/// Something to start: an episode, the show's next episode, or a movie.
struct EpisodeLaunch: Identifiable {
    let id = UUID()
    let show: Show
    /// Season and episode; nil plays what's next for the viewer.
    var seasonID: Int? = nil
    var episode: Int? = nil
    /// A version the viewer chose.
    var source: EpisodeSource? = nil
    var openInVLC = false
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

    private unowned let app: AppModel
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
    private var detailsTasks: [Int: Task<ShowDetails, Error>] = [:]
    private var prefetchTask: Task<Void, Never>?

    private struct Saved: Codable {
        var myList: [Show] = []
        var history: [WatchEntry] = []
        var progress: [String: EpisodeProgress] = [:]
        var sources: [String: SavedSource] = [:]
        var groups: [String: String] = [:]
        var roots: [String: Int] = [:]
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

    /// Seasons and episodes, from memory or disk when fresh enough, else from the catalog. A stale copy is
    /// returned when the catalog can't be reached.
    @discardableResult
    func loadDetails(_ show: Show, force: Bool = false) async throws -> ShowDetails {
        let root = rootID(show)
        if !force, let d = cachedDetails(show), isFresh(d) { return d }
        if let running = detailsTasks[root] { return try await running.value }
        let task = Task { try await catalog.details(id: show.id) }
        detailsTasks[root] = task
        defer { detailsTasks[root] = nil }
        do {
            let d = try await task.value
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

    private func store(_ d: ShowDetails) {
        details[d.show.id] = d
        for s in d.seasons { roots[s.media.id] = d.show.id }
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: detailsURL(d.show.id), options: .atomic) }
        save()
    }

    /// Adds episode names and stills the main catalog lacks.
    private func enrich(_ d: ShowDetails) async {
        let full = await catalog.withEpisodeInfo(d)
        guard full != d else { return }
        store(full)
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
        } else {
            myList.insert(details[root]?.show ?? show, at: 0)
        }
        save()
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
        return UpNextItem(title: Self.episodeLabel(d, ns, ne), subtitle: ne.title) { [weak self] in
            guard let self else { return nil }
            return try? await self.request(d, ns, ne, source: nil, resumeAt: nil, status: { _ in })
        }
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
    }

    /// Releases that play an episode, best first. Kept for ten minutes.
    func sources(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, refresh: Bool = false) async throws -> [EpisodeSource] {
        let key = Self.key(d.show.id, s.id, e.number)
        if !refresh, let c = sourceCache[key], Date().timeIntervalSince(c.at) < 600 { return c.list }
        var prefs = preferences
        prefs.group = groups[String(d.show.id)]
        let list = try await SourceFinder(nyaa: app.nyaa).sources(for: d, season: s, episode: e, prefs: prefs)
        sourceCache[key] = (Date(), list)
        return list
    }

    /// Release and file used for an episode last time, if it was saved.
    func savedSource(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) -> SavedSource? {
        savedSources[Self.key(d.show.id, s.id, e.number)]
    }

    /// Finds a file that plays the episode: the one prepared ahead, the one played before, the next file of the
    /// season pack being watched, else the best release found.
    func resolve(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, source: EpisodeSource?,
                 status: @escaping (String) -> Void) async throws -> ResolvedEpisode {
        guard e.isAired else { throw ShowError.notAired }
        let key = Self.key(d.show.id, s.id, e.number)
        let isMovie = d.show.isMovie || s.media.isMovie
        if source == nil {
            if let r = prepared[key], app.client.torrent(infoHashHex: r.torrent.infoHashHex) != nil {
                if r.torrent.isPaused { r.torrent.resume() }
                return r
            }
            if let saved = savedSources[key], let r = await open(saved) { return r }
            // Packs hold the next episodes too.
            for other in savedSources.filter({ $0.key.hasPrefix("\(d.show.id).") && $0.value.isBatch }).map(\.value) {
                guard let t = app.client.torrent(infoHashHex: other.infoHash), let info = t.torrentInfo,
                      let f = Self.pickFile(info, s, e, isMovie: isMovie) else { continue }
                if t.isPaused { t.resume() }
                return ResolvedEpisode(torrent: t, file: f, source: SavedSource(infoHash: other.infoHash, fileIndex: f.index,
                                                                                  magnet: other.magnet, torrentURL: other.torrentURL,
                                                                                  group: other.group, isBatch: true))
            }
        }

        status("Finding the best version")
        let candidates: [EpisodeSource]
        if let source {
            candidates = [source]
        } else {
            candidates = Array(try await sources(d, s, e).prefix(4))
        }
        guard !candidates.isEmpty else { throw ShowError.noSources }
        status("Starting")
        for c in candidates {
            guard let t = await app.addSource(torrentURL: c.result.torrentURL, magnet: c.result.magnet,
                                              infoHash: c.result.infoHash) else { continue }
            guard let info = await Self.info(t, timeout: 25),
                  let f = Self.pickFile(info, s, e, isMovie: isMovie) else {
                app.discardSource(t)
                continue
            }
            let saved = SavedSource(infoHash: t.infoHashHex, fileIndex: f.index, magnet: c.result.magnet ?? t.magnetLink,
                                    torrentURL: c.result.torrentURL, group: c.group, isBatch: c.isBatch)
            return ResolvedEpisode(torrent: t, file: f, source: saved)
        }
        throw ShowError.unplayable
    }

    /// A ready-to-play request for an episode, resuming where the viewer stopped unless told otherwise.
    func request(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode, source: EpisodeSource?, resumeAt: Double?,
                 status: @escaping (String) -> Void) async throws -> PlaybackRequest {
        let r = try await resolve(d, s, e, source: source, status: status)
        let key = Self.key(d.show.id, s.id, e.number)
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
        }
        if let data = try? Data(contentsOf: rowsURL), let r = try? JSONDecoder().decode(SavedRows.self, from: data) {
            rows = r.rows
            rowsFetchedAt = r.fetchedAt
        }
        // Continue Watching needs each show's episodes to know what's next.
        for h in history.prefix(20) { _ = cachedDetails(h.show) }
    }
}
