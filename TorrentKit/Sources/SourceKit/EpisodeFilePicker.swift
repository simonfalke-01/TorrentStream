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
    ///   - special: the episode is an OVA or special (`SourceMatcher.isSideEntry`), found among a pack's specials.
    public static func pick(_ files: [File], season: Int, episode: Int, absolute: Int, seasonEpisodes: Int?,
                            isMovie: Bool = false, special: Bool = false) -> Int? {
        if special && !isMovie { return pickSpecial(files, episode: episode, count: seasonEpisodes) }
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

    private static let notEpisode =
        #"(?i)\b(nc ?op|nc ?ed|creditless|op\d*|ed\d*|pv\d*|cm\d*|sample|preview|trailer|teaser|menu)\b"#
    private static let specialMark = #"(?i)\b(ovas?|oads?|sp\s?\d*|specials?|s00(e\d+)?|extras?|bonus|omake)\b"#

    /// An OVA or special: in a pack of the series, among the files marked as such ("Specials/", "OVA 2", "S00E02");
    /// in a pack of only the specials, any of its videos. Matched by number, else by order when the count fits.
    static func pickSpecial(_ files: [File], episode: Int, count: Int?) -> Int? {
        let vids = files.filter { f in
            let ext = (f.path as NSString).pathExtension.lowercased()
            guard videoExtensions.contains(ext) else { return false }
            let name = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
            return name.range(of: notEpisode, options: .regularExpression) == nil
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let marked = vids.filter { f in
            var parts = f.path.split(separator: "/").map(String.init)
            // The top folder is the release's name, which says what the whole pack holds.
            if parts.count > 1 { parts.removeFirst() }
            let info = ReleaseName.parse(parts.last ?? f.path)
            return info.isSpecial || info.season == 0
                || parts.contains { $0.range(of: specialMark, options: .regularExpression) != nil }
        }
        let pool = marked.isEmpty ? vids : marked
        if pool.count == 1 { return pool[0].index }
        let numbered = pool.filter { ReleaseName.parse(($0.path as NSString).lastPathComponent).episode == episode }
        if let f = numbered.max(by: { $0.length < $1.length }) { return f.index }
        if let count, pool.count == count, episode >= 1, episode <= count { return pool[episode - 1].index }
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
