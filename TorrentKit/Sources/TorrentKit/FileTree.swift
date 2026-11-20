import Foundation

/// A folder of a torrent's file hierarchy, restricted to the files a screen cares about (for example videos).
public struct FileFolder: Identifiable, Hashable {
    /// Path components from the torrent root. Empty for the root.
    public let path: [String]
    public let folders: [FileFolder]
    /// Direct children, in natural order ("2" before "10").
    public let files: [TorrentFile]

    public var id: String { path.joined(separator: "/") }
    public var name: String { path.last ?? "" }

    /// Every file in this folder and its subfolders, in natural order.
    public var allFiles: [TorrentFile] { files + folders.flatMap(\.allFiles) }

    public func folder(id: String) -> FileFolder? {
        if self.id == id { return self }
        for f in folders { if let found = f.folder(id: id) { return found } }
        return nil
    }
}

public enum FileTree {
    /// Builds the hierarchy of `files` that pass `include`. Folders holding no included files are dropped, and
    /// a folder whose only content is one subfolder is merged into it, so there is never a screen with a single row
    /// to tap through.
    public static func build(_ files: [TorrentFile], include: (TorrentFile) -> Bool) -> FileFolder {
        let selected = files.filter { !$0.isPadding && include($0) }
        return collapse(node(path: [], files: selected))
    }

    private static func node(path: [String], files: [TorrentFile]) -> FileFolder {
        let depth = path.count
        var direct: [TorrentFile] = []
        var children: [String: [TorrentFile]] = [:]
        for f in files {
            if f.path.count == depth + 1 { direct.append(f) } else { children[f.path[depth], default: []].append(f) }
        }
        let folders = children.keys.sorted(by: naturalOrder).map { node(path: path + [$0], files: children[$0]!) }
        return FileFolder(path: path, folders: folders, files: direct.sorted { naturalOrder($0.fileName, $1.fileName) })
    }

    private static func collapse(_ f: FileFolder) -> FileFolder {
        if f.files.isEmpty && f.folders.count == 1 { return collapse(f.folders[0]) }
        return FileFolder(path: f.path, folders: f.folders.map(collapse), files: f.files)
    }

    /// Finder-style ordering: case-insensitive, with numbers compared by value.
    public static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .numeric]) == .orderedAscending
    }
}

public enum MediaTitle {
    /// "[SubsPlease] Frieren - 03 (1080p) [F02B9CA3].mkv" becomes "Frieren - 03 (1080p)".
    /// Strips the extension, a leading release-group tag and a trailing checksum, and turns dots or underscores used
    /// as word separators into spaces.
    public static func clean(_ fileName: String) -> String {
        var s = fileName
        let ext = (s as NSString).pathExtension
        if !ext.isEmpty && ext.count <= 5 { s = (s as NSString).deletingPathExtension }

        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { s = rest }
        }
        if let r = s.range(of: #"\s*[\[(][0-9A-Fa-f]{8}[\])]$"#, options: .regularExpression) {
            let rest = String(s[..<r.lowerBound])
            if !rest.isEmpty { s = rest }
        }
        if !s.contains(" ") {
            let separators = s.filter { $0 == "." || $0 == "_" }.count
            if separators >= 2 {
                s = s.replacingOccurrences(of: "_", with: " ")
                // Keep the dots in "5.1" or "H.264": protect them, replace the rest, then restore.
                let mark = "\u{1}"
                s = s.replacingOccurrences(of: #"(?<![0-9])([0-9])\.([0-9])(?![0-9])"#, with: "$1\(mark)$2", options: .regularExpression)
                s = s.replacingOccurrences(of: #"\b([Hh])\.(26[456])\b"#, with: "$1\(mark)$2", options: .regularExpression)
                s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: mark, with: ".")
            }
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fileName : trimmed
    }
}
