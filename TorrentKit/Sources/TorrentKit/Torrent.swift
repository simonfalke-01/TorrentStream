import Foundation

/// Download state of a piece that isn't verified yet. Blocks are written to disk as they arrive, so readers can use
/// them before the whole piece is in; the piece is hashed from disk once its last block landed.
final class PieceProgress {
    let index: Int
    let size: Int
    let blockCount: Int
    var received: [Bool]
    var receivedCount = 0
    private(set) var requesters: [[ObjectIdentifier]]
    var requestedAt: [TimeInterval]
    /// When the earliest outstanding request for each block should have been answered.
    var eta: [TimeInterval]
    /// Peers that delivered blocks of this piece, blamed if it fails the hash check.
    var sources = Set<PeerAddress>()
    var blockSources: [PeerAddress?]
    /// After a failed check with blocks from several peers, the next attempt comes from one peer: it either passes
    /// (and the bad block's sender is found by comparison) or that peer alone is to blame.
    var owner: ObjectIdentifier?
    var verifying = false
    /// Outstanding requests beyond the first one for each block: races.
    private(set) var extraRequests = 0

    init(index: Int, size: Int) {
        self.index = index
        self.size = size
        blockCount = (size + blockSize - 1) / blockSize
        received = Array(repeating: false, count: blockCount)
        blockSources = Array(repeating: nil, count: blockCount)
        requesters = Array(repeating: [], count: blockCount)
        requestedAt = Array(repeating: 0, count: blockCount)
        eta = Array(repeating: 0, count: blockCount)
    }

    func blockLength(_ b: Int) -> Int { min(blockSize, size - b * blockSize) }

    func addRequester(_ b: Int, _ peer: ObjectIdentifier) {
        if !requesters[b].isEmpty { extraRequests += 1 }
        requesters[b].append(peer)
    }

    func clearRequesters(_ b: Int) {
        extraRequests -= max(0, requesters[b].count - 1)
        requesters[b] = []
    }

    func release(_ b: Int, peer: ObjectIdentifier) {
        guard b >= 0 && b < blockCount else { return }
        let before = requesters[b].count
        requesters[b].removeAll { $0 == peer }
        extraRequests -= max(0, before - 1) - max(0, requesters[b].count - 1)
    }
}

/// One connected peer, for display.
public struct PeerSnapshot: Hashable, Sendable {
    public let address: String
    /// What the peer's software calls itself; may be empty.
    public let client: String
    /// Bytes per second it is sending.
    public let downloadRate: Double
    /// How much of the torrent it has, 0...1.
    public let progress: Double
    /// Not sending to us right now.
    public let isChoking: Bool
    /// It connected to us.
    public let isIncoming: Bool
}

public struct FileStatus: Identifiable, Hashable {
    public let file: TorrentFile
    public let downloadedBytes: Int64
    public let wanted: Bool
    public var id: Int { file.index }
    public var progress: Double { file.length == 0 ? 1 : Double(downloadedBytes) / Double(file.length) }
    public var isComplete: Bool { downloadedBytes >= file.length }
    /// Being fetched in the background (wanted, not finished yet).
    public var isDownloading: Bool { wanted && !isComplete }
}

public struct TorrentStatus {
    public enum Phase: Equatable {
        case fetchingMetadata
        case ready
        case failed(String)
    }

    public let infoHashHex: String
    public let name: String
    public let phase: Phase
    public let isPaused: Bool
    public let files: [FileStatus]
    public let totalLength: Int64
    public let downloadedBytes: Int64
    public let connectedPeers: Int
    public let knownPeers: Int
    public let downloadRate: Double
    public let metadataProgress: Double

    public var progress: Double { totalLength == 0 ? 0 : Double(downloadedBytes) / Double(totalLength) }
    public var isComplete: Bool { totalLength > 0 && downloadedBytes >= totalLength }
    /// True when some files are queued for download and not finished yet.
    public var hasActiveDownloads: Bool { files.contains { $0.isDownloading && !$0.file.isPadding } }
}

public struct StreamStatus {
    /// Position of the playback reader inside the file (nil when nothing is reading).
    public let readerOffset: Int64?
    /// Contiguous downloaded bytes ahead of the reader.
    public let bufferedAhead: Int64
    public let fileProgress: Double
    public let downloadRate: Double
    public let connectedPeers: Int
}

/// A single torrent: peer swarm, block scheduling tuned for streaming, storage and blocking reads.
public final class Torrent {
    /// How badly a byte range is needed (see `want`).
    public enum RangeUrgency: Int, Sendable, Comparable {
        case background, soon, now
        public static func < (a: RangeUrgency, b: RangeUrgency) -> Bool { a.rawValue < b.rawValue }
    }

    public let infoHash: Data
    public var infoHashHex: String { infoHash.hexString }
    public let descriptor: TorrentDescriptor
    let peerID: Data
    let directory: URL
    weak var client: TorrentClient?
    let loop: EventLoop

    let lock = NSCondition()

    // MARK: state guarded by `lock`
    private(set) var info: TorrentInfo?
    var storage: Storage?
    var have: [Bool] = []
    var haveCount = 0
    var inProgress: [Int: PieceProgress] = [:]
    var wantedFiles = Set<Int>()
    var streamingFiles = Set<Int>()
    /// Bytes fetched past each reader of a file, beyond the urgent window. Missing = `defaultReadahead`.
    var readahead: [Int: Int64] = [:]
    /// File whose start (and container index at the end) is loaded ahead of playback, and how many bytes of it.
    var prefetchTarget: (fileIndex: Int, bytes: Int64)?

    /// `updated` is when the reader started or last moved, so the latest seek ranks first.
    struct Reader {
        var fileIndex: Int; var offset: Int64; var updated: TimeInterval; var orderedAt: Int64
        /// Where and when it started reading (a seek starts a new reader).
        var start: Int64 = 0
        var startedAt: TimeInterval = 0
        /// Until when its player is estimated to have plenty buffered (see `Torrent.settledUntilLocked`); 0: it may be
        /// waiting on data.
        var settledUntil: TimeInterval = 0
    }
    var readers: [UUID: Reader] = [:]

    struct Want { let fileIndex: Int; let ranges: [Range<Int64>]; let urgency: RangeUrgency; let seq: Int }
    var wants: [String: Want] = [:]
    var wantSeq = 0

    /// Byte ranges to fetch, most urgent first (see `rebuildOrder`).
    var spans: [Span] = []
    /// Layouts of the Matroska files being streamed or prefetched, by file index.
    var containers: [Int: ContainerState] = [:]
    var orderDirty = true
    /// Requests were released, so span cursors may have skipped blocks that are free again.
    var cursorsStale = false
    var starving = false

    final class BlockWaiter {
        let start: Int64
        let end: Int64
        let fileIndex: Int
        let fileOffset: Int64
        var continuation: CheckedContinuation<Data?, Never>?
        init(start: Int64, end: Int64, fileIndex: Int, fileOffset: Int64) {
            self.start = start; self.end = end; self.fileIndex = fileIndex; self.fileOffset = fileOffset
        }
    }
    var blockWaiters: [ObjectIdentifier: BlockWaiter] = [:]

    var peers: [PeerAddress: PeerConnection] = [:]
    var peersByID: [ObjectIdentifier: PeerConnection] = [:]
    var handshaked = Set<ObjectIdentifier>()
    var knownPeers = Set<PeerAddress>()
    var peerQueue: [PeerAddress] = []
    var retryAfter: [PeerAddress: TimeInterval] = [:]
    var banned = Set<PeerAddress>()
    /// Per-block hashes and senders of failed attempts at pieces, compared with the good data once a piece passes to
    /// find who sent the bad block when several peers contributed.
    var failedAttempts: [Int: [[(PeerAddress?, Data)]]] = [:]
    /// Loop thread: closes requested while the lock was held.
    var deferredCloses: [(PeerConnection, String)] = []
    var rescheduleQueued = false
    var connectQueued = false
    /// The last tick found nothing to do and asked for the slow interval.
    var tickingSlowly = false

    var metadataSize: Int?
    var metadataPieces: [Data?] = []
    var metadataRequestedAt: [Int: Date] = [:]

    var downloadedTotal: Int64 = 0
    /// Bytes of blocks received for the first time (diagnostics: the rest of `downloadedTotal` was raced twice).
    var newBlockBytes: Int64 = 0
    /// Diagnostics: bytes of blocks received again while still asked for, after a cancel, unasked; and blocks that
    /// arrived first despite a cancel.
    var dupBytes: [Int64] = [0, 0, 0, 0]
    var bytesSinceTick = 0
    var rateMeter = RateMeter()
    var currentRate: Double = 0
    var failure: String?
    var stopped = false
    var paused = false
    /// Trackers were started (a torrent added paused starts them on first resume).
    var networkStarted = true
    var resumeDirty = false
    var lastResumeSave = Date()
    var lastDHTLookup = Date.distantPast
    /// When the app last came back from suspension.
    var resumedAt: TimeInterval = 0
    var lastSlowTick: TimeInterval = 0
    var lastRateSample: TimeInterval = 0
    var trackers: [TrackerAnnouncer] = []
    let hashQueue: DispatchQueue

    // Milestones, for diagnostics.
    let createdAt = Date.timeIntervalSinceReferenceDate
    var firstConnectAt: TimeInterval?
    var firstUnchokeAt: TimeInterval?
    var firstBlockAt: TimeInterval?
    /// Diagnostics: the ramp log follows the last start or seek for a while.
    var lastRampLog: TimeInterval = 0
    var lastActivityAt = Date.timeIntervalSinceReferenceDate
    var lastActivityStart = Date.timeIntervalSinceReferenceDate
    var activityBytes: Int64 = 0

