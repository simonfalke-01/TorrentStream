import Foundation
import SwiftUI
import TorrentKit

struct LibraryItem: Identifiable {
    let torrent: Torrent
    let status: TorrentStatus
    var id: String { torrent.infoHashHex }
}

/// What the player needs to stream one file.
struct PlaybackRequest: Identifiable {
    let torrent: Torrent
    let file: TorrentFile
    let url: URL
    /// Subtitle files shipped inside the torrent, as stream URLs, best match first.
    let subtitles: [(name: String, url: URL)]
    var id: String { "\(torrent.infoHashHex)/\(file.index)" }
}

enum PlayerEngine: String, CaseIterable, Identifiable {
    case vlc, apple
    var id: String { rawValue }
    var title: String { self == .vlc ? "VLC (all formats, tracks & subtitles)" : "Apple AVPlayer (MP4/MOV only)" }
}

@MainActor
final class AppModel: ObservableObject {
    let client: TorrentClient
    @Published private(set) var items: [LibraryItem] = []
    @Published var errorMessage: String?
    @Published var navigationPath: [String] = []
    @AppStorage("playerEngine") var playerEngineRaw: String = PlayerEngine.vlc.rawValue

    private let baseURL: URL
    private var timer: Timer?

    private struct SavedEntry: Codable {
        let infoHash: String
        var magnet: String?
        var hasTorrentFile: Bool
        var wantedFiles: [Int]?
    }

    var playerEngine: PlayerEngine {
        if !VLCAvailability.isAvailable { return .apple }
        return PlayerEngine(rawValue: playerEngineRaw) ?? .vlc
    }

    init() {
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL.appendingPathComponent("torrents"), withIntermediateDirectories: true)
        client = TorrentClient(downloadDirectory: baseURL.appendingPathComponent("Downloads", isDirectory: true))
        restoreLibrary()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        items = client.torrents.map { LibraryItem(torrent: $0, status: $0.status()) }
    }

    func item(_ hash: String) -> LibraryItem? { items.first { $0.id == hash } }

    // MARK: adding

    @discardableResult
    func addMagnet(_ text: String) -> Bool {
        do {
            let t = try client.add(magnet: text)
            persist()
            refresh()
            navigationPath = [t.infoHashHex]
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
            persist()
            refresh()
            navigationPath = [t.infoHashHex]
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addTorrentFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            addTorrentFile(try Data(contentsOf: url))
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func handleOpen(url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            addMagnet(url.absoluteString)
        } else if url.isFileURL {
            addTorrentFile(at: url)
        }
    }

    func remove(_ torrent: Torrent, deleteData: Bool) {
        client.remove(torrent, deleteData: deleteData)
        try? FileManager.default.removeItem(at: torrentFileURL(torrent.infoHashHex))
        persist()
        refresh()
    }

    func setWanted(_ wanted: Bool, torrent: Torrent, fileIndex: Int) {
        torrent.setWanted(wanted, fileIndex: fileIndex)
        persist()
    }

    // MARK: playback

    func playbackRequest(torrent: Torrent, file: TorrentFile) -> PlaybackRequest {
        let url = client.streamURL(for: torrent, fileIndex: file.index, fileName: file.fileName)
        let base = (file.fileName as NSString).deletingPathExtension.lowercased()
        let subs = (torrent.torrentInfo?.files ?? [])
            .filter { MediaKind(fileExtension: $0.fileExtension) == .subtitle && $0.fileExtension != "idx" }
            .sorted { a, b in
                // Subtitles named after the video come first.
                let ma = a.fileName.lowercased().hasPrefix(base), mb = b.fileName.lowercased().hasPrefix(base)
                return ma != mb ? ma : a.displayPath < b.displayPath
            }
            .prefix(40)
            .map { (name: $0.displayPath, url: client.streamURL(for: torrent, fileIndex: $0.index, fileName: $0.fileName)) }
        persist()
        return PlaybackRequest(torrent: torrent, file: file, url: url, subtitles: Array(subs))
    }

    // MARK: persistence

    private var libraryURL: URL { baseURL.appendingPathComponent("library.json") }
    private func torrentFileURL(_ hash: String) -> URL { baseURL.appendingPathComponent("torrents/\(hash).torrent") }

    private func persist() {
        let entries = client.torrents.map { t -> SavedEntry in
            let wanted = t.status().files.filter { $0.wanted }.map { $0.file.index }
            return SavedEntry(infoHash: t.infoHashHex, magnet: t.descriptor.magnetURI,
                              hasTorrentFile: t.descriptor.torrentData != nil, wantedFiles: wanted)
        }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: libraryURL, options: .atomic) }
    }

    private func restoreLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let entries = try? JSONDecoder().decode([SavedEntry].self, from: data) else { return }
        for e in entries {
            var torrent: Torrent?
            if e.hasTorrentFile, let d = try? Data(contentsOf: torrentFileURL(e.infoHash)) {
                torrent = try? client.add(torrentData: d)
            } else if let m = e.magnet {
                torrent = try? client.add(magnet: m)
            }
            if let t = torrent {
                for i in e.wantedFiles ?? [] { t.setWanted(true, fileIndex: i) }
            }
        }
    }
}
