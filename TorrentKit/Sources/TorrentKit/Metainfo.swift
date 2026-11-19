import Foundation

public enum TorrentError: Error, LocalizedError {
    case invalidTorrent(String)
    case invalidMagnet(String)
    case stopped
    case timeout
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTorrent(let s): return "Invalid torrent: \(s)"
        case .invalidMagnet(let s): return "Invalid magnet link: \(s)"
        case .stopped: return "Torrent stopped"
        case .timeout: return "Timed out"
        case .io(let s): return "I/O error: \(s)"
        }
    }
}

public struct TorrentFile: Hashable, Identifiable {
    public let index: Int
    /// Path components relative to the torrent root (the torrent name for multi-file torrents).
    public let path: [String]
    public let length: Int64
    /// Absolute offset of the file within the torrent's concatenated byte stream.
    public let offset: Int64
    /// BEP 47 padding file; never shown to the user.
    public let isPadding: Bool

    public var id: Int { index }
    public var displayPath: String { path.joined(separator: "/") }
    public var fileName: String { path.last ?? "file" }
    public var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
}

/// Parsed `info` dictionary of a v1 torrent.
public struct TorrentInfo {
    public let infoHash: Data
    public let name: String
    public let pieceLength: Int
    public let pieceHashes: [Data]
    public let files: [TorrentFile]
    public let totalLength: Int64
    /// Raw bencoded info dictionary (served to peers via ut_metadata and persisted for resume).
    public let rawInfo: Data
    /// True for single-file torrents (the file sits directly at the storage root).
    public let isSingleFile: Bool

    public var pieceCount: Int { pieceHashes.count }

    public init(rawInfo: Data) throws {
        let value: BValue
        do { value = try BDecoder.decode(rawInfo) } catch { throw TorrentError.invalidTorrent("info dictionary is not valid bencode") }
        guard case .dict = value else { throw TorrentError.invalidTorrent("info is not a dictionary") }
        self.rawInfo = rawInfo
        infoHash = SHA1.hash(rawInfo)

        guard let name = (value["name.utf-8"] ?? value["name"])?.string else { throw TorrentError.invalidTorrent("missing name") }
        self.name = TorrentInfo.sanitize(name)

        guard let pl = value["piece length"]?.int, pl > 0, pl <= 64 << 20 else { throw TorrentError.invalidTorrent("bad piece length") }
        pieceLength = Int(pl)

        guard let pieces = value["pieces"]?.data, pieces.count % 20 == 0, !pieces.isEmpty else {
            throw TorrentError.invalidTorrent("bad pieces field (v2-only torrents are not supported)")
        }
        pieceHashes = stride(from: 0, to: pieces.count, by: 20).map { pieces.subdata(in: pieces.startIndex + $0 ..< pieces.startIndex + $0 + 20) }

        var files: [TorrentFile] = []
        var offset: Int64 = 0
        if let list = value["files"]?.list {
            isSingleFile = false
            for (i, f) in list.enumerated() {
                guard let len = f["length"]?.int, len >= 0 else { throw TorrentError.invalidTorrent("file without length") }
                let rawPath = (f["path.utf-8"] ?? f["path"])?.list?.compactMap { $0.string } ?? []
                let path = rawPath.map(TorrentInfo.sanitize).filter { !$0.isEmpty }
                guard !path.isEmpty else { throw TorrentError.invalidTorrent("file without path") }
                let attr = f["attr"]?.string ?? ""
                let padding = attr.contains("p") || path.last!.hasPrefix("_____padding_file")
                files.append(TorrentFile(index: i, path: path, length: len, offset: offset, isPadding: padding))
                offset += len
            }
        } else {
            isSingleFile = true
            guard let len = value["length"]?.int, len >= 0 else { throw TorrentError.invalidTorrent("missing length") }
            files.append(TorrentFile(index: 0, path: [self.name], length: len, offset: 0, isPadding: false))
            offset = len
        }
        self.files = files
        totalLength = offset
        let expectedPieces = (totalLength + Int64(pieceLength) - 1) / Int64(pieceLength)
        guard expectedPieces == Int64(pieceHashes.count) else {
            throw TorrentError.invalidTorrent("piece count mismatch (\(pieceHashes.count) vs \(expectedPieces))")
        }
    }

