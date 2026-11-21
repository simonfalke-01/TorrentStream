import Foundation
import SwiftUI
import TorrentKit
import NyaaKit
import CatalogKit
import SourceKit

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
    /// The catalog episode this plays, when started from a show page.
    var show: ShowPlayback? = nil
    var id: String { "\(torrent.infoHashHex)/\(file.index)" }

    func with(title: String, episode: String?, resumeAt: Double?, show: ShowPlayback?) -> PlaybackRequest {
        PlaybackRequest(torrent: torrent, file: file, url: url, subtitles: subtitles, resumeAt: resumeAt,
                        title: title, episode: episode, show: show)
    }
}

/// What the player offers when a video ends.
struct UpNextItem {
    /// "Episode 6" or "S2 E1".
    let title: String
    /// The episode's name, when known.
    let subtitle: String?
    /// The episode's still.
    var imageURL: URL? = nil
    let resolve: @MainActor () async -> PlaybackRequest?
}

enum AppTab: Hashable { case home, schedule, library, search }

/// Navigation destinations shared by every tab's stack.
enum Route: Hashable {
    /// A title in My List, by info hash.
    case title(String)
    /// A show or movie from the catalog.
    case show(Show)

    var hash: String {
        switch self {
        case .title(let h): return h
        case .show: return ""
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
    static let resumePlayback = "resumePlayback"
    static let subtitleSize = "subtitleSize"
    /// Audio and subtitle choices per show, by track label.
    static let trackChoices = "trackChoices"
    static let autoPlayNext = "autoPlayNext"
    static let useDHT = "useDHT"
    static let publicTrackers = "usePublicTrackers"
    static let nyaaAddress = "nyaaAddress"
    static let recentSearches = "recentShowSearches"
    /// Titles added by link before shows existed, still to be moved into their show.
    static let linkAdoption = "linkAdoptionPending"
    /// Vertical resolution to prefer: 2160, 1080, 720 or 480.
    static let preferredResolution = "preferredResolution"
    /// English audio over Japanese.
    static let preferDub = "preferDub"
    static let showArtwork = "showArtwork"
    /// Cache budget in gigabytes.
    static let cacheLimitGB = "cacheLimitGB"
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
    /// Titles the user added by link. Torrents started from show pages are kept out of sight.
    @Published private(set) var items: [LibraryItem] = []
    /// Torrents found for catalog episodes. They never appear in My List and are removed when evicted.
    private(set) var sourceHashes: Set<String> = []
    @Published var errorMessage: String?
    @Published var toast: Toast?
    @Published var navigationPath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var schedulePath: [Route] = []
    @Published var listPath: [Route] = []
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
    /// Episode sources from earlier launches that haven't been needed yet. They stay out of the engine (no tracker,
    /// DHT or piece checking work at launch) until an episode asks for one.
    private var dormant: [String: SavedEntry] = [:]
    /// File lists of dormant sources, read from disk when asked for.
    private var dormantInfo: [String: TorrentInfo] = [:]
    /// .torrent files of releases found for episodes, by download URL.
    let torrentFiles = TorrentFileStore(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentFiles", isDirectory: true))

    private struct SavedEntry: Codable {
        let infoHash: String
        var magnet: String?
        var hasTorrentFile: Bool
        var wantedFiles: [Int]?
        var paused: Bool?
        var addedAt: Date?
        var isSource: Bool?
    }

    init() {
        defaults.register(defaults: [
            SettingsKey.resumePlayback: true,
            SettingsKey.autoPlayNext: true,
            SettingsKey.useDHT: true,
            SettingsKey.publicTrackers: true,
            SettingsKey.showArtwork: true,
            SettingsKey.cacheLimitGB: 5,
            SettingsKey.preferredResolution: 1080,
            SettingsKey.preferDub: false,
        ])
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL.appendingPathComponent("torrents"), withIntermediateDirectories: true)
        client = TorrentClient(
            downloadDirectory: baseURL.appendingPathComponent("Downloads", isDirectory: true),
            useDHT: defaults.bool(forKey: SettingsKey.useDHT),
            extraTrackers: defaults.bool(forKey: SettingsKey.publicTrackers) ? TorrentClient.defaultTrackers : []
        )
        PlaybackTrace.shared.launch("model init")
        restoreCatalog()
        restoreLibrary()
        PlaybackTrace.shared.launch("library restored (\(client.torrents.count) in engine, \(dormant.count) dormant)")
        // Connections to the hosts every play uses, so the first search or download doesn't pay DNS, TCP and TLS.
        HTTP.preconnect([nyaa.baseURL.appendingPathComponent("static/favicon.png"),
                         URL(string: "https://kitsu.app/api/edge")!, URL(string: "https://api.ani.zip/mappings")!])
        refresh()
        refreshStorage()
        trimCache()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        items = client.torrents
            .filter { !sourceHashes.contains($0.infoHashHex) }
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
            sourceHashes.remove(t.infoHashHex)
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
            sourceHashes.remove(t.infoHashHex)
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

    // MARK: episode sources

    /// Adds a release found for a catalog episode, or returns it when already added. The .torrent file is used
    /// when it can be fetched, since it carries the file list; otherwise the magnet link.
    func addSource(torrentURL: URL?, magnet: String?, infoHash: String?) async -> Torrent? {
        if let h = infoHash?.lowercased(), let t = client.torrent(infoHashHex: h) ?? wakeSource(h) {
            if t.isPaused { t.resume() }
            return t
        }
        let fetchStart = Date()
        var fetched: Data?
        if let url = torrentURL {
            let wasCached = await torrentFiles.cached(url) != nil
            fetched = try? await torrentFiles.data(for: url)
            PlaybackTrace.shared.mark(String(format: "torrent file %@ in %.2fs", fetched == nil ? "failed" : (wasCached ? "on disk" : "fetched"),
                                             Date().timeIntervalSince(fetchStart)))
        }
        if let data = fetched {
            let hash = (try? TorrentDescriptor.parse(torrentData: data))?.infoHashHex
            if let hash, let existing = client.torrent(infoHashHex: hash) ?? wakeSource(hash) {
                if existing.isPaused { existing.resume() }
                return existing
            }
            if let t = try? client.add(torrentData: data) {
                try? data.write(to: torrentFileURL(t.infoHashHex))
                didAddSource(t)
                return t
            }
        }
        if let magnet, let t = try? client.add(magnet: magnet) {
            PlaybackTrace.shared.mark("added by magnet; metadata comes from peers")
            didAddSource(t)
            return t
        }
        return nil
    }

    private func didAddSource(_ t: Torrent) {
        sourceHashes.insert(t.infoHashHex)
        addedAt[t.infoHashHex] = Date()
        persist()
    }

    /// Drops a source that turned out not to play the episode, unless something is using it.
    func discardSource(_ t: Torrent) {
        let hash = t.infoHashHex
        guard sourceHashes.contains(hash), playing[hash] == nil else { return }
        removeSource(hash)
        persist()
    }

    /// Adds a dormant source to the engine.
    private func wakeSource(_ hash: String) -> Torrent? {
        guard let e = dormant.removeValue(forKey: hash) else { return nil }
        dormantInfo[hash] = nil
        let t = add(e)
        PlaybackTrace.shared.mark("woke source \(hash.prefix(8)) (\(t == nil ? "failed" : "added"))")
        return t
    }

    /// The file list of an episode source, whether in the engine or dormant.
    func sourceInfo(_ hash: String) -> TorrentInfo? {
        if let t = client.torrent(infoHashHex: hash) { return t.torrentInfo }
        guard let e = dormant[hash] else { return nil }
        if let info = dormantInfo[hash] { return info }
        var info: TorrentInfo?
        if e.hasTorrentFile, let d = try? Data(contentsOf: torrentFileURL(hash)) {
            info = (try? TorrentDescriptor.parse(torrentData: d))?.info
        } else if let raw = try? Data(contentsOf: client.downloadDirectory.appendingPathComponent("\(hash)/info.bencode")) {
            info = try? TorrentInfo(rawInfo: raw)
        }
        dormantInfo[hash] = info
        return info
    }

    /// An episode source by info hash, woken if dormant.
    func sourceTorrent(_ hash: String) -> Torrent? {
        client.torrent(infoHashHex: hash) ?? wakeSource(hash)
    }

    private func removeSource(_ hash: String) {
        if let t = client.torrent(infoHashHex: hash) { client.remove(t, deleteData: true) }
        if dormant.removeValue(forKey: hash) != nil {
            dormantInfo[hash] = nil
            try? FileManager.default.removeItem(at: client.downloadDirectory.appendingPathComponent(hash, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: torrentFileURL(hash))
        sourceHashes.remove(hash)
        addedAt[hash] = nil
        defaults.removeObject(forKey: lastPlayedKey(hash))
        defaults.removeObject(forKey: watchedAtKey(hash))
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
        if let i = listPath.firstIndex(where: { $0.hash == hash }) { listPath.removeSubrange(i...) }
        persist()
        refresh()
        refreshStorage()
    }

    // MARK: caching

    /// Open players per title; those titles are never evicted.
    private var playing: [String: Int] = [:]

    func isPlaying(_ torrent: Torrent) -> Bool { playing[torrent.infoHashHex] != nil }

    /// A player is open.
    var isPlayingAnything: Bool { !playing.isEmpty }

    /// What getting likely episodes ready may load beyond the essentials (their head, index and resume point): a
    /// twentieth of the cache, at least 64 MB.
    var warmBudget: Int64 { max(64 << 20, cacheLimit / 20) }

    /// Keeps cached video within budget by dropping the data of the titles watched longest ago, the most recent
    /// one last. Titles stay in My List with their episodes and positions; they stream again when played.
    func trimCache() {
        guard playing.isEmpty else { return }
        // Sources that were found but never played, beyond the most recent few, only take up slots.
        let sources = (client.torrents.map(\.infoHashHex).filter { sourceHashes.contains($0) } + dormant.keys)
            .sorted { lastUse($0) > lastUse($1) }
        if sources.count > AppModel.maxSources {
            for hash in sources[AppModel.maxSources...] { removeSource(hash) }
            persist()
        }
        let byLastUse = (client.torrents.filter { $0.torrentInfo != nil }.map(\.infoHashHex) + dormant.keys)
            .sorted { lastUse($0) < lastUse($1) }
        guard !byLastUse.isEmpty else { return }
        let dir = client.downloadDirectory
        let limit = cacheLimit
        Task.detached(priority: .utility) {
            let total = AppModel.allocatedSize(of: dir)
            let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            // Never more than a quarter of the space the phone has left.
            let budget = min(limit, max(AppModel.minimumCache, (free + total) / 4))
            guard total > budget else { return }
            var excess = total - budget
            var victims: [String] = []
            for hash in byLastUse where excess > 0 {
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
        evict(client.torrents.map(\.infoHashHex) + dormant.keys)
    }

    private func lastUse(_ hash: String) -> Date {
        (defaults.object(forKey: watchedAtKey(hash)) as? Date) ?? addedAt[hash] ?? .distantPast
    }

    func watchedAt(_ hash: String) -> Date? { defaults.object(forKey: watchedAtKey(hash)) as? Date }

    /// Index of the file played last from a title.
    func lastPlayedIndex(_ hash: String) -> Int? {
        defaults.object(forKey: lastPlayedKey(hash)) == nil ? nil : defaults.integer(forKey: lastPlayedKey(hash))
    }

    /// Where playback of a file stopped and how long it is, when it was played.
    func storedProgress(torrent: Torrent, file: TorrentFile) -> (position: Double, duration: Double)? {
        let k = "pos.\(key(torrent, file.index))"
        let pos = defaults.double(forKey: k), dur = defaults.double(forKey: k + ".dur")
        return pos > 0 ? (pos, dur) : nil
    }

    /// Turns a title added by link into an episode source: it leaves My List and plays from its show's page.
    func makeSource(_ hash: String) {
        guard client.torrent(infoHashHex: hash) != nil, !sourceHashes.contains(hash) else { return }
        sourceHashes.insert(hash)
        if let i = navigationPath.firstIndex(where: { $0 == .title(hash) }) { navigationPath.removeSubrange(i...) }
        if let i = searchPath.firstIndex(where: { $0 == .title(hash) }) { searchPath.removeSubrange(i...) }
        if let i = listPath.firstIndex(where: { $0 == .title(hash) }) { listPath.removeSubrange(i...) }
        persist()
        refresh()
    }

    /// Deletes a title's data and adds it back with its file list, so nothing changes for the user.
    /// Episode sources are removed outright; they are found again when played.
    private func evict(_ hashes: [String]) {
        for hash in hashes where playing[hash] == nil {
            if sourceHashes.contains(hash) {
                removeSource(hash)
                continue
            }
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

    /// Called when the player appears. Loads about ten minutes past the playhead and the start of the next episode.
    func playbackStarted(_ request: PlaybackRequest) {
        let torrent = request.torrent
        playing[torrent.infoHashHex, default: 0] += 1
        // Other episode sources go quiet; the next episode's is woken by its prefetch.
        for t in client.torrents where sourceHashes.contains(t.infoHashHex) && t !== torrent && playing[t.infoHashHex] == nil {
            if !t.isPaused { t.pause() }
        }
        if let d = knownDuration(torrent: torrent, file: request.file) { durationKnown(request, seconds: d) }
    }

    /// Sizes the readahead from the video's bitrate.
    func durationKnown(_ request: PlaybackRequest, seconds: Double) {
        guard seconds.isFinite, seconds > 60 else { return }
        let bytesPerSecond = Double(request.file.length) / seconds
        request.torrent.setReadahead(min(1 << 30, max(64 << 20, Int64(bytesPerSecond * 600))), fileIndex: request.file.index)
    }

    /// Once playback has run smoothly for a while, loads the start of the next video in the same torrent. Not
    /// earlier: until then every peer request should go to what's on screen. Show pages find the next episode
    /// themselves, since it may be in another release.
    func playbackSteady(_ request: PlaybackRequest, seconds: Double) {
        guard request.show == nil, let next = nextPlayable(after: request.file, in: request.torrent) else { return }
        request.torrent.prefetch(fileIndex: next.index, bytes: AppModel.prefetchBytes(fileLength: request.file.length, seconds: seconds))
    }

    nonisolated static let defaultPrefetch: Int64 = 100 << 20
    /// Episode sources kept around for quick replays.
    private static let maxSources = 24

    /// Bytes of the next episode to load ahead, sized to about three minutes of the current one.
    static func prefetchBytes(fileLength: Int64, seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 60 else { return defaultPrefetch }
        return min(200 << 20, max(32 << 20, Int64(Double(fileLength) / seconds * 180)))
    }
    nonisolated private static let minimumCache: Int64 = 1_000_000_000

    private var cacheLimit: Int64 { Int64(max(1, defaults.integer(forKey: SettingsKey.cacheLimitGB))) * 1_000_000_000 }

    /// Called when the player closes. What was loaded stays cached, so resuming is instant; nothing more is fetched
    /// except the start of the next episode.
    func playbackEnded(torrent: Torrent, file: TorrentFile, positionSeconds: Double, durationSeconds: Double) {
        savePosition(torrent: torrent, file: file, seconds: positionSeconds, duration: durationSeconds)
        defaults.set(file.index, forKey: lastPlayedKey(torrent.infoHashHex))
        defaults.set(Date(), forKey: watchedAtKey(torrent.infoHashHex))
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

    /// Saves the position while playing, so it survives the app being closed or killed mid-episode.
    func playbackProgressed(torrent: Torrent, file: TorrentFile, positionSeconds: Double, durationSeconds: Double) {
        guard positionSeconds > 0 else { return }
        savePosition(torrent: torrent, file: file, seconds: positionSeconds, duration: durationSeconds)
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
        for t in client.torrents where !sourceHashes.contains(t.infoHashHex) { remove(t) }
    }

    // MARK: persistence

    private var libraryURL: URL { baseURL.appendingPathComponent("library.json") }
    private func torrentFileURL(_ hash: String) -> URL { baseURL.appendingPathComponent("torrents/\(hash).torrent") }

    private func persist() {
        let live = client.torrents.map { t -> SavedEntry in
            let status = t.status()
            let wanted = status.files.filter { $0.wanted }.map { $0.file.index }
            return SavedEntry(infoHash: t.infoHashHex, magnet: t.descriptor.magnetURI,
                              hasTorrentFile: t.descriptor.torrentData != nil, wantedFiles: wanted,
                              paused: status.isPaused, addedAt: addedAt[t.infoHashHex],
                              isSource: sourceHashes.contains(t.infoHashHex) ? true : nil)
        }
        let liveHashes = Set(live.map(\.infoHash))
        let sleeping = dormant.values.filter { !liveHashes.contains($0.infoHash) }.map { e -> SavedEntry in
            var e = e
            e.addedAt = addedAt[e.infoHash] ?? e.addedAt
            return e
        }
        if let data = try? JSONEncoder().encode(live + sleeping) { try? data.write(to: libraryURL, options: .atomic) }
    }

    private func add(_ e: SavedEntry, paused: Bool = false) -> Torrent? {
        if e.hasTorrentFile, let d = try? Data(contentsOf: torrentFileURL(e.infoHash)) {
            return try? client.add(torrentData: d, paused: paused)
        } else if let m = e.magnet {
            return try? client.add(magnet: m, paused: paused)
        }
        return nil
    }

    private func restoreLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let entries = try? JSONDecoder().decode([SavedEntry].self, from: data) else { return }
        for (i, e) in entries.enumerated() {
            let added = e.addedAt ?? Date(timeIntervalSince1970: TimeInterval(entries.count - i))
            if e.isSource == true {
                // Woken when an episode needs it.
                dormant[e.infoHash] = e
                sourceHashes.insert(e.infoHash)
                addedAt[e.infoHash] = added
                continue
            }
            // Idle titles stay off the network until played. Files wanted by older versions aren't fetched in full.
            guard let t = add(e, paused: true) else { continue }
            addedAt[t.infoHashHex] = added
            // A magnet still needs its metadata from peers.
            if t.torrentInfo == nil { t.resume() }
        }
    }
}
