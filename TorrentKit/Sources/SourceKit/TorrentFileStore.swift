import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CatalogKit

/// .torrent files kept on disk by download URL. A release's file is fetched once (often ahead of time, while
/// the rest of the search is still running) and read from disk after that, so picking the same release again
/// or adding it back after it was dropped costs no round trip. Requests for a file already on its way share
/// that download.
public actor TorrentFileStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let directory: URL
    private let maxFiles: Int
    private let fetch: Fetch
    private var running: [URL: Task<Data, Error>] = [:]
    private var writesSincePrune = 0

    public init(directory: URL, maxFiles: Int = 400, fetch: Fetch? = nil) {
        self.directory = directory
        self.maxFiles = maxFiles
        self.fetch = fetch ?? Self.download
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The file when it's on disk.
    public func cached(_ url: URL) -> Data? {
        let path = file(url)
        guard let data = try? Data(contentsOf: path), Self.looksLikeTorrent(data) else { return nil }
        // Recently used files outlive the rest when the store is pruned.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return data
    }

    /// The file from disk, from a download already running, or downloaded now.
    public func data(for url: URL) async throws -> Data {
        if let hit = cached(url) { return hit }
        if let task = running[url] { return try await task.value }
        let fetch = self.fetch
        let task = Task { try await fetch(url) }
        running[url] = task
        defer { running[url] = nil }
        let data = try await task.value
        guard Self.looksLikeTorrent(data) else { throw URLError(.cannotParseResponse) }
        save(data, for: url)
        return data
    }

    /// Starts downloading files likely to be needed soon; does nothing for those on disk or on their way.
    public nonisolated func prefetch(_ urls: [URL]) {
        for url in urls {
            Task { _ = try? await self.data(for: url) }
        }
    }

    /// Whether a download of `url` is running.
    public func isFetching(_ url: URL) -> Bool { running[url] != nil }

    public func save(_ data: Data, for url: URL) {
        try? data.write(to: file(url), options: .atomic)
        writesSincePrune += 1
        if writesSincePrune >= 20 {
            writesSincePrune = 0
            prune()
        }
    }

    /// Keeps the most recently used `maxFiles` files.
    public func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              names.count > maxFiles else { return }
        let dated = names.map { u in
            (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (u, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maxFiles) { try? fm.removeItem(at: u) }
    }

    func file(_ url: URL) -> URL {
        directory.appendingPathComponent(Self.name(url.absoluteString) + ".torrent")
    }

    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func name(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// A bencoded dictionary rather than an error page.
    static func looksLikeTorrent(_ data: Data) -> Bool {
        data.count > 16 && data.first == UInt8(ascii: "d")
    }

    private static let download: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("TorrentStream/4 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.data(.shared, for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return data
    }
}
