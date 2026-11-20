import Foundation
import SwiftUI
import TorrentKit
import NyaaKit
import CatalogKit

struct LibraryItem: Identifiable {
    let torrent: Torrent
    let status: TorrentStatus
    let addedAt: Date
    var id: String { torrent.infoHashHex }
}

/// A subtitle file shipped inside the torrent, exposed as a stream URL.
struct SubtitleRef: Hashable {
    let name: String
    let url: URL
}

/// What the player needs to stream one file.
struct PlaybackRequest: Identifiable {
    let torrent: Torrent
    let file: TorrentFile
    let url: URL
    /// Subtitle files shipped inside the torrent, best match first.
    let subtitles: [SubtitleRef]
    /// Seconds to resume from (nil = start).
    let resumeAt: Double?
    /// Show or movie title for the player's top bar.
    let title: String
    /// "Episode 5", or nil for a movie.
    let episode: String?
    var id: String { "\(torrent.infoHashHex)/\(file.index)" }
}

enum PlayerEngine: String, CaseIterable, Identifiable {
    case vlc, apple
    var id: String { rawValue }
    var title: String { self == .vlc ? "VLC" : "Apple" }
    var detail: String {
        self == .vlc ? "Plays almost any format, with audio and subtitle tracks" : "AirPlay and Picture in Picture, for MP4 and MOV"
    }
}

enum AppTab: Hashable { case home, search }

/// Navigation destinations shared by the Home and Search stacks.
enum Route: Hashable {
    /// A title in My List, by info hash.
    case title(String)
    /// A search result that is added to My List when opened.
    case nyaa(NyaaResult)
    /// Every title in My List as a grid.
    case myList

    var hash: String {
        switch self {
        case .title(let h): return h
        case .nyaa(let r): return r.infoHash ?? ""
        case .myList: return ""
        }
    }
}

/// A season or folder of episodes on a title page.
struct EpisodeGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let files: [TorrentFile]
}

enum SettingsKey {
    static let playerEngine = "playerEngine"
    static let resumePlayback = "resumePlayback"
    static let autoPlayNext = "autoPlayNext"
    static let useDHT = "useDHT"
    static let publicTrackers = "usePublicTrackers"
    static let nyaaAddress = "nyaaAddress"
    static let searchSort = "searchSort"
    static let searchAscending = "searchAscending"
    static let searchCategory = "searchCategory"
    static let searchFilter = "searchFilter"
    static let recentSearches = "recentSearches"
    static let showArtwork = "showArtwork"
}

/// What the header's Play button starts.
struct UpNext {
    let file: TorrentFile
    let resumeAt: Double?
    /// Seconds left when resuming.
    let remaining: Double?
}

struct ContinueEntry: Identifiable {
    let item: LibraryItem
    let next: UpNext
    var id: String { item.id }
}

@MainActor
final class AppModel: ObservableObject {
    let client: TorrentClient
    @Published private(set) var items: [LibraryItem] = []
    @Published var errorMessage: String?
    @Published var toast: Toast?
    @Published var navigationPath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var selectedTab: AppTab = .home
    @Published private(set) var storageUsed: Int64 = 0
    /// Posters and synopses by `CatalogQuery.key`.
    @Published private(set) var catalog: [String: CatalogEntry] = [:]

    private let baseURL: URL
    private var timer: Timer?
    private var addedAt: [String: Date] = [:]
    private var toastTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let catalogClient = CatalogClient()
    /// Looked up this session without a match (or the lookup failed); retried next launch.
    private var catalogMisses: Set<String> = []
    private var catalogPending: Set<String> = []
    private var releaseCache: [String: ReleaseInfo] = [:]

    private struct SavedEntry: Codable {
        let infoHash: String
        var magnet: String?
        var hasTorrentFile: Bool
        var wantedFiles: [Int]?
        var paused: Bool?
        var addedAt: Date?
    }

