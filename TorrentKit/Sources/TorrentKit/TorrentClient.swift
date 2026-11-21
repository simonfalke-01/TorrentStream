import Foundation

/// Entry point of the engine: owns torrents, the DHT node and the local streaming server.
public final class TorrentClient {
    public static let defaultTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "https://tracker.gbitt.info:443/announce",
    ]

    public let downloadDirectory: URL
    let useDHT: Bool
    private let extraTrackers: [String]
    let peerID: Data
    let dht: DHT?
    private var server: StreamServer!
    private let lock = NSLock()
    private var torrentsByHash: [String: Torrent] = [:]
    private var order: [String] = []
    /// Torrents whose player is waiting on data; the others hold back so the phone's bandwidth goes there.
    private var starvingTorrents = Set<ObjectIdentifier>()
    /// Single network thread shared by every torrent's peer connections.
    let loop = EventLoop()

    public init(downloadDirectory: URL, useDHT: Bool = true, extraTrackers: [String] = TorrentClient.defaultTrackers,
                streamingPort: UInt16 = 0) {
        Net.ignoreSIGPIPE()
        self.downloadDirectory = downloadDirectory
        self.useDHT = useDHT
        self.extraTrackers = extraTrackers
        var id = Data("-TS0100-".utf8)
        let alnum = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        for _ in 0..<12 { id.append(alnum.randomElement()!) }
        peerID = id
        dht = useDHT ? DHT() : nil
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        server = StreamServer(client: self, preferredPort: streamingPort)
        dht?.start()
        try? server.ensureRunning()
    }

    deinit { loop.stop() }

    public var torrents: [Torrent] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { torrentsByHash[$0] }
    }

    public func torrent(infoHashHex: String) -> Torrent? {
        lock.lock(); defer { lock.unlock() }
        return torrentsByHash[infoHashHex]
    }

    /// Adds a magnet link (or bare info-hash). Returns the existing torrent if already added.
    @discardableResult
    public func add(magnet: String) throws -> Torrent {
        try add(descriptor: TorrentDescriptor.parse(magnet: magnet))
    }

    /// Adds a .torrent file. Returns the existing torrent if already added.
    @discardableResult
    public func add(torrentData: Data) throws -> Torrent {
        try add(descriptor: TorrentDescriptor.parse(torrentData: torrentData))
    }

    @discardableResult
    public func add(descriptor: TorrentDescriptor) throws -> Torrent {
        lock.lock()
        if let existing = torrentsByHash[descriptor.infoHashHex] { lock.unlock(); return existing }
        let dir = downloadDirectory.appendingPathComponent(descriptor.infoHashHex, isDirectory: true)
        let t = Torrent(descriptor: descriptor, client: self, directory: dir, peerID: peerID)
        torrentsByHash[descriptor.infoHashHex] = t
        order.append(descriptor.infoHashHex)
        lock.unlock()
        t.start(extraTrackers: extraTrackers, useDHT: useDHT)
        return t
    }

    public func remove(_ torrent: Torrent, deleteData: Bool) {
        lock.lock()
        torrentsByHash[torrent.infoHashHex] = nil
        order.removeAll { $0 == torrent.infoHashHex }
        lock.unlock()
        setStarving(torrent, false)
        torrent.stop()
        if deleteData { try? FileManager.default.removeItem(at: torrent.directory) }
    }

    /// Re-creates the loopback listener if the OS tore it down (e.g. after the app was suspended).
    public func ensureStreamingServer() {
        try? server.ensureRunning()
    }

    public var streamingPort: UInt16 { server.port }

    /// HTTP URL that any media player can use to stream (and seek within) a file of the torrent.
    public func streamURL(for torrent: Torrent, fileIndex: Int, fileName: String) -> URL {
        ensureStreamingServer()
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let name = fileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
        return URL(string: "http://127.0.0.1:\(server.port)/stream/\(torrent.infoHashHex)/\(fileIndex)/\(name)")!
    }

    public func shutdown() {
        torrents.forEach { $0.stop() }
        dht?.stop()
        server.stop()
        // Let the torrents' posted cleanup run first.
        loop.post { [loop] in loop.stop() }
    }

    func setStarving(_ torrent: Torrent, _ starving: Bool) {
        lock.lock(); defer { lock.unlock() }
        if starving { starvingTorrents.insert(ObjectIdentifier(torrent)) } else { starvingTorrents.remove(ObjectIdentifier(torrent)) }
    }

    /// Whether a torrent other than `torrent` has a player waiting on data.
    func otherTorrentStarving(excluding torrent: Torrent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let me = ObjectIdentifier(torrent)
        return starvingTorrents.contains { $0 != me }
    }
}

public enum MediaKind {
    case video, audio, subtitle, other

    public init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mts", "wmv", "flv", "mpg", "mpeg", "3gp", "ogv", "vob", "divx", "rmvb":
            self = .video
        case "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "wma", "alac", "ape":
            self = .audio
        case "srt", "vtt", "ass", "ssa", "sub", "idx", "smi":
            self = .subtitle
        default:
            self = .other
        }
    }

    public var isPlayable: Bool { self == .video || self == .audio }
}