    /// Connected peers. A loop thread multiplexes them, so this costs memory, not threads.
    var maxPeers = 200
    /// Downloads upload to the peers that send to them most (and one at random), as BitTorrent clients reward: most
    /// leechers only unchoke peers that upload. Streaming keeps the uplink free and doesn't.
    var reciprocates = false
    /// Pieces verified since the last tick, announced to peers while reciprocating.
    var verifiedForHave: [Int] = []
    var lastChokeRound: TimeInterval = 0
    var optimisticPeer: ObjectIdentifier?
    var lastOptimisticAt: TimeInterval = 0
    var uploadedTotal: Int64 = 0
    static let uploadSlots = 8
    static let chokeRoundInterval: TimeInterval = 10
    static let optimisticInterval: TimeInterval = 30
    static let streamingMaxPeers = 200
    static let downloadMaxPeers = 300
    /// Tracker lists are mostly unreachable peers, so many connection attempts run at once, and given up quickly: a
    /// live peer answers a SYN within a round trip (one retransmission fits).
    var maxConnecting = 240
    static let connectTimeout: TimeInterval = 3
    static let handshakeTimeout: TimeInterval = 6
    /// Bytes past a reader that are fetched before anything else, block by block, and raced between peers early.
    var criticalBytes: Int64 = 2 * 1024 * 1024
    /// Past the critical bytes, this much more of each reader is fetched next (also at block level).
    var soonBytes: Int64 = 16 * 1024 * 1024
    /// End of a media file fetched early: MKV cues and MP4 moov atoms usually live there.
    static let indexTailBytes: Int64 = 2 * 1024 * 1024
    /// The part of it fetched right after what the player waits on.
    static let indexTailUrgentBytes: Int64 = 256 * 1024
    /// Blocks at the start of a jump that go to several peers right away (see `Span.raceHead`).
    static let raceHeadBlocks = 2
    /// Most peers asked for the same urgent block.
    static let maxRacers = 3
    /// Peers asked at once for the block a reader is blocked on.
    static let maxHeadRacers = 6
    /// Most blocks requested from more than one peer at once besides the ones readers are blocked on: the peers share
    /// one link, so beyond a few hedges against a stalled peer, races only take bandwidth from the blocks the player
    /// needs next.
    static let maxHedgedBlocks = 32
    /// How long a peer with the fast extension has to answer a cancel before the block is asked of others.
    static let cancelAnswerTimeout: TimeInterval = 2
    /// Urgent blocks within this many bytes past a reader's head block stay queued at a peer the head is raced to.
    static let headNearBytes: Int64 = 256 * 1024
    /// How often the block a reader is blocked on goes to one more peer while nobody delivers it on time.
    static let headRaceStep: TimeInterval = 0.2
    /// How late past its deadline (the swarm reaching it) a block the player waits on may arrive before it is raced.
    static let deadlineSlack: TimeInterval = 0.25
    /// How long before the swarm reaches it a peer slower than the fastest must be expected to deliver a block.
    static let slowPeerMargin: TimeInterval = 0.5
    /// Scheduler tuning, in seconds of a peer's (or the swarm's) download rate: urgent blocks one peer holds, its queue
    /// past the round trip, and everything requested from all peers past the bytes in transit.
    static let urgentShareSeconds = 0.5
    static let queueSeconds = 0.15
    static let inFlightSeconds = 0.15
    static let minInFlightBlocks = 96
    /// Per-peer request queue for a torrent nothing plays from: seconds of the peer's rate, and a floor.
    static let downloadQueueSeconds = 3.0
    static let downloadMinQueue = 64

