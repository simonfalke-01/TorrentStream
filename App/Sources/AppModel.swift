import Foundation
import SwiftUI
import TorrentKit
import NyaaKit

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

enum AppTab: Hashable { case library, downloads, settings, search }

/// Navigation destinations shared by the Library and Search stacks.
enum Route: Hashable {
    case torrent(String)
    /// A folder inside a torrent, by `FileFolder.id`.
    case folder(hash: String, folder: String)
    /// A search result that is added to the library when opened.
    case nyaa(NyaaResult)

    var hash: String {
        switch self {
        case .torrent(let h), .folder(let h, _): return h
        case .nyaa(let r): return r.infoHash ?? ""
        }
    }
}

enum SettingsKey {
    static let playerEngine = "playerEngine"
    static let keepDownloading = "keepDownloadingAfterPlayback"
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
}

/// What the header's Play button starts.
struct UpNext {
    let file: TorrentFile
    let resumeAt: Double?
    /// Seconds left when resuming.
    let remaining: Double?
}

@MainActor
final class AppModel: ObservableObject {
    let client: TorrentClient
    @Published private(set) var items: [LibraryItem] = []
    @Published var errorMessage: String?
    @Published var toast: Toast?
    @Published var navigationPath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var selectedTab: AppTab = .library
    @Published private(set) var storageUsed: Int64 = 0

    private let baseURL: URL
    private var timer: Timer?
    private var addedAt: [String: Date] = [:]
    private var explicitDownloads: Set<String> = []
    private var toastTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

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
            SettingsKey.keepDownloading: true,
            SettingsKey.resumePlayback: true,
            SettingsKey.autoPlayNext: true,
            SettingsKey.useDHT: true,
            SettingsKey.publicTrackers: true,
        ])
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL.appendingPathComponent("torrents"), withIntermediateDirectories: true)
        client = TorrentClient(
            downloadDirectory: baseURL.appendingPathComponent("Downloads", isDirectory: true),
            useDHT: defaults.bool(forKey: SettingsKey.useDHT),
            extraTrackers: defaults.bool(forKey: SettingsKey.publicTrackers) ? TorrentClient.defaultTrackers : []
        )
        explicitDownloads = Set(defaults.stringArray(forKey: "explicitDownloads") ?? [])
        restoreLibrary()
        refresh()
        refreshStorage()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        items = client.torrents
            .map { LibraryItem(torrent: $0, status: $0.status(), addedAt: addedAt[$0.infoHashHex] ?? .distantPast) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func item(_ hash: String) -> LibraryItem? { items.first { $0.id == hash } }

    var activeDownloadCount: Int {
        items.reduce(0) { $0 + ($1.status.isPaused ? 0 : $1.status.files.filter { $0.isDownloading && !$0.file.isPadding }.count) }
    }

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
        selectedTab = .library
        navigationPath = [.torrent(hash)]
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
        explicitDownloads = explicitDownloads.filter { !$0.hasPrefix(hash) }
        defaults.removeObject(forKey: lastPlayedKey(hash))
        if let i = navigationPath.firstIndex(where: { $0.hash == hash }) { navigationPath.removeSubrange(i...) }
        if let i = searchPath.firstIndex(where: { $0.hash == hash }) { searchPath.removeSubrange(i...) }
        persist()
        refresh()
        refreshStorage()
    }

    func togglePause(_ torrent: Torrent) {
        if torrent.isPaused { torrent.resume() } else { torrent.pause() }
        persist()
        refresh()
    }

    /// "Download for offline": fetch the whole file in the background.
    func download(_ torrent: Torrent, fileIndex: Int) {
        torrent.resume()
        torrent.setWanted(true, fileIndex: fileIndex)
        explicitDownloads.insert(key(torrent, fileIndex))
        persist()
        refresh()
        showToast("Download started", systemImage: "arrow.down.circle")
    }

    func stopDownloading(_ torrent: Torrent, fileIndex: Int) {
        stopDownloading(torrent, fileIndices: [fileIndex])
    }

    func download(_ torrent: Torrent, fileIndices: [Int]) {
        torrent.resume()
        for i in fileIndices {
            torrent.setWanted(true, fileIndex: i)
            explicitDownloads.insert(key(torrent, i))
        }
        persist()
        refresh()
        showToast(fileIndices.count == 1 ? "Download started" : "Downloading \(Format.videos(fileIndices.count))",
                  systemImage: "arrow.down.circle")
    }

    func stopDownloading(_ torrent: Torrent, fileIndices: [Int]) {
        for i in fileIndices {
            torrent.setWanted(false, fileIndex: i)
            explicitDownloads.remove(key(torrent, i))
        }
        persist()
        refresh()
    }

    func downloadAll(_ torrent: Torrent) {
        torrent.resume()
        for f in torrent.torrentInfo?.files ?? [] where !f.isPadding {
            torrent.setWanted(true, fileIndex: f.index)
            explicitDownloads.insert(key(torrent, f.index))
        }
        persist()
        refresh()
        showToast("Downloading all files", systemImage: "arrow.down.circle")
    }

    func stopAllDownloads(_ torrent: Torrent) {
        torrent.setAllWanted(false)
        explicitDownloads = explicitDownloads.filter { !$0.hasPrefix(torrent.infoHashHex) }
        persist()
        refresh()
    }

    /// True when the user asked to keep this file (as opposed to it only being fetched for streaming).
    func isOfflineDownload(_ torrent: Torrent, fileIndex: Int) -> Bool {
        explicitDownloads.contains(key(torrent, fileIndex))
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
        return PlaybackRequest(torrent: torrent, file: file, url: url, subtitles: Array(subs), resumeAt: resume)
    }

    private func lastPlayedKey(_ hash: String) -> String { "last.\(hash)" }

    /// Called when the player closes.
    func playbackEnded(torrent: Torrent, file: TorrentFile, positionSeconds: Double, durationSeconds: Double) {
        savePosition(torrent: torrent, file: file, seconds: positionSeconds, duration: durationSeconds)
        defaults.set(file.index, forKey: lastPlayedKey(torrent.infoHashHex))
        let keep = defaults.bool(forKey: SettingsKey.keepDownloading)
        let complete = torrent.status().files.first { $0.file.index == file.index }?.isComplete ?? false
        if !keep && !complete && !explicitDownloads.contains(key(torrent, file.index)) {
            torrent.setWanted(false, fileIndex: file.index)
        }
        persist()
        refresh()
        refreshStorage()
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

    func completedMediaURLs(_ item: LibraryItem) -> [URL] {
        item.status.files
            .filter { $0.isComplete && ($0.file.kind.isPlayable || $0.file.kind == .subtitle) && !$0.file.isPadding }
            .compactMap { localURL(item.torrent, $0.file) }
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
        defaults.set(Array(explicitDownloads), forKey: "explicitDownloads")
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
            if e.paused == true { t.pause() }
        }
    }
}
