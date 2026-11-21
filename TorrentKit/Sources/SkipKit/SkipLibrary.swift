import Foundation
import CatalogKit

/// Fingerprints of episodes heard before, kept on disk by series, so the next episode of a show can be compared
/// with the ones already watched without downloading them again. About 60 KB an episode.
public actor SkipLibrary {
    private let directory: URL
    private let maxSeries: Int
    private let maxEpisodes: Int
    private var cache: [String: [Int: EpisodeAudio]] = [:]

    /// Keeps up to `maxEpisodes` episodes (the most recently stored) of each of the `maxSeries` series stored most recently.
    public init(directory: URL, maxSeries: Int = 40, maxEpisodes: Int = 6) {
        self.directory = directory
        self.maxSeries = maxSeries
        self.maxEpisodes = maxEpisodes
    }

    /// Stored episodes of a series, by episode number.
    public func episodes(series: String) -> [Int: EpisodeAudio] {
        let key = name(series)
        if let cached = cache[key] { return cached }
        var out: [Int: EpisodeAudio] = [:]
        let dir = directory.appendingPathComponent(key, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let n = Int(file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let audio = try? JSONDecoder().decode(EpisodeAudio.self, from: data) else { continue }
            out[n] = audio
        }
        cache[key] = out
        return out
    }

    /// Keeps the print of an episode, unless one with more of the episode heard is stored already (say a full
    /// viewing, while this is just the prefetched start of the same episode).
    public func store(_ audio: EpisodeAudio, series: String, episode: Int) {
        var all = episodes(series: series)
        if let old = all[episode], old.print.decodedSeconds > audio.print.decodedSeconds { return }
        all[episode] = audio
        let key = name(series)
        let dir = directory.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(audio) {
            try? data.write(to: dir.appendingPathComponent("\(episode).json"), options: .atomic)
        }
        // Forget the episodes stored longest ago, then the series.
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
        if files.count > maxEpisodes {
            for file in files.sorted(by: { modified($0) > modified($1) }).dropFirst(maxEpisodes) {
                try? FileManager.default.removeItem(at: file)
                if let n = Int(file.deletingPathExtension().lastPathComponent) { all[n] = nil }
            }
        }
        cache[key] = all
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        let folders = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        if folders.count > maxSeries {
            for old in folders.sorted(by: { modified($0) > modified($1) }).dropFirst(maxSeries) {
                try? FileManager.default.removeItem(at: old)
                cache[old.lastPathComponent] = nil
            }
        }
    }

    private func name(_ series: String) -> String {
        let safe = series.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return String(safe.prefix(80))
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