    init(descriptor: TorrentDescriptor, client: TorrentClient, directory: URL, peerID: Data) {
        self.descriptor = descriptor
        infoHash = descriptor.infoHash
        self.client = client
        self.loop = client.loop
        self.directory = directory
        self.peerID = peerID
        hashQueue = DispatchQueue(label: "torrent-hash", qos: .userInitiated)
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    /// Downloading in full: upload in return and keep more peers. Off for streaming.
    public func setReciprocating(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard reciprocates != on else { return }
        reciprocates = on
        maxPeers = on ? Torrent.downloadMaxPeers : Torrent.streamingMaxPeers
        lastChokeRound = 0
        verifiedForHave.removeAll()
        tickSoonLocked()
    }

    /// Lock held: whether a peer that just became interested can be unchoked before the next round.
    func hasFreeUploadSlotLocked() -> Bool {
        guard reciprocates, !paused else { return false }
        return handshaked.compactMap { peersByID[$0] }.filter { !$0.amChoking }.count < Torrent.uploadSlots + 1
    }

    /// Incoming connections allowed past `maxPeers`: they cost nothing to find and often send the most.
    static let incomingHeadroom = 30

    /// Loop thread: a peer connected to our listener for this torrent. Returns false to turn it away.
    func acceptIncoming(fd: Int32, address: PeerAddress, received: [UInt8]) -> Bool {
        lock.lock()
        guard !stopped, !paused, peers[address] == nil, !banned.contains(address),
              peers.count < maxPeers + Torrent.incomingHeadroom else { lock.unlock(); return false }
        let conn = connectLocked(address)
        lock.unlock()
        conn.adoptIncoming(fd: fd, received: received, loop: loop)
        return true
    }

    /// Lock held: who to choke or unchoke now. Without reciprocating, everyone unchoked is choked again.
    private func chokeRoundLocked(now: TimeInterval) -> [(PeerConnection, Bool)] {
        let active = handshaked.compactMap { peersByID[$0] }.filter(\.isActive)
        var unchoke = Set<ObjectIdentifier>()
        if reciprocates {
            guard now - lastChokeRound >= Torrent.chokeRoundInterval else { return [] }
            lastChokeRound = now
            let interested = active.filter(\.peerInterested)
            for p in interested.sorted(by: { $0.rate > $1.rate }).prefix(Torrent.uploadSlots) { unchoke.insert(ObjectIdentifier(p)) }
            let stillThere = optimisticPeer.map { id in interested.contains { ObjectIdentifier($0) == id } } ?? false
            if !stillThere || now - lastOptimisticAt >= Torrent.optimisticInterval {
                optimisticPeer = interested.filter { !unchoke.contains(ObjectIdentifier($0)) }.randomElement().map(ObjectIdentifier.init)
                lastOptimisticAt = now
            }
            if let o = optimisticPeer { unchoke.insert(o) }
        }
        return active.compactMap { p in
            let choke = !unchoke.contains(ObjectIdentifier(p))
            return p.amChoking == choke ? nil : (p, choke)
        }
    }

    /// Lock held: a block a peer we unchoked asked for, if we have it.
    func uploadBlockLocked(_ r: BlockRequest) -> Data? {
        guard reciprocates, !paused, let info = info, let storage = storage, r.piece >= 0, r.piece < info.pieceCount,
              have[r.piece], r.length > 0, r.length <= 32 * 1024, r.offset >= 0, r.offset + r.length <= info.pieceSize(r.piece)
        else { return nil }
        let at = Int64(r.piece) * Int64(info.pieceLength) + Int64(r.offset)
        guard let data = try? storage.read(offset: at, length: r.length) else { return nil }
        uploadedTotal += Int64(r.length)
        return data
    }

    /// Disconnects from the swarm and stops all network activity until `resume()` (or a playback request).
    public func pause() {
        lock.lock()
        guard !paused else { lock.unlock(); return }
        paused = true
        saveResumeLocked()
        lock.unlock()
        loop.post { [self] in closeAllPeers(reason: "paused") }
    }

    public func resume() {
        lock.lock()
        wakeLocked()
        lock.unlock()
    }

    /// Lock held: leaves the paused state. Trackers (started on first resume when added paused), the DHT and peer
    /// connections pick up on the loop thread.
    private func wakeLocked() {
        guard paused else { return }
        paused = false
        retryAfter.removeAll()
        requeueKnownPeersLocked()
        tickSoonLocked()
        let firstStart = !networkStarted
        networkStarted = true
        if !connectQueued { connectQueued = true; loop.post { [weak self] in self?.connectMore() } }
        loop.post { [weak self] in
            guard let self else { return }
            if firstStart {
                self.trackers.forEach { $0.start() }
                if self.client?.useDHT == true { self.lookupDHT() }
            } else {
                self.trackers.forEach { $0.poke() }
            }
        }
    }

    private var dataDirectory: URL { directory.appendingPathComponent("data", isDirectory: true) }
    private var infoFile: URL { directory.appendingPathComponent("info.bencode") }
    private var resumeFile: URL { directory.appendingPathComponent("resume.bin") }
    /// Peers that sent data last time, dialed first when the torrent is added again (before any tracker answers).
    private var peersFile: URL { directory.appendingPathComponent("peers.bin") }

    // MARK: lifecycle

    func start(extraTrackers: [String], useDHT: Bool, paused startPaused: Bool = false) {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        lock.lock()
        paused = startPaused
        networkStarted = !startPaused
        tickingSlowly = startPaused
        if let info = descriptor.info {
            setInfo(info)
        } else if let raw = try? Data(contentsOf: infoFile), let info = try? TorrentInfo(rawInfo: raw), info.infoHash == infoHash {
            setInfo(info)
        }
        var urls = descriptor.trackers
        for t in extraTrackers where !urls.contains(t) { urls.append(t) }
        trackers = urls.map { TrackerAnnouncer(url: $0, torrent: self) }
        lock.unlock()

        // Added paused: no tracker, DHT or peer traffic until resumed (or played).
        if !startPaused { trackers.forEach { $0.start() } }
        if let d = try? Data(contentsOf: peersFile) { addPeers(PeerAddress.parseCompactList(d), source: "cache") }
        if useDHT && !startPaused { lookupDHT() }
        loop.addTicker(owner: self, interval: startPaused ? Torrent.pausedTickInterval : 0.1) { [weak self] in self?.tick() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        saveResumeLocked()
        let waiters = Array(blockWaiters.values)
        blockWaiters.removeAll()
        lock.broadcast()
        lock.unlock()
        for w in waiters { w.continuation?.resume(returning: nil); w.continuation = nil }
        trackers.forEach { $0.stop() }
        loop.post { [self] in
            closeAllPeers(reason: "stopped")
            storage?.closeAll()
        }
    }

    /// Loop thread.
    private func closeAllPeers(reason: String) {
        lock.lock()
        let ps = Array(peers.values)
        lock.unlock()
        ps.forEach { $0.close(reason: reason) }
    }

    // MARK: app lifecycle

    /// Suspensions longer than this leave connections that look open but are dead (peers and NAT mappings drop idle
    /// connections), so they are replaced rather than waited on.
    static let staleAfterSuspension: TimeInterval = 30

    /// Persists progress and the peers worth dialing again (the app may not come back from suspension).
    func saveState() {
        lock.lock()
        if !stopped { saveResumeLocked() }
        lock.unlock()
    }

    /// The app is active again after `suspended` seconds in the background. Sockets iOS reclaimed fail on first use
    /// (a keep-alive reveals them); after a long suspension every connection is replaced. Either way the peers that
    /// sent data are dialed again first, without back-off, and trackers and the DHT are asked again.
    func reconnectAfterSuspension(suspended: TimeInterval) {
        loop.post { [self] in
            lock.lock()
            guard !stopped, !paused else { lock.unlock(); return }
            let all = Array(peers.values)
            let useful = all.filter { $0.isActive && $0.downloadedBytes > 0 }
                .sorted { $0.downloadedBytes > $1.downloadedBytes }.map { $0.address }
            resumedAt = Date.timeIntervalSinceReferenceDate
            lock.unlock()
            if suspended > Torrent.staleAfterSuspension {
                all.forEach { $0.close(reason: "stale after suspension") }
            } else {
                all.filter { $0.isActive }.forEach { $0.enqueueKeepAlive() }
            }
            lock.lock()
            retryAfter.removeAll()
            let first = Set(useful)
            peerQueue.removeAll { first.contains($0) }
            peerQueue.insert(contentsOf: useful.filter { peers[$0] == nil }, at: 0)
            if peerQueue.count < 50 { requeueKnownPeersLocked() }
            lastDHTLookup = Date()
            tickSoonLocked()
            lock.unlock()
            trackers.forEach { $0.poke() }
            connectMore()
            lookupDHT()
        }
    }

    private func lookupDHT() {
        guard let dht = client?.dht else { return }
        lastDHTLookup = Date()
        dht.findPeers(infoHash: infoHash) { [weak self] peers in self?.addPeers(peers, source: "dht") }
    }

    /// Periodic maintenance on the loop thread: returns when to run again (nil once stopped). Ten times a second while
    /// there is something to download or a player to serve, once a second otherwise.
    private func tick() -> TimeInterval? {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        if stopped { lock.unlock(); return nil }
        if paused {
            if resumeDirty { saveResumeLocked() }
            tickingSlowly = true
            lock.unlock()
            return Torrent.pausedTickInterval
        }
        var toClose: [(PeerConnection, String)] = []
        var keepAlive: [PeerConnection] = []
        let sampleRates = now - lastRateSample >= 0.5
        let dt = now - lastRateSample
        if sampleRates { lastRateSample = now }
        for p in peers.values {
            switch p.phase {
            case .connecting where now - p.startedAt > Torrent.connectTimeout:
                toClose.append((p, "connect timeout"))
            case .handshaking where now - p.startedAt > Torrent.handshakeTimeout:
                toClose.append((p, "handshake timeout"))
            case .active:
                if sampleRates {
                    let delta = Double(p.downloadedBytes - p.bytesAtLastSample)
                    p.bytesAtLastSample = p.downloadedBytes
                    // An idle peer gives no evidence about its speed, so its estimate only decays while it has work.
                    if delta > 0 || !p.pending.isEmpty {
                        let inst = delta / max(dt, 0.1)
                        if p.windowGrowing && delta > 0 {
                            p.rateSamples += 1
                            // The first sample covers part of an interval. Once the rate stops growing, the queue is
                            // sized from it.
                            if p.rateSamples > 2 && inst < p.rate * 1.15 { p.windowGrowing = false; p.window = 8 }
                        }
                        p.rate = inst >= p.rate ? inst : p.rate * 0.85 + inst * 0.15
                    }
                }
                if !p.pending.isEmpty {
                    let silent = now - p.lastBlockAt
                    if silent > 30 { toClose.append((p, "snubbed")) }
                    else if silent > 5 && !p.snubbed {
                        // Hand its work to others; it may still recover.
                        p.snubbed = true
                        releaseRequestsLocked(p)
                    }
                }
                if !p.cancelled.isEmpty && sampleRates {
                    // Peers without the fast extension never answer a cancel.
                    p.cancelled = p.cancelled.filter { now - $0.value < 5 }
                }
                if !p.cancelHeld.isEmpty && sampleRates {
                    // A cancel unanswered for long: the peer won't send the block after all.
                    let id = ObjectIdentifier(p)
                    for r in p.cancelHeld where now - (p.cancelled[r] ?? 0) > Torrent.cancelAnswerTimeout {
                        p.cancelHeld.remove(r)
                        inProgress[r.piece]?.release(r.offset / blockSize, peer: id)
                        cursorsStale = true
                    }
                }
                if now - p.lastSendAt > 90 { keepAlive.append(p) }
            default: break
            }
        }

        var doDHT = false, poke = false
        var chokes: [(PeerConnection, Bool)] = []
        var haves: [Int] = []
        var haveTargets: [PeerConnection] = []
        if now - lastSlowTick >= 1 {
            lastSlowTick = now
            chokes = chokeRoundLocked(now: now)
            if !verifiedForHave.isEmpty {
                haves = verifiedForHave
                verifiedForHave.removeAll()
                haveTargets = handshaked.compactMap { peersByID[$0] }.filter(\.isActive)
            }
            rateMeter.add(bytesSinceTick)
            bytesSinceTick = 0
            currentRate = rateMeter.rate()
            if resumeDirty && Date().timeIntervalSince(lastResumeSave) > 5 { saveResumeLocked() }
            toClose += peersToReplaceLocked(now: now)
            let starvingForPeers = handshaked.count < 8
            let dhtInterval: TimeInterval = starvingForPeers ? 30 : 300
            doDHT = client?.useDHT == true && Date().timeIntervalSince(lastDHTLookup) > dhtInterval
            if doDHT { lastDHTLookup = Date() }
            poke = starvingForPeers && peerQueue.isEmpty
            updateStarvingLocked()
        }
        let toStart = dequeuePeersLocked(now: now)
        if TorrentLog.enabled && now - lastRampLog >= 0.5 && now - lastActivityAt < 20 {
            lastRampLog = now
            var inFlight = 0, urgentInFlight = 0, unchoked = 0, connecting = 0, active = 0
            for p in peers.values {
                if p.isActive { active += 1; if !p.peerChoking { unchoked += 1 } } else { connecting += 1 }
                inFlight += p.pending.count
                for v in p.pending.values where v.priority == Span.now { urgentInFlight += 1 }
            }
            var ahead: Int64 = -1, readerAt: Int64 = 0, settled = 0.0
            if let info = info, let r = readers.values.max(by: { $0.updated < $1.updated }), r.fileIndex < info.files.count {
                readerAt = r.offset
                settled = r.settledUntil > 0 ? r.settledUntil - now : 0
                ahead = availablePrefixLocked(info.files[r.fileIndex].offset + r.offset, maxLength: 64 << 20)
            }
            var head = ""
            if let info = info {
                for (piece, b, _) in readerHeadsLocked(info) {
                    guard let pp = inProgress[piece] else { head += " head \(piece)/\(b) unrequested"; continue }
                    head += String(format: " head %d/%d age %.2f exp %.2f:", piece, b, now - pp.requestedAt[b], expectedArrivalLocked(pp, b, now: now) - now)
                    let r = BlockRequest(piece: piece, offset: b * blockSize, length: pp.blockLength(b))
                    for id in pp.requesters[b] {
                        guard let p = peersByID[id] else { continue }
                        let pr = p.pending[r]
                        head += String(format: " [%.0fKB/s q%d late%.2f ahead%d since%d", p.rate / 1024, p.pending.count, pr.map { now - $0.eta } ?? -1,
                                       pr?.queuedAhead ?? -1, pr.map { Int((p.downloadedBytes - $0.deliveredBefore) / Int64(blockSize)) } ?? -1)
                            + (p.snubbed ? " snub]" : p.peerChoking ? " choked]" : "]")
                    }
                    if let f = peers.values.filter({ $0.isActive && !$0.peerChoking }).max(by: { $0.rate < $1.rate }) {
                        head += " fastest: has \(f.has(piece)) cancelled \(f.cancelled[r].map { String(format: "%.2f", now - $0) } ?? "-") asked \(pp.requesters[b].contains(ObjectIdentifier(f))) fast \(f.supportsFast)"
                    }
                }
            }
            let rates = peers.values.filter { $0.isActive && !$0.peerChoking }.sorted { $0.rate > $1.rate }.prefix(8)
                .map { String(format: "%.0f", $0.rate / 1024) + ($0.answerTime.map { String(format: "@%.0f", $0 * 1000) } ?? "") }.joined(separator: ",")
            log(String(format: "ramp %.1fs: got %.2f MB (%.2f MB new), reader at %.2f MB has %.2f MB settled %.1fs, peers %d (unchoked %d, connecting %d, queued %d), in flight %d (now %d)",
                       now - lastActivityStart, Double(downloadedTotal - activityBytes) / 1e6, Double(newBlockBytes) / 1e6, Double(readerAt) / 1e6, Double(ahead) / 1e6, settled, active, unchoked, connecting,
                       peerQueue.count, inFlight, urgentInFlight) + " rates [\(rates)]" + head
                + String(format: " dup %.2f/%.2f/%.2f cancelled-new %.2f", Double(dupBytes[0]) / 1e6, Double(dupBytes[1]) / 1e6,
                         Double(dupBytes[2]) / 1e6, Double(dupBytes[3]) / 1e6))
        }
        // Blocks become overdue without any event, so the urgent ones are reconsidered often.
        // A settled reader's estimate runs out without any event.
        if readers.values.contains(where: { $0.settledUntil > 0 && $0.settledUntil <= now }) { orderDirty = true }
        let reschedule = orderDirty || spans.first?.priority == Span.now || now - lastSlowTick < 0.1
        if reschedule {
            // Without metadata, this retries timed-out metadata requests.
            if info != nil || now - lastSlowTick < 0.1 { rescheduleAllLocked() }
        }
        let idle = info != nil && !orderDirty && !rescheduleQueued && !isForegroundLocked && spans.isEmpty
            && !peers.values.contains { !$0.isActive }
        tickingSlowly = idle
        var layoutFiles: [Int] = []
        if let info = info {
            // Matroska files a want asks for too: their layout puts embedded fonts after what the first frame needs.
            let wanted = Set(wants.values.map(\.fileIndex)).subtracting(streamingFiles).filter { $0 >= 0 && $0 < info.files.count }
            layoutFiles = (streamingFiles.sorted() + (prefetchTarget.map { [$0.fileIndex] } ?? []) + wanted.sorted())
                .filter { layoutPendingLocked($0, info) }
        }
        lock.unlock()

        for fi in layoutFiles { refreshContainerLayout(fileIndex: fi) }
        for (p, reason) in toClose { p.close(reason: reason) }
        for p in keepAlive { p.enqueueKeepAlive() }
        if !chokes.isEmpty || !haves.isEmpty {
            for (p, choke) in chokes { p.setChoking(choke) }
            for p in haveTargets { for h in haves { p.enqueueHave(h) } }
            for p in chokes.map(\.0) + haveTargets { p.flush() }
        }
        runDeferredCloses()
        toStart.forEach { $0.startConnect(loop: loop) }
        if doDHT { lookupDHT() }
        if poke { trackers.forEach { $0.poke() } }
        return idle ? Torrent.idleTickInterval : 0.1
    }

    static let idleTickInterval: TimeInterval = 1
    /// A paused torrent only saves its resume data; `wakeLocked` brings the ticker back right away.
    static let pausedTickInterval: TimeInterval = 5

    /// Lock held: the torrent may have become busy (a player, a want, resumed, new peers), so frequent maintenance
    /// starts right away instead of after the idle interval.
    func tickSoonLocked() {
        guard tickingSlowly else { return }
        tickingSlowly = false
        loop.tickSoon(owner: self)
    }

    /// When every slot is taken and there are untried peers, peers that kept us choked for a while (or have nothing
    /// we need) make room: seeders unchoke a handful of peers at a time, so a fresh connection is often the faster
    /// way to an unchoke.
    private func peersToReplaceLocked(now: TimeInterval) -> [(PeerConnection, String)] {
        guard peers.count >= maxPeers - 2 else { return [] }
        let candidates = peerQueue.filter { (retryAfter[$0] ?? 0) <= now && peers[$0] == nil }.count
        guard candidates > 0 else { return [] }
        let stale = peers.values.filter { p in
            p.isActive && p.allowedFast.isEmpty && ((p.peerChoking && now - p.chokedSince > 30) ||
                (!p.amInterested && now - (p.connectedAt ?? now) > 20))
        }.sorted { $0.chokedSince < $1.chokedSince }
        return stale.prefix(min(4, candidates)).map { ($0, "replaced (choked or useless)") }
    }

    /// Loop thread, lock not held.
    func runDeferredCloses() {
        lock.lock()
        let list = deferredCloses
        deferredCloses.removeAll()
        lock.unlock()
        for (p, reason) in list { p.close(reason: reason) }
    }

    /// Lock held.
    func deferClose(_ peer: PeerConnection, reason: String) {
        deferredCloses.append((peer, reason))
    }

    /// Loop thread, after a peer's input was processed.
    func flushPeersAfterEvent() {
        runDeferredCloses()
    }

    /// Asks the loop to recompute every peer's requests now (a reader moved, a want changed).
    func requestReschedule() {
        lock.lock()
        requestRescheduleLocked()
        lock.unlock()
    }

    func requestRescheduleLocked() {
        tickSoonLocked()
        guard !rescheduleQueued else { return }
        rescheduleQueued = true
        loop.post { [weak self] in self?.rescheduleAll() }
    }

    private func rescheduleAll() {
        lock.lock()
        rescheduleQueued = false
        if !stopped && !paused && info != nil { rescheduleAllLocked() }
        lock.unlock()
        runDeferredCloses()
    }

    /// Lock held: whether the player is (or may soon be) waiting on blocks that haven't arrived.
    func updateStarvingLocked() {
        let was = starving
        if orderDirty, let info = info { rebuildOrder(info) }
        starving = spans.contains { s in
            guard s.priority <= Span.soon else { return false }
            guard let pp = inProgress[s.piece] else { return !have[s.piece] }
            return (s.start..<s.end).contains { !pp.received[$0] }
        }
        if was != starving { client?.setStarving(self, starving) }
    }

    /// Whether the torrent serves a reader or urgent wants (and so may take bandwidth from torrents that don't).
    var isForegroundLocked: Bool { !readers.isEmpty || wants.values.contains { $0.urgency >= .soon } }

    // MARK: peers

    /// Connection slots free right now.
    private func freeSlotsLocked() -> Int {
        guard !stopped, !paused else { return 0 }
        let connecting = peers.values.filter { $0.phase == .connecting || $0.phase == .idle }.count
        return max(0, min(maxPeers - (peers.count - connecting), maxConnecting - connecting))
    }

    private func connectLocked(_ addr: PeerAddress) -> PeerConnection {
        let conn = PeerConnection(address: addr, torrent: self)
        peers[addr] = conn
        peersByID[ObjectIdentifier(conn)] = conn
        return conn
    }

    /// Creates connections for queued peers while there are free slots. The caller starts them after unlocking.
    private func dequeuePeersLocked(now: TimeInterval) -> [PeerConnection] {
        var toStart: [PeerConnection] = []
        var budget = freeSlotsLocked()
        guard budget > 0 else { return [] }
        var scanned = 0
        let queueCount = peerQueue.count
        var deferred: [PeerAddress] = []
        while budget > 0 && scanned < queueCount && !peerQueue.isEmpty {
            let addr = peerQueue.removeFirst()
            scanned += 1
            if let r = retryAfter[addr], r > now { deferred.append(addr); continue }
            if peers[addr] != nil || banned.contains(addr) { continue }
            toStart.append(connectLocked(addr))
            budget -= 1
        }
        peerQueue.append(contentsOf: deferred)
        return toStart
    }

    private func requeueKnownPeersLocked() {
        let queued = Set(peerQueue)
        for p in knownPeers.shuffled() where peers[p] == nil && !queued.contains(p) { peerQueue.append(p) }
    }

    /// Loop thread: starts connections for free slots.
    private func connectMore() {
        lock.lock()
        connectQueued = false
        let toStart = dequeuePeersLocked(now: Date.timeIntervalSinceReferenceDate)
        lock.unlock()
        toStart.forEach { $0.startConnect(loop: loop) }
    }

    func requestConnect() {
        lock.lock()
        let queued = connectQueued
        connectQueued = true
        tickSoonLocked()
        lock.unlock()
        if !queued { loop.post { [weak self] in self?.connectMore() } }
    }

    /// Queues peers and connects right away while there are free slots. Lists are shuffled, since one stale tracker
    /// list (common) would otherwise hold every slot until its connections time out. Peers learned from other peers
    /// are live, so they go first.
    public func addPeers(_ list: [PeerAddress], source: String) {
        lock.lock()
        var fresh: [PeerAddress] = []
        for p in list where !p.isPrivateOrInvalid || source == "test" {
            if knownPeers.count < 4000, knownPeers.insert(p).inserted { fresh.append(p) }
        }
        fresh.shuffle()
        if source == "pex" || source == "test" || source == "cache" { peerQueue.insert(contentsOf: fresh, at: 0) }
        else {
            // Interleave with what's queued so every source gets early attempts.
            for (i, p) in fresh.enumerated() { peerQueue.insert(p, at: min(peerQueue.count, i * 2)) }
        }
        lock.unlock()
        if !fresh.isEmpty {
            log("\(infoHashHex.prefix(8)): +\(fresh.count) peers from \(source)")
            requestConnect()
        }
    }

    /// Lock held (loop thread, from PEX).
    func queuePexPeers(_ list: [PeerAddress]) {
        var fresh: [PeerAddress] = []
        for p in list where !p.isPrivateOrInvalid {
            if knownPeers.count < 4000, knownPeers.insert(p).inserted { fresh.append(p) }
        }
        guard !fresh.isEmpty else { return }
        peerQueue.insert(contentsOf: fresh.shuffled(), at: 0)
        if !connectQueued {
            connectQueued = true
            loop.post { [weak self] in self?.connectMore() }
        }
    }

    func peerConnected(_ peer: PeerConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !paused, peers[peer.address] === peer else { return false }
        let now = Date.timeIntervalSinceReferenceDate
        handshaked.insert(ObjectIdentifier(peer))
        peer.connectedAt = now
        peer.chokedSince = now
        peer.lastBlockAt = now
        if firstConnectAt == nil {
            firstConnectAt = now
            log("\(infoHashHex.prefix(8)): first peer after \(String(format: "%.2f", now - createdAt))s")
        }
        if now - lastActivityStart < 15 {
            log("peer \(peer.address) (\(peer.clientName)) up: " + String(format: "tcp %.0f ms, handshake %.0f ms (%.2fs)",
                peer.rtt * 1000, (now - peer.startedAt - peer.rtt) * 1000, now - createdAt))
        }
        if let info = info { peer.bitfield = Array(repeating: false, count: info.pieceCount) }
        return true
    }

    /// Loop thread, lock not held.
    func peerDisconnected(_ peer: PeerConnection) {
        lock.lock()
        let id = ObjectIdentifier(peer)
        peer.closed = true
        releaseRequestsLocked(peer)
        if peers[peer.address] === peer { peers[peer.address] = nil }
        peersByID[id] = nil
        let wasConnected = handshaked.remove(id) != nil
        for (piece, _) in peer.metadataRequestedAt { metadataRequestedAt[piece] = nil }
        // An incoming peer's address is a port it connected from; it can't be connected back to.
        if !stopped && !paused && !banned.contains(peer.address) && !peer.isIncoming {
            // Useful peers are retried soon (right away when the app just came back and the socket was reclaimed);
            // dead ones much later.
            let now = Date.timeIntervalSinceReferenceDate
            let delay: TimeInterval = peer.downloadedBytes > 0 ? (now - resumedAt < 10 ? 0 : 10) : (wasConnected ? 90 : 600)
            retryAfter[peer.address] = now + delay
            if delay == 0 { peerQueue.insert(peer.address, at: 0) } else { peerQueue.append(peer.address) }
        }
        lock.unlock()
        requestConnect()
    }

    func releaseRequestsLocked(_ peer: PeerConnection) {
        releaseCancelHeldLocked(peer)
        guard !peer.pending.isEmpty else { return }
        let id = ObjectIdentifier(peer)
        for r in peer.pending.keys { inProgress[r.piece]?.release(r.offset / blockSize, peer: id) }
        peer.pending.removeAll()
        cursorsStale = true
    }

    func releaseCancelHeldLocked(_ peer: PeerConnection) {
        guard !peer.cancelHeld.isEmpty else { return }
        let id = ObjectIdentifier(peer)
        for r in peer.cancelHeld { inProgress[r.piece]?.release(r.offset / blockSize, peer: id) }
        peer.cancelHeld.removeAll()
        cursorsStale = true
    }

    /// Lock held: takes a request off a peer's queue and sends a cancel. A peer with the fast extension answers it
    /// with the block (if sent already) or a reject: until then the block stays assigned to it.
    func cancelRequestLocked(_ peer: PeerConnection, _ r: BlockRequest, now: TimeInterval) {
        peer.pending[r] = nil
        peer.cancelled[r] = now
        if peer.supportsFast { peer.cancelHeld.insert(r) } else { inProgress[r.piece]?.release(r.offset / blockSize, peer: ObjectIdentifier(peer)) }
        cursorsStale = true
    }

    func peerChokedLocked(_ peer: PeerConnection) {
        if !peer.peerChoking { peer.chokedSince = Date.timeIntervalSinceReferenceDate }
        peer.peerChoking = true
        // Choking drops queued requests (with the fast extension they are rejected one by one, except allowed-fast).
        let id = ObjectIdentifier(peer)
        releaseCancelHeldLocked(peer)
        peer.cancelled.removeAll()
        peer.early.removeAll()
        for r in peer.pending.keys where !peer.allowedFast.contains(r.piece) {
            peer.pending[r] = nil
            inProgress[r.piece]?.release(r.offset / blockSize, peer: id)
        }
        cursorsStale = true
    }

    func peerUnchokedLocked(_ peer: PeerConnection) {
        let now = Date.timeIntervalSinceReferenceDate
        peer.peerChoking = false
        peer.lastBlockAt = now
        // Without the fast extension, requests that arrived while it still choked us were dropped silently.
        if !peer.early.isEmpty && !peer.supportsFast { releaseEarlyLocked(peer) { _ in true } }
        if peer.firstUnchokeAt == nil {
            peer.firstUnchokeAt = now
            if now - lastActivityStart < 15 {
                log("peer \(peer.address) unchoked " + String(format: "%.2fs after handshake (%.2fs)", now - (peer.connectedAt ?? now), now - createdAt))
            }
        }
        if firstUnchokeAt == nil {
            firstUnchokeAt = now
            log("\(infoHashHex.prefix(8)): first unchoke after \(String(format: "%.2f", now - createdAt))s")
        }
    }

    func requestRejectedLocked(_ peer: PeerConnection, _ r: BlockRequest) {
        // An early request the peer couldn't take (choked, or no such piece): others pick it up, and so may this peer.
        if !peer.early.isEmpty, peer.early.remove(r) != nil {
            if peer.pending.removeValue(forKey: r) != nil {
                inProgress[r.piece]?.release(r.offset / blockSize, peer: ObjectIdentifier(peer))
                cursorsStale = true
            }
            return
        }
        // The answer to a cancel, not to a live request.
        if peer.cancelled.removeValue(forKey: r) != nil {
            if peer.cancelHeld.remove(r) != nil {
                inProgress[r.piece]?.release(r.offset / blockSize, peer: ObjectIdentifier(peer))
                cursorsStale = true
            }
            return
        }
        guard peer.pending.removeValue(forKey: r) != nil else { return }
        inProgress[r.piece]?.release(r.offset / blockSize, peer: ObjectIdentifier(peer))
        // Not asked of this peer again for a second or two (it may not have the block after all, or its queue is
        // full); others pick it up. Entries expire 5 s after their time.
        peer.cancelled[r] = Date.timeIntervalSinceReferenceDate - 3.5
        cursorsStale = true
    }

    func peerHaveLocked(_ peer: PeerConnection, piece: Int) {
        if info != nil {
            if piece >= 0 && piece < peer.bitfield.count { peer.bitfield[piece] = true }
        } else {
            peer.pendingHaves.append(piece)
        }
    }

    func peerHaveAllLocked(_ peer: PeerConnection) {
        if let info = info { peer.bitfield = Array(repeating: true, count: info.pieceCount) } else { peer.pendingHaveAll = true }
    }

    func peerBitfieldLocked(_ peer: PeerConnection, data: Data) {
        if let info = info { peer.bitfield = Torrent.decodeBitfield(data, count: info.pieceCount) }
        else { peer.rawBitfield = data }
        // Early requests for pieces it doesn't have won't be answered (or only rejected).
        if !peer.early.isEmpty { releaseEarlyLocked(peer) { !peer.has($0.piece) } }
    }

    /// Lock held: forgets early requests matching `which` (a late answer is still taken).
    func releaseEarlyLocked(_ peer: PeerConnection, _ which: (BlockRequest) -> Bool) {
        let id = ObjectIdentifier(peer)
        for r in peer.early where which(r) {
            peer.early.remove(r)
            if peer.pending.removeValue(forKey: r) != nil {
                inProgress[r.piece]?.release(r.offset / blockSize, peer: id)
                cursorsStale = true
            }
        }
    }

    static func decodeBitfield(_ data: Data, count: Int) -> [Bool] {
        var out = Array(repeating: false, count: count)
        for (i, byte) in data.enumerated() where byte != 0 {
            for bit in 0..<8 {
                let idx = i * 8 + bit
                if idx < count && byte & (0x80 >> UInt8(bit)) != 0 { out[idx] = true }
            }
        }
        return out
    }

    func ourBitfieldMessage(orEmpty: Bool = false) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard info != nil, haveCount > 0 || orEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: (have.count + 7) / 8)
        for (i, h) in have.enumerated() where h { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
        var d = Data()
        d.appendBE(UInt32(bytes.count + 1))
        d.append(5)
        d.append(contentsOf: bytes)
        return d
    }

    // MARK: metadata exchange (BEP 9)

    var metadataSizeIfKnown: Int? { lock.lock(); defer { lock.unlock() }; return info?.rawInfo.count }

    func peerReportedMetadataSizeLocked(_ peer: PeerConnection, size: Int) {
        guard info == nil, metadataSize == nil, size > 0, size < 32 * 1024 * 1024 else { return }
        metadataSize = size
        metadataPieces = Array(repeating: nil, count: (size + 16383) / 16384)
    }

    func metadataPieceReplyLocked(_ piece: Int) -> Data? {
        guard let raw = info?.rawInfo else { return nil }
        let start = piece * 16384
        guard start >= 0 && start < raw.count else { return nil }
        var reply = BValue.dict(["msg_type": .int(1), "piece": .int(Int64(piece)), "total_size": .int(Int64(raw.count))]).encoded()
        reply.append(raw.subdata(in: raw.startIndex + start ..< raw.startIndex + min(raw.count, start + 16384)))
        return reply
    }

    func metadataPieceRejectedLocked(_ peer: PeerConnection, piece: Int) {
        metadataRequestedAt[piece] = nil
        peer.metadataRequestedAt[piece] = nil
    }

    func metadataPieceReceivedLocked(_ peer: PeerConnection, piece: Int, data: Data) {
        peer.metadataRequestedAt[piece] = nil
        guard info == nil, piece >= 0, piece < metadataPieces.count, metadataPieces[piece] == nil else { return }
        metadataPieces[piece] = data
        guard metadataPieces.allSatisfy({ $0 != nil }) else { return }
        var raw = Data()
        metadataPieces.forEach { raw.append($0!) }
        if SHA1.hash(raw) == infoHash, let parsed = try? TorrentInfo(rawInfo: raw) {
            log("\(infoHashHex.prefix(8)): metadata received (\(parsed.files.count) files)")
            try? raw.write(to: infoFile)
            setInfo(parsed)
            requestRescheduleLocked()
        } else {
            log("\(infoHashHex.prefix(8)): metadata hash mismatch, retrying")
            metadataPieces = Array(repeating: nil, count: metadataPieces.count)
        }
        metadataRequestedAt.removeAll()
    }

    /// Gives a torrent added by magnet or info-hash its metainfo from a .torrent file fetched meanwhile, so it can
    /// join the swarm (trackers, DHT, peers) while the file downloads instead of after. Returns whether the torrent
    /// has its metainfo now; false when `info` belongs to another torrent.
    @discardableResult
    public func installInfo(_ info: TorrentInfo) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard info.infoHash == infoHash else { return false }
        guard self.info == nil, !stopped else { return self.info != nil }
        log("\(infoHashHex.prefix(8)): metainfo installed from the .torrent file")
        try? info.rawInfo.write(to: infoFile)
        setInfo(info)
        metadataRequestedAt.removeAll()
        requestRescheduleLocked()
        return true
    }