    public func pieceSize(_ index: Int) -> Int {
        if index == pieceCount - 1 {
            let rem = Int(totalLength - Int64(index) * Int64(pieceLength))
            return rem
        }
        return pieceLength
    }

    /// Range of pieces overlapping the absolute byte range [start, end).
    public func pieces(from start: Int64, to end: Int64) -> ClosedRange<Int> {
        let first = Int(start / Int64(pieceLength))
        let last = Int(max(start, end - 1) / Int64(pieceLength))
        return min(first, pieceCount - 1)...min(last, pieceCount - 1)
    }

    public func pieces(for file: TorrentFile) -> ClosedRange<Int> {
        pieces(from: file.offset, to: file.offset + max(file.length, 1))
    }

    static func sanitize(_ component: String) -> String {
        var s = component.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        s = s.replacingOccurrences(of: "\0", with: "")
        if s == "." || s == ".." { s = "_" }
        return s
    }
}

/// Everything known about a torrent at the moment it is added.
public struct TorrentDescriptor {
    public let infoHash: Data
    public var displayName: String?
    public var trackers: [String]
    public var info: TorrentInfo?
    /// Original source so the app can persist it (magnet URI or .torrent file bytes).
    public var magnetURI: String?
    public var torrentData: Data?

    public var infoHashHex: String { infoHash.hexString }

    public static func parse(torrentData data: Data) throws -> TorrentDescriptor {
        var decoder = BDecoder(data)
        let root: BValue
        do { root = try decoder.decode() } catch { throw TorrentError.invalidTorrent("file is not a valid .torrent") }
        guard let range = decoder.infoRange else { throw TorrentError.invalidTorrent("missing info dictionary") }
        let rawInfo = data.subdata(in: data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound)
        let info = try TorrentInfo(rawInfo: rawInfo)
        var trackers: [String] = []
        if let tiers = root["announce-list"]?.list {
            for tier in tiers { for t in tier.list ?? [] { if let s = t.string { trackers.append(s) } } }
        }
        if let a = root["announce"]?.string { trackers.insert(a, at: 0) }
        return TorrentDescriptor(infoHash: info.infoHash, displayName: info.name, trackers: unique(trackers),
                                 info: info, magnetURI: nil, torrentData: data)
    }

    /// Parses `magnet:?xt=urn:btih:...` links. A bare 40-char hex or 32-char base32 info-hash is also accepted.
    public static func parse(magnet input: String) throws -> TorrentDescriptor {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = parseInfoHash(trimmed) {
            return TorrentDescriptor(infoHash: hash, displayName: nil, trackers: [], info: nil,
                                     magnetURI: "magnet:?xt=urn:btih:\(hash.hexString)", torrentData: nil)
        }
        guard trimmed.lowercased().hasPrefix("magnet:"), let q = trimmed.firstIndex(of: "?") else {
            throw TorrentError.invalidMagnet("expected a magnet: link")
        }
        var hash: Data?
        var name: String?
        var trackers: [String] = []
        for pair in trimmed[trimmed.index(after: q)...].split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].lowercased()
            let rawValue = String(pair[pair.index(after: eq)...])
            let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            if key == "xt" || key.hasPrefix("xt.") {
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") {
                    hash = parseInfoHash(String(value.dropFirst("urn:btih:".count)))
                }
            } else if key == "dn" {
                name = value
            } else if key == "tr" || key.hasPrefix("tr.") {
                trackers.append(rawValue.removingPercentEncoding ?? rawValue)
            }
        }
        guard let infoHash = hash else { throw TorrentError.invalidMagnet("no BitTorrent v1 info-hash (urn:btih) found") }
        return TorrentDescriptor(infoHash: infoHash, displayName: name, trackers: unique(trackers), info: nil,
                                 magnetURI: trimmed, torrentData: nil)
    }

    static func parseInfoHash(_ s: String) -> Data? {
        if s.count == 40, let d = Data(hex: s) { return d }
        if s.count == 32, let d = Data(base32: s), d.count == 20 { return d }
        return nil
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
