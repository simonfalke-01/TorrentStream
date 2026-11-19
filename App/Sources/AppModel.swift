import Foundation
import SwiftUI
import TorrentKit

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
        self == .vlc ? "Every format · audio tracks · subtitles" : "MP4/MOV · AirPlay · Picture in Picture"
    }
}

enum AppTab: Hashable { case library, downloads, settings }

enum SettingsKey {
    static let playerEngine = "playerEngine"
    static let keepDownloading = "keepDownloadingAfterPlayback"
    static let resumePlayback = "resumePlayback"
    static let autoPlayNext = "autoPlayNext"
    static let useDHT = "useDHT"
    static let publicTrackers = "usePublicTrackers"
}

@MainActor
final class AppModel: ObservableObject {
    let client: TorrentClient
    @Published private(set) var items: [LibraryItem] = []
    @Published var errorMessage: String?
    @Published var toast: Toast?
    @Published var navigationPath: [String] = []
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
        withAnimation(.spring(duration: 0.35)) { toast = Toast(message: message, systemImage: systemImage) }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
        }
    }

    // MARK: adding

    @discardableResult
    func addMagnet(_ text: String) -> Bool {
        do {
            let t = try client.add(magnet: text)
            didAdd(t)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addTorrentFile(_ data: Data) -> Bool {
        do {
            let t = try client.add(torrentData: data)
            try? data.write(to: torrentFileURL(t.infoHashHex))
            didAdd(t)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
        selectedTab = .library
        navigationPath = [t.infoHashHex]
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
        navigationPath.removeAll { $0 == hash }
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
        showToast("Downloading for offline", systemImage: "arrow.down.circle.fill")
    }

    func stopDownloading(_ torrent: Torrent, fileIndex: Int) {
        torrent.setWanted(false, fileIndex: fileIndex)
        explicitDownloads.remove(key(torrent, fileIndex))
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
        showToast("Downloading everything", systemImage: "arrow.down.circle.fill")
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
        return PlaybackRequest(torrent: torrent, file: file, url: url, subtitles: Array(subs), resumeAt: resume)
    }

    /// Called when the player closes.
    func playbackEnded(torrent: Torrent, file: TorrentFile, positionSeconds: Double, durationSeconds: Double) {
        savePosition(torrent: torrent, file: file, seconds: positionSeconds, duration: durationSeconds)
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

    private func savePosition(torrent: Torrent, file: TorrentFile, seconds: Double, duration: Double) {
        let k = "pos.\(key(torrent, file.index))"
        defaults.set(seconds, forKey: k)
        if duration > 0 { defaults.set(duration, forKey: k + ".dur") }
    }

    /// Next video in the torrent (episodes), by natural filename order.
    func nextPlayable(after file: TorrentFile, in torrent: Torrent) -> TorrentFile? {
        let videos = (torrent.torrentInfo?.files ?? [])
            .filter { $0.kind == file.kind && !$0.isPadding }
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
        guard let i = videos.firstIndex(of: file), i + 1 < videos.count else { return nil }
        return videos[i + 1]
    }

    /// The file most likely to be "the movie".
    func mainPlayable(_ status: TorrentStatus) -> FileStatus? {
        status.files.filter { $0.file.kind == .video && !$0.file.isPadding }.max { $0.file.length < $1.file.length }
            ?? status.files.filter { $0.file.kind == .audio }.first
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