    /// Called with lock held.
    private func setInfo(_ info: TorrentInfo) {
        self.info = info
        have = Array(repeating: false, count: info.pieceCount)
        storage = Storage(root: dataDirectory, info: info)
        for p in peers.values {
            if p.pendingHaveAll { p.bitfield = Array(repeating: true, count: info.pieceCount) }
            else if let raw = p.rawBitfield { p.bitfield = Torrent.decodeBitfield(raw, count: info.pieceCount) }
            else if p.bitfield.count != info.pieceCount { p.bitfield = Array(repeating: false, count: info.pieceCount) }
            for h in p.pendingHaves where h >= 0 && h < info.pieceCount { p.bitfield[h] = true }
            p.rawBitfield = nil
            p.pendingHaves = []
            p.pendingHaveAll = false
        }
        orderDirty = true
        lock.broadcast()
        // Nothing is hashed at start. A piece enters the resume file only after it was written and verified, so it is
        // trusted while its files still extend past it (one stat per file). One whose file was removed or truncated
        // (the app trims its cache) can't hold its data any more and is simply missing again.
        if let resume = try? Data(contentsOf: resumeFile), resume.count == info.pieceCount {
            var sizes: [Int: Int64] = [:]
            for (idx, v) in resume.enumerated() where v == 1 {
                if storage!.holdsPiece(idx, sizes: &sizes) { have[idx] = true; haveCount += 1 } else { resumeDirty = true }
            }
        }
    }

