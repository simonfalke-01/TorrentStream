import Foundation
import CatalogKit

/// Finds the file for one episode inside a release that holds many.
public enum EpisodeFilePicker {
    public struct File: Sendable {
        public var index: Int
        public var path: String
        public var length: Int64

        public init(index: Int, path: String, length: Int64) {
            self.index = index
            self.path = path
            self.length = length
        }
    }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv"]
    private static let extras =
        #"(?i)\b(nc ?op|nc ?ed|creditless|op\d*|ed\d*|pv\d*|cm\d*|sample|preview|trailer|teaser|menu|sp\d*|specials?|extras?|bonus|ova|oad|omake|recap)\b"#

    /// Video files that are part of the show, in natural order.
    public static func videos(_ files: [File]) -> [File] {
        files.filter { f in
            let ext = (f.path as NSString).pathExtension.lowercased()
            guard videoExtensions.contains(ext) else { return false }
            var parts = f.path.split(separator: "/").map(String.init)
            // The top folder is the release name, which may mention its extras.
            if parts.count > 1 { parts.removeFirst() }
            if let last = parts.popLast() { parts.append((last as NSString).deletingPathExtension) }
            return !parts.contains { $0.range(of: extras, options: .regularExpression) != nil }
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The file playing an episode, or nil when none can be told apart.
    /// - Parameters:
    ///   - season: Season number in the catalog.
    ///   - episode: Episode number within the season.
    ///   - absolute: Episode number counted from the start of the show.
    ///   - seasonEpisodes: Episodes in the season, for packs whose files carry no numbers.
    public static func pick(_ files: [File], season: Int, episode: Int, absolute: Int, seasonEpisodes: Int?,
                            isMovie: Bool = false) -> Int? {
        let vids = videos(files)
        if isMovie { return (vids.isEmpty ? files : vids).max { $0.length < $1.length }?.index }
        if vids.count == 1 { return vids[0].index }

        var exact: [File] = [], loose: [File] = []
        for f in vids {
            let parts = f.path.split(separator: "/").map(String.init)
            let info = ReleaseName.parse(parts.last ?? f.path)
            guard let n = info.episode else { continue }
            let folderSeason = parts.dropLast().reversed().lazy.compactMap(folderSeasonNumber).first
            let fileSeason = info.season ?? folderSeason
            if let fs = fileSeason {
                if fs == season, n == episode || n == absolute { exact.append(f) }
            } else if n == absolute {
                exact.append(f)
            } else if n == episode {
                loose.append(f)
            }
        }
        if let f = (exact.isEmpty ? loose : exact).max(by: { $0.length < $1.length }) { return f.index }

        // A pack of one season whose files are only numbered by order.
        if let count = seasonEpisodes, vids.count == count, episode >= 1, episode <= count { return vids[episode - 1].index }
        return nil
    }

    /// "Season 2", "S02", "2nd Season" in a folder name.
    static func folderSeasonNumber(_ name: String) -> Int? {
        let patterns = [#"(?i)\bseason\s*0*(\d{1,2})\b"#, #"(?i)\bs0*(\d{1,2})\b"#, #"(?i)\b(\d{1,2})(?:st|nd|rd|th)\s+season\b"#]
        for p in patterns {
            if let v = ReleaseTraits.first(p, in: name).flatMap(Int.init) { return v }
        }
        return nil
    }
}
