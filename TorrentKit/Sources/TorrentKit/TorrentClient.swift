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
    private(set) var server: StreamServer!
    private let lock = NSLock()
    private var torrentsByHash: [String: Torrent] = [:]
    private var order: [String] = []
    /// Torrents whose player is waiting on data; the others hold back so the phone's bandwidth goes there.
    private var starvingTorrents = Set<ObjectIdentifier>()
    /// Single network thread shared by every torrent's peer connections.
    let loop = EventLoop()
    /// Accepts peers that connect to us.
    private var listener: PeerListener?
    /// Forwards a public port on the home router to the listener.
    private var mapper: PortMapper?
    private var skipsAttachments = true

    /// When a player opens a Matroska file whose attachments (embedded subtitle fonts, often several megabytes before
    /// the first video frame) haven't been downloaded yet, they are served as an EBML Void element instead of being
    /// waited for: the first frame comes seconds sooner, but styled subtitles of that playback use fallback fonts.
    /// Attachments already on disk (a prefetched episode, a replay after 30 s) are served as they are. Default true.
    public var skipsUndownloadedAttachments: Bool {
        get { lock.lock(); defer { lock.unlock() }; return skipsAttachments }
        set { lock.lock(); skipsAttachments = newValue; lock.unlock() }
    }

    public init(downloadDirectory: URL, useDHT: Bool = true, extraTrackers: [String] = TorrentClient.defaultTrackers,
                streamingPort: UInt16 = 0) {
        Net.ignoreSIGPIPE()
        Net.raiseFileLimit()
        self.downloadDirectory = downloadDirectory
        self.useDHT = useDHT
        self.extraTrackers = extraTrackers
        var id = Data("-TS0100-".utf8)
        let alnum = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        for _ in 0..<12 { id.append(alnum.randomElement()!) }
        peerID = id
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        dht = useDHT ? DHT(stateFile: downloadDirectory.appendingPathComponent("dht-nodes.bin")) : nil
        server = StreamServer(client: self, preferredPort: streamingPort)
        dht?.start()
        try? server.ensureRunning()
        startListening()
    }

    /// The port peers connect to: the one the router forwards, else the one we listen on.
    var announcePort: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return mapper?.externalPort ?? listener?.port
    }

    /// The local port peers can connect to, if listening.
    public var listeningPort: UInt16? { lock.lock(); defer { lock.unlock() }; return listener?.port }

    /// The public port the router forwards to us, once mapped.
    public var forwardedPort: UInt16? { lock.lock(); defer { lock.unlock() }; return mapper?.externalPort }

    private func startListening() {
        let portFile = downloadDirectory.appendingPathComponent("peer-port")
        let saved = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { UInt16($0) } ?? 0
        let l = PeerListener(client: self, loop: loop)
        guard let port = l.open(preferred: saved) else { log("listener: no port"); return }
        if port != saved { try? String(port).write(to: portFile, atomically: true, encoding: .utf8) }
        let m = PortMapper(internalPort: port) { _ in }
        lock.lock()
        listener = l
        mapper = m
        lock.unlock()
        dht?.announcePort = { [weak self] in self?.announcePort }
        log("listener: peers connect on port \(port)")
        if useDHT { m.refresh() }
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

    /// Adds a magnet link (or bare info-hash). Returns the existing torrent if already added. With `paused`, the
    /// torrent stays off the network (no trackers, DHT or peers) until `resume()` or playback.
    @discardableResult
    public func add(magnet: String, paused: Bool = false) throws -> Torrent {
        try add(descriptor: TorrentDescriptor.parse(magnet: magnet), paused: paused)
    }

    /// Adds a .torrent file. Returns the existing torrent if already added, giving it the file's metainfo if it was
    /// added by magnet and has none yet.
    @discardableResult
    public func add(torrentData: Data, paused: Bool = false) throws -> Torrent {
        try add(descriptor: TorrentDescriptor.parse(torrentData: torrentData), paused: paused)
    }

    @discardableResult
    public func add(descriptor: TorrentDescriptor, paused: Bool = false) throws -> Torrent {
        lock.lock()
        if let existing = torrentsByHash[descriptor.infoHashHex] {
            lock.unlock()
            if let info = descriptor.info, existing.torrentInfo == nil { existing.installInfo(info) }
            return existing
        }
        let dir = downloadDirectory.appendingPathComponent(descriptor.infoHashHex, isDirectory: true)
        let t = Torrent(descriptor: descriptor, client: self, directory: dir, peerID: peerID)
        torrentsByHash[descriptor.infoHashHex] = t
        order.append(descriptor.infoHashHex)
        lock.unlock()
        t.start(extraTrackers: extraTrackers, useDHT: useDHT, paused: paused)
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

    /// Makes sure the loopback listener answers, re-creating it on the same port if the OS tore it down (iOS reclaims
    /// the listening sockets of suspended apps). Cheap when it worked moments ago.
    public func ensureStreamingServer() {
        server.validate()
    }

    private var backgroundedAt: Date?

    /// Call when the app moves to the background: saves progress, the peers worth dialing again and DHT nodes, in
    /// case the app is not resumed.
    public func applicationDidEnterBackground() {
        lock.lock(); backgroundedAt = Date(); lock.unlock()
        torrents.forEach { $0.saveState() }
        dht?.save()
    }

    /// Call before `applicationWillEnterForeground` when the app kept running the whole time it was in the background:
    /// its peers are still connected and are kept.
    public func stayedAwakeInBackground() {
        lock.lock(); backgroundedAt = nil; lock.unlock()
    }

    /// Call when the app becomes active again: brings the streaming server back (same port, so the player's URLs
    /// keep working) and replaces peer connections that died during the suspension.
    public func applicationWillEnterForeground() {
        server.validate(maxAge: 0)
        lock.lock()
        let suspended = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        lock.unlock()
        torrents.forEach { $0.reconnectAfterSuspension(suspended: suspended) }
        // The listener comes back if iOS reclaimed it; the router mapping is renewed if it lapsed (or local network
        // access was just allowed).
        if let listener { loop.post { if listener.fd < 0 { listener.reopen() } } }
        if useDHT { mapper?.refresh() }
    }

    public var streamingPort: UInt16 { server.port }

    /// Changes each time the streaming listener is re-created (iOS reclaimed it during a suspension). The port stays
    /// the same whenever possible, but a player connection opened before the change is dead: compare this to the value
    /// seen when the stream was opened to decide whether to reopen it.
    public var streamingServerGeneration: Int { server.listenerGeneration }

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
        if let listener { loop.post { listener.close() } }
        // Let the torrents' posted cleanup run first.
        loop.post { [loop] in loop.stop() }
    }

    func setStarving(_ torrent: Torrent, _ starving: Bool) {
        lock.lock(); defer { lock.unlock() }
        if starving { starvingTorrents.insert(ObjectIdentifier(torrent)) } else { starvingTorrents.remove(ObjectIdentifier(torrent)) }
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