    private func saveResumeLocked() {
        let good = peers.values.filter { $0.isActive && $0.downloadedBytes > 0 }.sorted { $0.downloadedBytes > $1.downloadedBytes }
        if !good.isEmpty {
            var d = Data()
            for p in good.prefix(80) { d.append(p.address.compact) }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? d.write(to: peersFile, options: .atomic)
        }
        guard info != nil else { return }
        try? Data(have.map { $0 ? 1 : 0 }).write(to: resumeFile, options: .atomic)
        resumeDirty = false
        lastResumeSave = Date()
    }

    // MARK: blocks

    /// Loop thread, lock held: a block arrived. It goes to disk right away and is readable from then on.
    func blockReceivedLocked(_ peer: PeerConnection, piece: Int, offset: Int, data: UnsafeRawBufferPointer) {
        let now = Date.timeIntervalSinceReferenceDate
        let r = BlockRequest(piece: piece, offset: offset, length: data.count)
        let pendingEntry = peer.pending[r]
        let wasPending = peer.pending.removeValue(forKey: r) != nil
        if let pe = pendingEntry, peer.rate > 64 * 1024 {
            // Time past sending what was queued before it, at the peer's peak rate.
            let sent = Double(peer.downloadedBytes - pe.deliveredBefore)
            let sample = max(0.02, now - pe.at - sent / peer.rate)
            if let a = peer.answerTime, sample >= a { peer.answerTime = a + (sample - a) * 0.01 } else { peer.answerTime = sample }
        }
        if !peer.early.isEmpty { peer.early.remove(r) }
        var wasCancelled = false
        if !peer.cancelled.isEmpty { wasCancelled = peer.cancelled.removeValue(forKey: r) != nil }
        if !peer.cancelHeld.isEmpty { peer.cancelHeld.remove(r) }
        if TorrentLog.enabled {
            let b = offset / blockSize
            let fresh = info != nil && piece >= 0 && piece < have.count && !have[piece]
                && !(inProgress[piece].map { b < $0.blockCount && $0.received[b] } ?? false)
            if !fresh { dupBytes[wasPending ? 0 : wasCancelled ? 1 : 2] += Int64(data.count) }
            else if wasCancelled { dupBytes[3] += Int64(data.count) }
        }
        peer.lastBlockAt = now
        peer.snubbed = false
        if peer.windowGrowing && peer.window < peer.maxRequests { peer.window += 1 }
        peer.downloadedBytes += Int64(data.count)
        bytesSinceTick += data.count
        downloadedTotal += Int64(data.count)
        if firstBlockAt == nil {
            firstBlockAt = now
            log("\(infoHashHex.prefix(8)): first block after \(String(format: "%.2f", now - createdAt))s")
        }
        guard let info = info, let storage = storage, piece >= 0, piece < info.pieceCount, !have[piece],
              offset % blockSize == 0 else { return }
        let pp: PieceProgress
        if let existing = inProgress[piece] { pp = existing } else {
            pp = PieceProgress(index: piece, size: info.pieceSize(piece))
            inProgress[piece] = pp
        }
        let b = offset / blockSize
        guard b < pp.blockCount, data.count == pp.blockLength(b), !pp.received[b], !pp.verifying else { return }
        if TorrentLog.enabled, readerHeadsLocked(info).contains(where: { $0.0 == piece && $0.1 == b }) {
            log(String(format: "head block %d/%d after %.2fs from %.0fKB/s peer (asked %.2fs ago, eta %+.2f, %d ahead, %d since; %d requesters)",
                       piece, b, now - pp.requestedAt[b], peer.rate / 1024, pendingEntry.map { now - $0.at } ?? -1,
                       pendingEntry.map { now - $0.eta } ?? 0, pendingEntry?.queuedAhead ?? -1,
                       pendingEntry.map { Int((peer.downloadedBytes - $0.deliveredBefore) / Int64(blockSize)) } ?? -1, pp.requesters[b].count))
        }
        do {
            try storage.write(offset: Int64(piece) * Int64(info.pieceLength) + Int64(offset), bytes: data)
        } catch {
            failure = "Disk write failed: \(error)"
            lock.broadcast()
            return
        }
        pp.received[b] = true
        pp.receivedCount += 1
        newBlockBytes += Int64(data.count)
        pp.sources.insert(peer.address)
        pp.blockSources[b] = peer.address
        let me = ObjectIdentifier(peer)
        for other in pp.requesters[b] where other != me {
            // A raced duplicate lost; take it off the other peer's queue.
            if let o = peersByID[other], o.pending.removeValue(forKey: r) != nil {
                o.cancelled[r] = now
                o.enqueueCancel(r)
            } else if let o = peersByID[other], !o.cancelHeld.isEmpty {
                o.cancelHeld.remove(r)
            }
        }
        pp.clearRequesters(b)
        notifyBlockWaitersLocked()
        lock.broadcast()
        if pp.receivedCount == pp.blockCount { verifyLocked(pp, info: info, storage: storage) }
    }