    var playerEngine: PlayerEngine {
        guard VLCAvailability.isAvailable else { return .apple }
        return PlayerEngine(rawValue: defaults.string(forKey: SettingsKey.playerEngine) ?? "") ?? .vlc
    }

    init() {
        defaults.register(defaults: [
            SettingsKey.resumePlayback: true,
            SettingsKey.autoPlayNext: true,
            SettingsKey.useDHT: true,
            SettingsKey.publicTrackers: true,
            SettingsKey.showArtwork: true,
        ])
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL.appendingPathComponent("torrents"), withIntermediateDirectories: true)
        client = TorrentClient(
            downloadDirectory: baseURL.appendingPathComponent("Downloads", isDirectory: true),
            useDHT: defaults.bool(forKey: SettingsKey.useDHT),
            extraTrackers: defaults.bool(forKey: SettingsKey.publicTrackers) ? TorrentClient.defaultTrackers : []
        )
        restoreCatalog()
        restoreLibrary()
        refresh()
        refreshStorage()
        trimCache()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        items = client.torrents
            .map { LibraryItem(torrent: $0, status: $0.status(), addedAt: addedAt[$0.infoHashHex] ?? .distantPast) }
            .sorted { $0.addedAt > $1.addedAt }
        requestCatalog(items.compactMap { catalogQuery(for: $0) })
    }

    func item(_ hash: String) -> LibraryItem? { items.first { $0.id == hash } }

    func showToast(_ message: String, systemImage: String = "checkmark.circle.fill") {
        toastTask?.cancel()
        withAnimation(Motion.enter) { toast = Toast(message: message, systemImage: systemImage) }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.exit) { self.toast = nil }
        }
    }

    // MARK: adding

    /// Adds and shows the torrent in the Library tab.
    @discardableResult
    func addMagnet(_ text: String) -> Bool {
        guard let hash = addTorrent(magnet: text) else { return false }
        reveal(hash)
        return true
    }

    /// Adds and shows the torrent in the Library tab.
    @discardableResult
    func addTorrentFile(_ data: Data) -> Bool {
        guard let hash = addTorrent(data: data) else { return false }
        reveal(hash)
        return true
    }

    /// Adds without navigating. Returns the info hash, or nil after reporting the error.
    func addTorrent(magnet: String, reportErrors: Bool = true) -> String? {
        do {
            let t = try client.add(magnet: magnet)
            didAdd(t)
            return t.infoHashHex
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func addTorrent(data: Data, reportErrors: Bool = true) -> String? {
        do {
            let t = try client.add(torrentData: data)
            try? data.write(to: torrentFileURL(t.infoHashHex))
            didAdd(t)
            return t.infoHashHex
        } catch {
            if reportErrors { errorMessage = error.localizedDescription }
            return nil
        }
    }

    @discardableResult
    func addTorrentFile(at url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return addTorrentFile(try Data(contentsOf: url))
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    private func didAdd(_ t: Torrent) {
        if addedAt[t.infoHashHex] == nil { addedAt[t.infoHashHex] = Date() }
        persist()
        refresh()
    }

    private func reveal(_ hash: String) {
        selectedTab = .home
        navigationPath = [.title(hash)]
    }

    // MARK: titles and artwork

    var showsArtwork: Bool { defaults.bool(forKey: SettingsKey.showArtwork) }

    /// Parsed release or file name, memoized because views ask on every refresh.
    func release(_ name: String) -> ReleaseInfo {
        if let r = releaseCache[name] { return r }
        let r = ReleaseName.parse(name)
        releaseCache[name] = r
        return r
    }

    /// True while a magnet link without a name is still fetching its metadata.
    private func isUnnamed(_ item: LibraryItem) -> Bool {
        item.status.name.caseInsensitiveCompare(item.id) == .orderedSame
    }

    func catalogQuery(name: String, prefersAnime: Bool? = nil) -> CatalogQuery? {
        let q = CatalogQuery(release: release(name), prefersAnime: prefersAnime)
        return q.isSearchable ? q : nil
    }

    private func catalogQuery(for item: LibraryItem) -> CatalogQuery? {
        isUnnamed(item) ? nil : catalogQuery(name: item.status.name)
    }

    func entry(name: String) -> CatalogEntry? {
        guard showsArtwork, let q = catalogQuery(name: name) else { return nil }
        return catalog[q.key]
    }

    func entry(for item: LibraryItem) -> CatalogEntry? {
        isUnnamed(item) ? nil : entry(name: item.status.name)
    }

    /// Show or movie name: the catalog's, else the one parsed from the release name.
    func displayTitle(name: String) -> String {
        if let e = entry(name: name) { return e.title }
        let r = release(name)
        return r.title.isEmpty ? MediaTitle.clean(name) : r.title
    }

    func displayTitle(_ item: LibraryItem) -> String {
        isUnnamed(item) ? "Loading Title" : displayTitle(name: item.status.name)
    }

    /// Catalog poster, else a poster image shipped with the title.
    func posterURL(_ item: LibraryItem) -> URL? {
        entry(for: item)?.posterURL ?? artworkURL(item)
    }

    /// Wide artwork for 16:9 cards and title headers.
    func backdropURL(_ item: LibraryItem) -> URL? {
        entry(for: item)?.backdropURL
    }

    /// "Episode 5", "S2 E5", or nil when the file name has no episode number.
    func episodeLabel(_ file: TorrentFile) -> String? {
        let r = release(file.fileName)
        guard let e = r.episode else { return nil }
        if let s = r.season, s > 1 { return "S\(s) E\(e)" }
        return "Episode \(e)"
    }

    /// Row title for an episode: its name when the file has one, else "Episode 5", else the cleaned file name.
    func episodeTitle(_ file: TorrentFile) -> String {
        let r = release(file.fileName)
        if let t = r.episodeTitle, !t.isEmpty { return t }
        if let e = r.episode { return "Episode \(e)" }
        return file.title
    }

    /// Fetches catalog entries for titles not looked up yet this session.
    func requestCatalog(_ queries: [CatalogQuery]) {
        guard showsArtwork else { return }
        var seen = Set<String>()
        let todo = queries.filter { q in
            q.isSearchable && catalog[q.key] == nil && !catalogMisses.contains(q.key)
                && !catalogPending.contains(q.key) && seen.insert(q.key).inserted
        }
        guard !todo.isEmpty else { return }
        catalogPending.formUnion(todo.map(\.key))
        Task { await lookUp(todo) }
    }

    /// Anime go to AniList in batches, everything else to Cinemeta; each falls back to the other source.
    private func lookUp(_ queries: [CatalogQuery]) async {
        let animeMisses = await lookUpAnime(queries.filter(\.prefersAnime), isLast: false)
        var liveActionMisses: [CatalogQuery] = []
        for q in queries.filter({ !$0.prefersAnime }) + animeMisses {
            if let hit = try? await catalogClient.lookupLiveAction(q) { store(hit, for: q.key) }
            else if !q.prefersAnime { liveActionMisses.append(q) }
            else { miss(q.key) }
        }
        _ = await lookUpAnime(liveActionMisses, isLast: true)
        saveCatalog()
    }

    /// Returns the queries AniList answered without a match, unless this is the last source tried.
    private func lookUpAnime(_ list: [CatalogQuery], isLast: Bool) async -> [CatalogQuery] {
        var notFound: [CatalogQuery] = []
        for start in stride(from: 0, to: list.count, by: 8) {
            let chunk = Array(list[start..<min(start + 8, list.count)])
            let found = (try? await catalogClient.lookupAnime(chunk)) ?? [:]
            for q in chunk {
                if let hit = found[q.key] ?? nil { store(hit, for: q.key) }
                else if !isLast && found[q.key] != nil { notFound.append(q) }
                else { miss(q.key) }
            }
        }
        return notFound
    }

    private func store(_ entry: CatalogEntry, for key: String) {
        catalogPending.remove(key)
        catalog[key] = entry
    }

    private func miss(_ key: String) {
        catalogPending.remove(key)
        catalogMisses.insert(key)
    }

    private var catalogURL: URL { baseURL.appendingPathComponent("catalog.json") }

    private func saveCatalog() {
        if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: catalogURL, options: .atomic) }
    }

    private func restoreCatalog() {
        guard let data = try? Data(contentsOf: catalogURL),
              let saved = try? JSONDecoder().decode([String: CatalogEntry].self, from: data) else { return }
        catalog = saved
    }

    /// Forgets downloaded posters and synopses, for when artwork is turned off.
    func clearCatalog() {
        catalog = [:]
        catalogMisses = []
        try? FileManager.default.removeItem(at: catalogURL)
    }

    // MARK: search

    var nyaa: NyaaClient {
        NyaaClient(baseURL: AppModel.nyaaURL(from: defaults.string(forKey: SettingsKey.nyaaAddress)))
    }

    /// Accepts "nyaa.si", "https://nyaa.si/" or a mirror; falls back to nyaa.si.
    static func nyaaURL(from text: String?) -> URL {
        var s = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return NyaaClient.defaultBaseURL }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), c.host?.isEmpty == false else { return NyaaClient.defaultBaseURL }
        c.path = ""
        c.query = nil
        return c.url ?? NyaaClient.defaultBaseURL
    }

    func handleOpen(url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            addMagnet(url.absoluteString)
        } else if url.isFileURL {
            addTorrentFile(at: url)
        }
    }

    // MARK: managing

    func remove(_ torrent: Torrent) {
        let hash = torrent.infoHashHex
        client.remove(torrent, deleteData: true)
        try? FileManager.default.removeItem(at: torrentFileURL(hash))
        addedAt[hash] = nil
        defaults.removeObject(forKey: lastPlayedKey(hash))
        defaults.removeObject(forKey: watchedAtKey(hash))
        if let i = navigationPath.firstIndex(where: { $0.hash == hash }) { navigationPath.removeSubrange(i...) }
        if let i = searchPath.firstIndex(where: { $0.hash == hash }) { searchPath.removeSubrange(i...) }
        persist()
        refresh()
        refreshStorage()
    }

    // MARK: caching

    /// Open players per title; those titles are never evicted.
    private var playing: [String: Int] = [:]
    /// The cache may use this share of the space left on the device, within the bounds below.
    private let cacheShare: Int64 = 4
    private let cacheFloor: Int64 = 2_000_000_000
    private let cacheCeiling: Int64 = 20_000_000_000

    /// Keeps cached video within budget by dropping the data of the titles watched longest ago.
    /// Titles stay in My List with their episodes and positions; they stream again when played.
    func trimCache() {
        guard playing.isEmpty, !BackgroundKeeper.shared.isActive else { return }
        let byLastUse = items.filter { $0.status.phase == .ready }
            .sorted { lastUse($0) < lastUse($1) }
            .map(\.id)
        guard byLastUse.count > 1 else { return }
        let dir = client.downloadDirectory
        let (share, floor, ceiling) = (cacheShare, cacheFloor, cacheCeiling)
        Task.detached(priority: .utility) {
            let total = AppModel.allocatedSize(of: dir)
            let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            let budget = min(ceiling, max(floor, (free + total) / share))
            guard total > budget else { return }
            var excess = total - budget
            var victims: [String] = []
            // The most recently watched title keeps its cache even when it alone is over budget.
            for hash in byLastUse.dropLast() where excess > 0 {
                let size = AppModel.allocatedSize(of: dir.appendingPathComponent(hash, isDirectory: true))
                guard size > 0 else { continue }
                victims.append(hash)
                excess -= size
            }
            let chosen = victims
            await MainActor.run { self.evict(chosen) }
        }
    }

    /// Clears every title's cached video. My List and watch history are kept.
    func clearCache() {
        evict(items.map(\.id))
    }

    private func lastUse(_ item: LibraryItem) -> Date {
        (defaults.object(forKey: watchedAtKey(item.id)) as? Date) ?? item.addedAt
    }

    /// Deletes a title's data and adds it back with its file list, so nothing changes for the user.
    private func evict(_ hashes: [String]) {
        for hash in hashes where playing[hash] == nil {
            guard let t = client.torrent(infoHashHex: hash), let info = t.torrentInfo else { continue }
            var descriptor = t.descriptor
            descriptor.info = info
            client.remove(t, deleteData: true)
            guard (try? client.add(descriptor: descriptor)) != nil else { continue }
            let dir = client.downloadDirectory.appendingPathComponent(hash, isDirectory: true)
            try? info.rawInfo.write(to: dir.appendingPathComponent("info.bencode"))
        }
        persist()
        refresh()
        refreshStorage()
    }

    private func key(_ t: Torrent, _ i: Int) -> String { "\(t.infoHashHex)#\(i)" }

    // MARK: playback

    func playbackRequest(torrent: Torrent, file: TorrentFile) -> PlaybackRequest {
        let url = client.streamURL(for: torrent, fileIndex: file.index, fileName: file.fileName)
        let base = (file.fileName as NSString).deletingPathExtension.lowercased()
        let subs = (torrent.torrentInfo?.files ?? [])
            .filter { $0.kind == .subtitle && $0.fileExtension != "idx" }
            .sorted { a, b in
                let ma = a.fileName.lowercased().hasPrefix(base), mb = b.fileName.lowercased().hasPrefix(base)
                return ma != mb ? ma : a.displayPath.localizedStandardCompare(b.displayPath) == .orderedAscending
            }
            .prefix(40)
            .map { SubtitleRef(name: $0.displayPath, url: client.streamURL(for: torrent, fileIndex: $0.index, fileName: $0.fileName)) }
        let resume = defaults.bool(forKey: SettingsKey.resumePlayback) ? savedPosition(torrent: torrent, file: file) : nil
        defaults.set(file.index, forKey: lastPlayedKey(torrent.infoHashHex))
        defaults.set(Date(), forKey: watchedAtKey(torrent.infoHashHex))
        let name = torrent.status().name
        let isMovie = (item(torrent.infoHashHex).map { playlist($0.status).count } ?? 1) <= 1
        return PlaybackRequest(torrent: torrent, file: file, url: url, subtitles: Array(subs), resumeAt: resume,
                               title: displayTitle(name: name),
                               episode: isMovie ? nil : (episodeLabel(file) ?? file.title))
    }

    private func lastPlayedKey(_ hash: String) -> String { "last.\(hash)" }
    private func watchedAtKey(_ hash: String) -> String { "watchedAt.\(hash)" }

    /// Called when the player appears.
    func playbackStarted(_ torrent: Torrent) {
        playing[torrent.infoHashHex, default: 0] += 1
    }

    /// Called when the player closes. A finished episode stops loading and the next one starts, so it plays
    /// instantly; an unfinished one keeps loading so resuming is instant.
    func playbackEnded(torrent: Torrent, file: TorrentFile, positionSeconds: Double, durationSeconds: Double) {
        savePosition(torrent: torrent, file: file, seconds: positionSeconds, duration: durationSeconds)
        defaults.set(file.index, forKey: lastPlayedKey(torrent.infoHashHex))
        defaults.set(Date(), forKey: watchedAtKey(torrent.infoHashHex))
        if isWatched(torrent: torrent, file: file) {
            torrent.setWanted(false, fileIndex: file.index)
            if let next = nextPlayable(after: file, in: torrent) { torrent.setWanted(true, fileIndex: next.index) }
        }
        let hash = torrent.infoHashHex
        if let n = playing[hash] { playing[hash] = n > 1 ? n - 1 : nil }
        persist()
        refresh()
        refreshStorage()
        trimCache()
    }

    func savedPosition(torrent: Torrent, file: TorrentFile) -> Double? {
        let k = "pos.\(key(torrent, file.index))"
        let pos = defaults.double(forKey: k), dur = defaults.double(forKey: k + ".dur")
        guard pos > 20 else { return nil }
        if dur > 0 && pos > dur * 0.95 { return nil }
        return pos
    }

    /// 0...1 watched progress for list rows.
    func watchedFraction(torrent: Torrent, file: TorrentFile) -> Double? {
        let k = "pos.\(key(torrent, file.index))"
        let pos = defaults.double(forKey: k), dur = defaults.double(forKey: k + ".dur")
        guard pos > 20, dur > 0 else { return nil }
        return min(1, pos / dur)
    }

    /// Watched to the end credits.
    func isWatched(torrent: Torrent, file: TorrentFile) -> Bool {
        (watchedFraction(torrent: torrent, file: file) ?? 0) >= 0.9
    }

    /// Length in seconds, known once the file has been opened in the player.
    func knownDuration(torrent: Torrent, file: TorrentFile) -> Double? {
        let d = defaults.double(forKey: "pos.\(key(torrent, file.index)).dur")
        return d > 0 ? d : nil
    }

    /// Titles started and not finished, most recently watched first.
    var continueWatching: [ContinueEntry] {
        items.compactMap { item -> (ContinueEntry, Date)? in
            guard let at = defaults.object(forKey: watchedAtKey(item.id)) as? Date,
                  let next = upNext(item),
                  !isWatched(torrent: item.torrent, file: next.file) else { return nil }
            return (ContinueEntry(item: item, next: next), at)
        }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
    }

    /// Seasons or folders of a title's episodes. Videos directly in the root come first.
    func episodeGroups(_ status: TorrentStatus) -> [EpisodeGroup] {
        let wanted = Set(playlist(status).map(\.index))
        let tree = FileTree.build(status.files.map(\.file)) { wanted.contains($0.index) }
        var groups: [EpisodeGroup] = []
        if !tree.files.isEmpty {
            groups.append(EpisodeGroup(id: "", name: tree.folders.isEmpty ? "Episodes" : "Main", files: tree.files))
        }
        for folder in tree.folders {
            let r = release(folder.name)
            let name = r.season.map { "Season \($0)" } ?? MediaTitle.clean(folder.name)
            groups.append(EpisodeGroup(id: folder.id, name: name, files: folder.allFiles))
        }
        return groups
    }

    /// Videos in the order they should be watched, without samples when there is real content.
    func playlist(_ status: TorrentStatus) -> [TorrentFile] {
        let media = status.files.map(\.file).filter { !$0.isPadding && $0.kind.isPlayable }
        let videos = media.filter { $0.kind == .video }
        let pool = videos.isEmpty ? media : videos
        let content = pool.filter { !$0.fileName.lowercased().contains("sample") }
        return (content.isEmpty ? pool : content)
            .sorted { FileTree.naturalOrder($0.displayPath, $1.displayPath) }
    }

    /// The video the Play button starts: the one in progress, the episode after the last one finished, the movie
    /// when one file dominates, or the first episode.
    func upNext(_ item: LibraryItem) -> UpNext? {
        let list = playlist(item.status)
        guard !list.isEmpty else { return nil }
        let torrent = item.torrent

        func make(_ f: TorrentFile) -> UpNext {
            let resume = defaults.bool(forKey: SettingsKey.resumePlayback) ? savedPosition(torrent: torrent, file: f) : nil
            let dur = defaults.double(forKey: "pos.\(key(torrent, f.index)).dur")
            return UpNext(file: f, resumeAt: resume, remaining: resume.map { dur - $0 })
        }

        if defaults.object(forKey: lastPlayedKey(torrent.infoHashHex)) != nil,
           let i = list.firstIndex(where: { $0.index == defaults.integer(forKey: lastPlayedKey(torrent.infoHashHex)) }) {
            if isWatched(torrent: torrent, file: list[i]), i + 1 < list.count { return make(list[i + 1]) }
            return make(list[i])
        }
        let total = list.reduce(Int64(0)) { $0 + $1.length }
        if let largest = list.max(by: { $0.length < $1.length }), Double(largest.length) > Double(total) * 0.6 {
            return make(largest)
        }
        return make(list[0])
    }

    private func savePosition(torrent: Torrent, file: TorrentFile, seconds: Double, duration: Double) {
        let k = "pos.\(key(torrent, file.index))"
        defaults.set(seconds, forKey: k)
        if duration > 0 { defaults.set(duration, forKey: k + ".dur") }
    }

    /// Next video in the torrent (episodes), in playlist order across folders.
    func nextPlayable(after file: TorrentFile, in torrent: Torrent) -> TorrentFile? {
        let list = playlist(torrent.status())
        guard let i = list.firstIndex(of: file), i + 1 < list.count else { return nil }
        return list[i + 1]
    }

    func artworkURL(_ item: LibraryItem) -> URL? {
        let images = item.status.files.filter { $0.file.isImage && $0.file.length < 8_000_000 }
        guard !images.isEmpty else { return nil }
        let preferred = images.first { f in
            let n = f.file.fileName.lowercased()
            return ["poster", "cover", "folder", "front"].contains { n.contains($0) }
        } ?? images.first { $0.file.path.count <= 2 }
        guard let f = preferred else { return nil }
        return client.streamURL(for: item.torrent, fileIndex: f.file.index, fileName: f.file.fileName)
    }

    // MARK: saving

    func localURL(_ torrent: Torrent, _ file: TorrentFile) -> URL? {
        torrent.localURL(fileIndex: file.index)
    }

    func saveToPhotos(_ torrent: Torrent, _ file: TorrentFile) {
        guard let url = localURL(torrent, file) else { return }
        Task {
            do {
                try await PhotoSaver.save(url)
                showToast("Saved to Photos")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copyStreamLink(_ torrent: Torrent, _ file: TorrentFile) {
        UIPasteboard.general.url = client.streamURL(for: torrent, fileIndex: file.index, fileName: file.fileName)
        showToast("Stream link copied", systemImage: "link")
    }

    func copyMagnet(_ torrent: Torrent) {
        UIPasteboard.general.string = torrent.magnetLink
        showToast("Magnet link copied", systemImage: "link")
    }

    // MARK: storage

    func refreshStorage() {
        let dir = client.downloadDirectory
        Task.detached(priority: .utility) {
            let total = AppModel.allocatedSize(of: dir)
            await MainActor.run { self.storageUsed = total }
        }
    }

    nonisolated private static func allocatedSize(of dir: URL) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    func removeAll() {
        for t in client.torrents { remove(t) }
    }

    // MARK: persistence

    private var libraryURL: URL { baseURL.appendingPathComponent("library.json") }
    private func torrentFileURL(_ hash: String) -> URL { baseURL.appendingPathComponent("torrents/\(hash).torrent") }

    private func persist() {
        let entries = client.torrents.map { t -> SavedEntry in
            let status = t.status()
            let wanted = status.files.filter { $0.wanted }.map { $0.file.index }
            return SavedEntry(infoHash: t.infoHashHex, magnet: t.descriptor.magnetURI,
                              hasTorrentFile: t.descriptor.torrentData != nil, wantedFiles: wanted,
                              paused: status.isPaused, addedAt: addedAt[t.infoHashHex])
        }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: libraryURL, options: .atomic) }
    }

    private func restoreLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let entries = try? JSONDecoder().decode([SavedEntry].self, from: data) else { return }
        for (i, e) in entries.enumerated() {
            var torrent: Torrent?
            if e.hasTorrentFile, let d = try? Data(contentsOf: torrentFileURL(e.infoHash)) {
                torrent = try? client.add(torrentData: d)
            } else if let m = e.magnet {
                torrent = try? client.add(magnet: m)
            }
            guard let t = torrent else { continue }
            addedAt[t.infoHashHex] = e.addedAt ?? Date(timeIntervalSince1970: TimeInterval(entries.count - i))
            for idx in e.wantedFiles ?? [] { t.setWanted(true, fileIndex: idx) }
        }
    }
}