    private func verifyLocked(_ pp: PieceProgress, info: TorrentInfo, storage: Storage) {
        pp.verifying = true
        let piece = pp.index
        let expected = info.pieceHashes[piece]
        hashQueue.async { [weak self] in
            let data = try? storage.readPiece(piece)
            let ok = data.map { SHA1.hash($0) == expected } ?? false
            func blockHashes(_ d: Data) -> [Data] {
                stride(from: 0, to: d.count, by: blockSize).map { SHA1.hash(d.subdata(in: d.startIndex + $0 ..< d.startIndex + min(d.count, $0 + blockSize))) }
            }
            guard let self = self else { return }
            self.lock.lock()
            var culprits = Set<PeerAddress>()
            if ok {
                if !self.have[piece] {
                    self.have[piece] = true
                    self.haveCount += 1
                    self.resumeDirty = true
                    if self.reciprocates { self.verifiedForHave.append(piece) }
                }
                self.inProgress[piece] = nil
                if let attempts = self.failedAttempts.removeValue(forKey: piece), let good = data.map(blockHashes) {
                    for attempt in attempts {
                        for (b, (source, hash)) in attempt.enumerated() where b < good.count && good[b] != hash {
                            if let s = source { culprits.insert(s) }
                        }
                    }
                }
            } else {
                log("piece \(piece) failed hash check (sources \(pp.sources.count))")
                if pp.sources.count == 1 {
                    culprits = pp.sources
                } else if let d = data {
                    // Several peers sent blocks: find the bad one once the piece passes.
                    let hashes = blockHashes(d)
                    let attempt = hashes.indices.map { (pp.blockSources.indices.contains($0) ? pp.blockSources[$0] : nil, hashes[$0]) }
                    self.failedAttempts[piece, default: []].append(attempt)
                }
                self.inProgress[piece] = PieceProgress(index: piece, size: pp.size)
                self.cursorsStale = true
            }
            for a in culprits {
                self.banned.insert(a)
                if let p = self.peers[a] { self.deferClose(p, reason: "sent corrupt data") }
            }
            self.orderDirty = true
            self.lock.broadcast()
            self.lock.unlock()
            self.loop.post { [weak self] in self?.runDeferredCloses() }
            self.requestReschedule()
        }
    }

    /// Lock held: whether every block covering the absolute range has arrived (verified or not).
    func rangeAvailableLocked(_ start: Int64, _ end: Int64) -> Bool {
        guard end > start else { return true }
        return availablePrefixLocked(start, maxLength: end - start) >= end - start
    }

    /// Lock held: how many contiguous bytes from `start` (absolute) have arrived, up to `maxLength`.
    func availablePrefixLocked(_ start: Int64, maxLength: Int64) -> Int64 {
        guard let info = info, maxLength > 0 else { return 0 }
        let pl = Int64(info.pieceLength)
        let limit = min(info.totalLength, start + maxLength)
        var pos = start
        while pos < limit {
            let piece = Int(pos / pl)
            let pieceStart = Int64(piece) * pl
            let pieceEnd = pieceStart + Int64(info.pieceSize(piece))
            if have[piece] { pos = pieceEnd; continue }
            guard let pp = inProgress[piece], !(pp.verifying && pp.receivedCount == 0) else { break }
            var b = Int((pos - pieceStart) / Int64(blockSize))
            while b < pp.blockCount && pp.received[b] { b += 1 }
            let reached = min(pieceEnd, pieceStart + Int64(b) * Int64(blockSize))
            if reached <= pos { break }
            pos = reached
            if b < pp.blockCount { break }
        }
        return max(0, min(pos, limit) - start)
    }

    /// Lock held: wakes async waiters whose range is complete.
    func notifyBlockWaitersLocked() {
        guard !blockWaiters.isEmpty, let storage = storage else { return }
        for (id, w) in blockWaiters where rangeAvailableLocked(w.start, w.end) {
            blockWaiters[id] = nil
            if let c = w.continuation {
                w.continuation = nil
                let start = w.start, count = Int(w.end - w.start)
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: try? storage.read(offset: start, length: count)) }
            }
        }
    }

    // MARK: public API

    /// Readahead past a reader when none was set for its file: about 10 minutes of 1080p video.
    public static let defaultReadahead: Int64 = 256 * 1024 * 1024

    /// How far past the playback position a file is loaded in the background (`nil` restores the default).
    /// Only applies while the file is being read; nothing beyond it is fetched.
    public func setReadahead(_ bytes: Int64?, fileIndex: Int) {
        lock.lock()
        readahead[fileIndex] = bytes.map { max(0, $0) }
        orderDirty = true
        lock.unlock()
        requestReschedule()
    }

    /// Loads the first `bytes` of a file (plus its container index at the end) at low priority, replacing any
    /// earlier prefetch. Resumes a paused torrent.
    public func prefetch(fileIndex: Int, bytes: Int64) {
        lock.lock()
        prefetchTarget = (fileIndex, bytes)
        orderDirty = true
        lock.unlock()
        resume()
        requestReschedule()
    }

    public func cancelPrefetch() {
        lock.lock()
        prefetchTarget = nil
        orderDirty = true
        lock.unlock()
        requestReschedule()
    }

    /// Every piece of the first `bytes` of a file (and of its last 2 MB) is on disk.
    public func hasPrefix(fileIndex: Int, bytes: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { return false }
        let f = info.files[fileIndex]
        guard f.length > 0 else { return true }
        let head = info.pieces(from: f.offset, to: f.offset + min(f.length, max(1, bytes)))
        let tail = info.pieces(from: max(f.offset, f.offset + f.length - Torrent.indexTailBytes), to: f.offset + f.length)
        return head.allSatisfy { have[$0] } && tail.allSatisfy { have[$0] }
    }

    /// Marks a whole file for background download, or stops downloading it. Streaming doesn't need this:
    /// readers fetch what they read plus the readahead.
    public func setWanted(_ wanted: Bool, fileIndex: Int) {
        lock.lock()
        if wanted { wantedFiles.insert(fileIndex) } else { wantedFiles.remove(fileIndex); streamingFiles.remove(fileIndex) }
        orderDirty = true
        lock.unlock()
        requestReschedule()
    }

    public func setAllWanted(_ wanted: Bool) {
        lock.lock()
        guard let info = info else { lock.unlock(); return }
        if wanted { wantedFiles = Set(info.files.filter { !$0.isPadding }.map { $0.index }) } else { wantedFiles.removeAll(); streamingFiles.removeAll() }
        orderDirty = true
        lock.unlock()
        requestReschedule()
    }

    /// Asks for a byte range of a file. `.now` is as urgent as what the player is reading (e.g. the spot under the
    /// user's finger while scrubbing); `.soon` is a likely next seek target (skip-intro end, +10 s); `.background` sits
    /// below read-ahead (seek-preview keyframes). Only the blocks covering the range are needed — do not require the
    /// whole piece to be downloaded first. Replaces any earlier ranges registered under the same tag.
    public func want(fileIndex: Int, ranges: [Range<Int64>], urgency: RangeUrgency, tag: String) {
        lock.lock()
        wantSeq += 1
        let clean = ranges.filter { !$0.isEmpty && $0.lowerBound >= 0 }
        if clean.isEmpty { wants[tag] = nil } else { wants[tag] = Want(fileIndex: fileIndex, ranges: clean, urgency: urgency, seq: wantSeq) }
        orderDirty = true
        let wake = paused && urgency >= .soon
        lock.unlock()
        if wake { resume() }
        requestReschedule()
    }

    public func clearWants(tag: String) {
        lock.lock()
        let removed = wants.removeValue(forKey: tag) != nil
        if removed { orderDirty = true }
        lock.unlock()
        if removed { requestReschedule() }
    }

    /// Bytes of the file at offset..<offset+length once every block of it has arrived (verified or not), waiting up to
    /// `timeout`; nil on timeout. Never blocks the caller's thread longer than the timeout.
    /// Doesn't prioritize anything by itself: pair it with `want` (or a reader) for ranges that aren't being fetched.
    public func waitForBlocks(fileIndex: Int, offset: Int64, length: Int64, timeout: TimeInterval) async -> Data? {
        let check = checkBlockRange(fileIndex: fileIndex, offset: offset, length: length)
        switch check {
        case .invalid: return nil
        case .empty: return Data()
        case let .ready(storage, start, count):
            return await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: try? storage.read(offset: start, length: count)) }
            }
        case let .missing(start, end):
            guard timeout > 0 else { return nil }
            let waiter = BlockWaiter(start: start, end: end, fileIndex: fileIndex, fileOffset: offset)
            return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                register(waiter, continuation: c, timeout: timeout)
            }
        }
    }

    private enum BlockRangeCheck {
        case invalid, empty
        case ready(Storage, Int64, Int)
        case missing(Int64, Int64)
    }

    private func checkBlockRange(fileIndex: Int, offset: Int64, length: Int64) -> BlockRangeCheck {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, let storage = storage, fileIndex >= 0, fileIndex < info.files.count, offset >= 0, length >= 0,
              !stopped else { return .invalid }
        let file = info.files[fileIndex]
        let count = max(0, min(length, file.length - offset))
        guard count > 0 else { return .empty }
        let start = file.offset + offset, end = start + count
        return rangeAvailableLocked(start, end) ? .ready(storage, start, Int(count)) : .missing(start, end)
    }

    private func register(_ waiter: BlockWaiter, continuation c: CheckedContinuation<Data?, Never>, timeout: TimeInterval) {
        let id = ObjectIdentifier(waiter)
        lock.lock()
        if stopped {
            lock.unlock()
            c.resume(returning: nil)
            return
        }
        waiter.continuation = c
        blockWaiters[id] = waiter
        // Blocks may have landed between the check and registering.
        notifyBlockWaitersLocked()
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let w = self.blockWaiters.removeValue(forKey: id)
            let cont = w?.continuation
            w?.continuation = nil
            self.lock.unlock()
            cont?.resume(returning: nil)
        }
    }

    /// Blocks until the metadata (file list) is available.
    public func waitForInfo(timeout: TimeInterval) -> TorrentInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while info == nil && !stopped {
            if !lock.wait(until: deadline) { break }
        }
        return info
    }

    public var torrentInfo: TorrentInfo? { lock.lock(); defer { lock.unlock() }; return info }

    /// Lock held: registers or moves a streaming reader. Moving it re-ranks what to fetch.
    func updateReaderLocked(_ readerID: UUID, fileIndex: Int, offset: Int64) {
        if paused {
            // Playing something un-pauses the torrent.
            wakeLocked()
        }
        let now = Date.timeIntervalSinceReferenceDate
        if var r = readers[readerID], r.fileIndex == fileIndex {
            r.offset = offset
            // Re-rank once the reader has moved a bit (sequential playback) or jumped.
            if abs(offset - r.orderedAt) >= 256 * 1024 {
                r.orderedAt = offset
                r.updated = now
                orderDirty = true
                requestRescheduleLocked()
            }
            readers[readerID] = r
        } else {
            readers[readerID] = Reader(fileIndex: fileIndex, offset: offset, updated: now, orderedAt: offset, start: offset, startedAt: now)
            orderDirty = true
            requestRescheduleLocked()
            if now - lastActivityAt > 20 { lastActivityStart = now; activityBytes = downloadedTotal }
            lastActivityAt = now
        }
        if streamingFiles.insert(fileIndex).inserted { orderDirty = true }
    }

    /// Registers a streaming reader at `offset` of a file and blocks until `length` bytes from there have arrived
    /// (their blocks are on disk; the pieces may not be verified yet). Returns false on timeout (the reader stays
    /// registered so priorities keep following it).
    public func waitForData(fileIndex: Int, offset: Int64, length: Int, readerID: UUID, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { throw TorrentError.io("no such file") }
        let file = info.files[fileIndex]
        let start = file.offset + offset
        let end = min(file.offset + file.length, start + Int64(max(length, 1)))
        updateReaderLocked(readerID, fileIndex: fileIndex, offset: offset)
        while true {
            if stopped { throw TorrentError.stopped }
            if let f = failure { throw TorrentError.io(f) }
            if rangeAvailableLocked(start, end) { return true }
            if !lock.wait(until: deadline) { return false }
        }
    }

    /// Like `waitForData`, but returns as soon as any bytes at `offset` have arrived: how many contiguous bytes are
    /// readable from there (at most `maxLength`), or 0 on timeout. The stream server sends each block as it lands.
    func waitForAvailable(fileIndex: Int, offset: Int64, maxLength: Int64, readerID: UUID, timeout: TimeInterval) throws -> Int64 {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { throw TorrentError.io("no such file") }
        let file = info.files[fileIndex]
        let start = file.offset + offset
        let limit = min(maxLength, file.length - offset)
        guard limit > 0 else { return 0 }
        updateReaderLocked(readerID, fileIndex: fileIndex, offset: offset)
        while true {
            if stopped { throw TorrentError.stopped }
            if let f = failure { throw TorrentError.io(f) }
            let n = availablePrefixLocked(start, maxLength: limit)
            if n > 0 { return n }
            if !lock.wait(until: deadline) { return 0 }
        }
    }

    public func removeReader(_ id: UUID) {
        lock.lock()
        let removed = readers.removeValue(forKey: id) != nil
        if removed { orderDirty = true }
        lock.unlock()
        if removed { requestReschedule() }
    }

    /// Reads bytes of a file that `waitForData` reported available.
    public func readData(fileIndex: Int, offset: Int64, length: Int) throws -> Data {
        lock.lock()
        let storage = self.storage
        let file = info?.files[fileIndex]
        lock.unlock()
        guard let s = storage, let f = file else { throw TorrentError.io("no metadata") }
        return try s.read(offset: f.offset + offset, length: length)
    }

    /// Whether every piece covering a file range is downloaded and verified. Never prioritizes or blocks.
    public func hasData(fileIndex: Int, offset: Int64, length: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count, offset >= 0, length >= 0 else { return false }
        let file = info.files[fileIndex]
        let count = max(0, min(length, file.length - offset))
        guard count > 0 else { return true }
        let start = file.offset + offset
        return info.pieces(from: start, to: start + count).allSatisfy { have[$0] }
    }

    /// The bytes of a file range if every piece covering it is already downloaded and verified; nil otherwise.
    /// Never prioritizes, registers readers, or blocks. The range is clamped to the file length, so a range
    /// starting at or past the end yields empty data.
    public func availableData(fileIndex: Int, offset: Int64, length: Int) -> Data? {
        lock.lock()
        guard let info = info, let storage = storage, fileIndex >= 0, fileIndex < info.files.count,
              offset >= 0, length >= 0 else { lock.unlock(); return nil }
        let file = info.files[fileIndex]
        let count = Int(max(0, min(Int64(length), file.length - offset)))
        guard count > 0 else { lock.unlock(); return Data() }
        let start = file.offset + offset
        let ready = info.pieces(from: start, to: start + Int64(count)).allSatisfy { have[$0] }
        lock.unlock()
        guard ready else { return nil }
        return try? storage.read(offset: start, length: count)
    }

    /// Local path of a file (complete or partial).
    public func localURL(fileIndex: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let s = storage, let info = info, fileIndex < info.files.count else { return nil }
        return s.url(for: info.files[fileIndex])
    }

    /// Verified bytes of one file, without the rest of `status()`. Nil before the metadata.
    public func downloadedBytes(fileIndex: Int) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { return nil }
        return downloadedBytesLocked(info.files[fileIndex], info)
    }

    private func downloadedBytesLocked(_ f: TorrentFile, _ info: TorrentInfo) -> Int64 {
        var bytes: Int64 = 0
        guard f.length > 0 else { return 0 }
        for p in info.pieces(for: f) where have[p] {
            let ps = Int64(p) * Int64(info.pieceLength)
            let pe = ps + Int64(info.pieceSize(p))
            bytes += min(pe, f.offset + f.length) - max(ps, f.offset)
        }
        return bytes
    }

    public func status() -> TorrentStatus {
        lock.lock(); defer { lock.unlock() }
        var files: [FileStatus] = []
        var downloaded: Int64 = 0
        if let info = info {
            for f in info.files {
                files.append(FileStatus(file: f, downloadedBytes: downloadedBytesLocked(f, info), wanted: wantedFiles.contains(f.index)))
            }
            for p in 0..<info.pieceCount where have[p] { downloaded += Int64(info.pieceSize(p)) }
        }
        let phase: TorrentStatus.Phase
        if let f = failure { phase = .failed(f) } else { phase = info == nil ? .fetchingMetadata : .ready }
        let metaProgress = metadataPieces.isEmpty ? 0 : Double(metadataPieces.filter { $0 != nil }.count) / Double(metadataPieces.count)
        return TorrentStatus(
            infoHashHex: infoHashHex,
            name: info?.name ?? descriptor.displayName ?? infoHashHex,
            phase: phase,
            isPaused: paused,
            files: files,
            totalLength: info?.totalLength ?? 0,
            downloadedBytes: downloaded,
            connectedPeers: handshaked.count,
            knownPeers: knownPeers.count,
            downloadRate: currentRate,
            metadataProgress: info != nil ? 1 : metaProgress
        )
    }

    /// The peers connected now, fastest first.
    public func peerSnapshots() -> [PeerSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return handshaked.compactMap { peersByID[$0] }.map { p in
            let have = p.pendingHaveAll ? 1 : (p.bitfield.isEmpty ? 0 : Double(p.bitfield.lazy.filter { $0 }.count) / Double(p.bitfield.count))
            return PeerSnapshot(address: p.address.description, client: p.clientName, downloadRate: p.rate, progress: have,
                                isChoking: p.peerChoking, isIncoming: p.isIncoming)
        }.sorted { $0.downloadRate != $1.downloadRate ? $0.downloadRate > $1.downloadRate : $0.address < $1.address }
    }

    /// One line about the swarm, for logs and the command line harness.
    public var swarmSummary: String {
        lock.lock(); defer { lock.unlock() }
        let active = peers.values.filter { $0.isActive }
        let unchoked = active.filter { !$0.peerChoking }.count
        let sending = active.filter { $0.rate > 1024 }.count
        let connecting = peers.values.filter { $0.phase == .connecting || $0.phase == .handshaking }.count
        func ms(_ t: TimeInterval?) -> String { t.map { String(format: "%.1fs", $0 - createdAt) } ?? "-" }
        return "peers \(active.count) (unchoked \(unchoked), sending \(sending), connecting \(connecting), queued \(peerQueue.count), known \(knownPeers.count)) "
            + "first peer \(ms(firstConnectAt)) unchoke \(ms(firstUnchokeAt)) block \(ms(firstBlockAt)) "
            + String(format: "rate %.0f KB/s", currentRate / 1024)
            + " top " + active.sorted { $0.rate > $1.rate }.prefix(6).map { String(format: "%.0fK/%d", $0.rate / 1024, $0.pending.count) }.joined(separator: " ")
    }

    /// Diagnostics: who was asked for the block at a file offset, and how it is going.
    func blockDebugDescription(fileIndex: Int, offset: Int64) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { return "-" }
        let abs = info.files[fileIndex].offset + offset
        let piece = Int(abs / Int64(info.pieceLength))
        let b = Int((abs - Int64(piece) * Int64(info.pieceLength)) / Int64(blockSize))
        let now = Date.timeIntervalSinceReferenceDate
        let spanInfo = spans.first { $0.piece == piece && (($0.start)..<($0.end)).contains(b) }.map { "span prio \($0.priority)" } ?? "no span"
        let holders = peersWithPiece(piece)
        guard let pp = inProgress[piece] else { return "piece \(piece) block \(b): not started, \(spanInfo), \(holders) peers have it" }
        let r = BlockRequest(piece: piece, offset: b * blockSize, length: pp.blockLength(b))
        let reqs = pp.requesters[b].compactMap { peersByID[$0] }.map { p -> String in
            var s = "\(p.address) \(p.clientName) " + String(format: "%.0fK/s q%d choked %d", p.rate / 1024, p.pending.count, p.peerChoking ? 1 : 0)
            if let pr = p.pending[r] {
                let older = p.pending.values.filter { $0.at < pr.at }.count
                s += " older \(older) delivered since \((p.downloadedBytes - pr.deliveredBefore) / Int64(blockSize)) prio \(pr.priority)"
            } else { s += " not pending" }
            return s
        }
        return String(format: "piece %d block %d: received %d, asked %.2fs ago, eta %+.2fs, ", piece, b, pp.received[b] ? 1 : 0,
                      now - pp.requestedAt[b], pp.eta[b] - now) + "\(spanInfo), \(holders) peers have it, requesters [\(reqs.joined(separator: ", "))]"
    }

    private func peersWithPiece(_ piece: Int) -> Int { peers.values.filter { $0.isActive && $0.has(piece) && !$0.peerChoking }.count }

    /// Downloaded fraction of a file split into `buckets` equal segments (for a "buffered" bar).
    public func availability(fileIndex: Int, buckets: Int) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count, buckets > 0 else { return [] }
        let file = info.files[fileIndex]
        guard file.length > 0 else { return Array(repeating: 1, count: buckets) }
        var out = [Double](repeating: 0, count: buckets)
        for b in 0..<buckets {
            let s = file.offset + file.length * Int64(b) / Int64(buckets)
            let e = max(s + 1, file.offset + file.length * Int64(b + 1) / Int64(buckets))
            let range = info.pieces(from: s, to: e)
            out[b] = Double(range.filter { have[$0] }.count) / Double(range.count)
        }
        return out
    }

    /// Magnet link for sharing this torrent.
    public var magnetLink: String {
        if let m = descriptor.magnetURI, m.lowercased().hasPrefix("magnet:") { return m }
        var s = "magnet:?xt=urn:btih:\(infoHashHex)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let n = descriptor.displayName ?? torrentInfo?.name { s += "&dn=" + (n.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        for t in descriptor.trackers.prefix(10) { s += "&tr=" + (t.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        return s
    }

    public func streamStatus(fileIndex: Int) -> StreamStatus {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else {
            return StreamStatus(readerOffset: nil, bufferedAhead: 0, fileProgress: 0, downloadRate: currentRate, connectedPeers: handshaked.count)
        }
        let file = info.files[fileIndex]
        let reader = readers.values.filter { $0.fileIndex == fileIndex }.max { $0.updated < $1.updated }
        var ahead: Int64 = 0
        if let r = reader {
            ahead = availablePrefixLocked(file.offset + r.offset, maxLength: file.length - r.offset)
        }
        let range = info.pieces(for: file)
        let haveInFile = range.filter { have[$0] }.count
        return StreamStatus(readerOffset: reader?.offset, bufferedAhead: max(0, ahead),
                            fileProgress: Double(haveInFile) / Double(range.count),
                            downloadRate: currentRate, connectedPeers: handshaked.count)
    }

    func makeAnnounceRequest(event: AnnounceRequest.Event) -> AnnounceRequest {
        lock.lock(); defer { lock.unlock() }
        var left: Int64 = 1 << 30
        if let info = info {
            var haveBytes: Int64 = 0
            for p in 0..<info.pieceCount where have[p] { haveBytes += Int64(info.pieceSize(p)) }
            left = info.totalLength - haveBytes
        }
        return AnnounceRequest(infoHash: infoHash, peerID: peerID, port: client?.announcePort ?? 6881, downloaded: downloadedTotal,
                               left: left, uploaded: uploadedTotal, event: event)
    }
}
