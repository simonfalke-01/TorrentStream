import Foundation

/// In-memory assembly buffer for a piece that is being downloaded.
final class PieceProgress {
    let index: Int
    let size: Int
    let blockCount: Int
    var buffer: Data
    var received: [Bool]
    var receivedCount = 0
    var requesters: [[ObjectIdentifier]]
    var requestedAt: [TimeInterval]

    init(index: Int, size: Int) {
        self.index = index
        self.size = size
        blockCount = (size + blockSize - 1) / blockSize
        buffer = Data(count: size)
        received = Array(repeating: false, count: blockCount)
        requesters = Array(repeating: [], count: blockCount)
        requestedAt = Array(repeating: 0, count: blockCount)
    }

    func blockLength(_ b: Int) -> Int { min(blockSize, size - b * blockSize) }

    func release(_ b: Int, peer: ObjectIdentifier) {
        guard b >= 0 && b < blockCount else { return }
        requesters[b].removeAll { $0 == peer }
    }
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

/// A single torrent: peer swarm, piece selection tuned for streaming, storage and blocking reads.
public final class Torrent {
    public let infoHash: Data
    public var infoHashHex: String { infoHash.hexString }
    public let descriptor: TorrentDescriptor
    let peerID: Data
    let directory: URL
    private weak var client: TorrentClient?

    let lock = NSCondition()

    // MARK: state guarded by `lock`
    private(set) var info: TorrentInfo?
    private var storage: Storage?
    private var have: [Bool] = []
    private var haveCount = 0
    private var inProgress: [Int: PieceProgress] = [:]
    private var verifying = Set<Int>()
    private var wantedFiles = Set<Int>()
    private var streamingFiles = Set<Int>()
    /// Bytes fetched past each reader of a file, beyond the urgent window. Missing = `defaultReadahead`.
    private var readahead: [Int: Int64] = [:]
    /// File whose start (and container index at the end) is loaded ahead of playback, and how many bytes of it.
    private var prefetchTarget: (fileIndex: Int, bytes: Int64)?

    /// `updated` is when the reader started or last moved to another piece, so the latest seek ranks first.
    private struct Reader { var fileIndex: Int; var offset: Int64; var piece: Int; var updated: Date }
    private var readers: [UUID: Reader] = [:]

    private var priorityOrder: [Int] = []
    private var urgentPieces = Set<Int>()
    /// The pieces right at each reader: what the player is blocked on.
    private var criticalPieces = Set<Int>()
    private var orderDirty = true

    private var peers: [PeerAddress: PeerConnection] = [:]
    private var handshaked = Set<ObjectIdentifier>()
    private var connectedAt: [ObjectIdentifier: Date] = [:]
    private var knownPeers = Set<PeerAddress>()
    private var peerQueue: [PeerAddress] = []
    private var retryAfter: [PeerAddress: Date] = [:]

    private var metadataSize: Int?
    private var metadataPieces: [Data?] = []
    private var metadataRequestedAt: [Int: Date] = [:]

    private var downloadedTotal: Int64 = 0
    private var bytesSinceTick = 0
    private var rateMeter = RateMeter()
    private var currentRate: Double = 0
    private var failure: String?
    private var stopped = false
    private var paused = false
    private var resumeDirty = false
    private var lastResumeSave = Date()
    private var lastDHTLookup = Date.distantPast
    private var trackers: [TrackerAnnouncer] = []

    let maxPeers = 60
    /// Tracker lists are mostly unreachable peers, so many connection attempts run at once.
    let maxConnecting = 40
    /// Bytes past a reader (capped by its urgent window) that are fetched before anything else, and raced between
    /// peers early.
    static let criticalBytes: Int64 = 2 * 1024 * 1024
    /// A block of a critical piece is re-requested from another peer when it hasn't arrived after this long.
    static let criticalRaceAfter: TimeInterval = 0.5

    init(descriptor: TorrentDescriptor, client: TorrentClient, directory: URL, peerID: Data) {
        self.descriptor = descriptor
        infoHash = descriptor.infoHash
        self.client = client
        self.directory = directory
        self.peerID = peerID
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    /// Disconnects from the swarm and stops all network activity until `resume()` (or a playback request).
    public func pause() {
        lock.lock()
        guard !paused else { lock.unlock(); return }
        paused = true
        let ps = Array(peers.values)
        saveResumeLocked()
        lock.unlock()
        ps.forEach { $0.close() }
    }

    public func resume() {
        lock.lock()
        let was = paused
        paused = false
        if was { retryAfter.removeAll() }
        lock.unlock()
        if was { trackers.forEach { $0.poke() } }
    }

    private var dataDirectory: URL { directory.appendingPathComponent("data", isDirectory: true) }
    private var infoFile: URL { directory.appendingPathComponent("info.bencode") }
    private var resumeFile: URL { directory.appendingPathComponent("resume.bin") }

    // MARK: lifecycle

    func start(extraTrackers: [String], useDHT: Bool) {
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        lock.lock()
        if let info = descriptor.info {
            setInfo(info)
        } else if let raw = try? Data(contentsOf: infoFile), let info = try? TorrentInfo(rawInfo: raw), info.infoHash == infoHash {
            setInfo(info)
        }
        var urls = descriptor.trackers
        for t in extraTrackers where !urls.contains(t) { urls.append(t) }
        trackers = urls.map { TrackerAnnouncer(url: $0, torrent: self) }
        lock.unlock()

        trackers.forEach { $0.start() }
        if useDHT { lookupDHT() }
        let t = Thread { [weak self] in
            while let s = self, s.tick() { Thread.sleep(forTimeInterval: 1) }
        }
        t.name = "torrent \(infoHashHex.prefix(8))"
        t.start()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let ps = Array(peers.values)
        saveResumeLocked()
        lock.broadcast()
        lock.unlock()
        trackers.forEach { $0.stop() }
        ps.forEach { $0.close() }
        storage?.closeAll()
    }

    private func lookupDHT() {
        guard let dht = client?.dht else { return }
        lastDHTLookup = Date()
        dht.findPeers(infoHash: infoHash) { [weak self] peers in self?.addPeers(peers, source: "dht") }
    }

    /// Periodic maintenance. Returns false once stopped.
    private func tick() -> Bool {
        lock.lock()
        if stopped { lock.unlock(); return false }
        rateMeter.add(bytesSinceTick)
        bytesSinceTick = 0
        currentRate = rateMeter.rate()
        if paused {
            if resumeDirty { saveResumeLocked() }
            lock.unlock()
            return true
        }

        let now = Date()
        let toStart = dequeuePeersLocked(now: now)
        for p in peers.values {
            // An idle peer gives no evidence about its speed, so its estimate only decays while it has work.
            let delta = Double(p.downloadedBytes - p.bytesAtLastTick)
            if delta > 0 || !p.pending.isEmpty { p.capacity = max(p.capacity * 0.95, delta) }
            p.bytesAtLastTick = p.downloadedBytes
        }

        if resumeDirty && now.timeIntervalSince(lastResumeSave) > 5 { saveResumeLocked() }

        let starving = handshaked.count < 8
        let dhtInterval: TimeInterval = starving ? 30 : 300
        let doDHT = client?.useDHT == true && now.timeIntervalSince(lastDHTLookup) > dhtInterval
        if doDHT { lastDHTLookup = now }
        let poke = starving && peerQueue.isEmpty
        lock.unlock()

        toStart.forEach { $0.start() }
        if doDHT { lookupDHT() }
        if poke { trackers.forEach { $0.poke() } }
        return true
    }

    /// Connection slots free right now.
    private func freeSlotsLocked() -> Int {
        guard !stopped, !paused else { return 0 }
        let connecting = peers.values.filter { !handshaked.contains(ObjectIdentifier($0)) }.count
        return max(0, min(maxPeers - peers.count, maxConnecting - connecting))
    }

    private func connectLocked(_ addr: PeerAddress, now: Date) -> PeerConnection {
        let conn = PeerConnection(address: addr, torrent: self)
        peers[addr] = conn
        connectedAt[ObjectIdentifier(conn)] = now
        return conn
    }

    /// Creates connections for queued peers while there are free slots. The caller starts them after unlocking.
    private func dequeuePeersLocked(now: Date) -> [PeerConnection] {
        var toStart: [PeerConnection] = []
        var budget = freeSlotsLocked()
        var scanned = 0
        let queueCount = peerQueue.count
        while budget > 0 && !peerQueue.isEmpty && scanned < queueCount {
            let addr = peerQueue.removeFirst()
            scanned += 1
            if let r = retryAfter[addr], r > now { peerQueue.append(addr); continue }
            if peers[addr] != nil { continue }
            toStart.append(connectLocked(addr, now: now))
            budget -= 1
        }
        return toStart
    }

    // MARK: peers

    /// Queues peers and connects to a few of them right away. Each list only gets a share of the free slots and the
    /// rest is shuffled into the queue, since one stale tracker list (common) would otherwise hold every slot until
    /// its connections time out. Peers learned from other peers are live, so they go first.
    public func addPeers(_ list: [PeerAddress], source: String) {
        lock.lock()
        var fresh: [PeerAddress] = []
        for p in list where !p.isPrivateOrInvalid && knownPeers.count < 3000 {
            if knownPeers.insert(p).inserted { fresh.append(p) }
        }
        fresh.shuffle()
        let now = Date()
        let immediate = min(fresh.count, freeSlotsLocked(), maxConnecting / 4)
        let toStart = fresh.prefix(immediate).map { connectLocked($0, now: now) }
        for p in fresh.dropFirst(immediate) {
            peerQueue.insert(p, at: source == "pex" ? 0 : Int.random(in: 0...peerQueue.count))
        }
        lock.unlock()
        toStart.forEach { $0.start() }
        if !fresh.isEmpty { log("\(infoHashHex.prefix(8)): +\(fresh.count) peers from \(source)") }
    }

    func peerConnected(_ peer: PeerConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        handshaked.insert(ObjectIdentifier(peer))
        connectedAt[ObjectIdentifier(peer)] = Date()
        if let info = info { peer.bitfield = Array(repeating: false, count: info.pieceCount) }
        return true
    }

    func peerDisconnected(_ peer: PeerConnection) {
        lock.lock()
        peerDisconnectedLocked(peer)
        let toStart = dequeuePeersLocked(now: Date())
        lock.unlock()
        toStart.forEach { $0.start() }
    }

    private func peerDisconnectedLocked(_ peer: PeerConnection) {
        let id = ObjectIdentifier(peer)
        peer.closed = true
        releaseRequestsLocked(peer)
        if peers[peer.address] === peer { peers[peer.address] = nil }
        let wasConnected = handshaked.remove(id) != nil
        connectedAt[id] = nil
        for (piece, _) in peer.metadataRequestedAt { metadataRequestedAt[piece] = nil }
        if !stopped {
            // Useful peers are retried soon; dead ones much later.
            retryAfter[peer.address] = Date().addingTimeInterval(peer.downloadedBytes > 0 ? 15 : (wasConnected ? 120 : 600))
            peerQueue.append(peer.address)
        }
    }

    private func releaseRequestsLocked(_ peer: PeerConnection) {
        let id = ObjectIdentifier(peer)
        for r in peer.pending { inProgress[r.piece]?.release(r.offset / blockSize, peer: id) }
        peer.pending.removeAll()
    }

    func peerChoked(_ peer: PeerConnection) {
        lock.lock(); defer { lock.unlock() }
        peer.peerChoking = true
        releaseRequestsLocked(peer)
    }

    func peerUnchoked(_ peer: PeerConnection) {
        lock.lock(); defer { lock.unlock() }
        peer.peerChoking = false
        peer.lastBlockAt = Date()
    }

    func peerHave(_ peer: PeerConnection, piece: Int) {
        lock.lock(); defer { lock.unlock() }
        if info != nil {
            if piece >= 0 && piece < peer.bitfield.count { peer.bitfield[piece] = true }
        } else {
            peer.pendingHaves.append(piece)
        }
    }

    func peerBitfield(_ peer: PeerConnection, data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let info = info { peer.bitfield = Torrent.decodeBitfield(data, count: info.pieceCount) }
        else { peer.rawBitfield = data }
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

    func ourBitfieldMessage() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard info != nil, haveCount > 0 else { return nil }
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

    func peerReportedMetadataSize(_ peer: PeerConnection, size: Int) {
        lock.lock(); defer { lock.unlock() }
        guard info == nil, metadataSize == nil, size > 0, size < 32 * 1024 * 1024 else { return }
        metadataSize = size
        metadataPieces = Array(repeating: nil, count: (size + 16383) / 16384)
    }

    func metadataPieceReply(_ piece: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = info?.rawInfo else { return nil }
        let start = piece * 16384
        guard start >= 0 && start < raw.count else { return nil }
        var reply = BValue.dict(["msg_type": .int(1), "piece": .int(Int64(piece)), "total_size": .int(Int64(raw.count))]).encoded()
        reply.append(raw.subdata(in: raw.startIndex + start ..< raw.startIndex + min(raw.count, start + 16384)))
        return reply
    }

    func metadataPieceRejected(_ peer: PeerConnection, piece: Int) {
        lock.lock(); defer { lock.unlock() }
        metadataRequestedAt[piece] = nil
        peer.metadataRequestedAt[piece] = nil
    }

    func metadataPieceReceived(_ peer: PeerConnection, piece: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
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
        } else {
            log("\(infoHashHex.prefix(8)): metadata hash mismatch, retrying")
            metadataPieces = Array(repeating: nil, count: metadataPieces.count)
        }
        metadataRequestedAt.removeAll()
    }

    /// Called with lock held.
    private func setInfo(_ info: TorrentInfo) {
        self.info = info
        have = Array(repeating: false, count: info.pieceCount)
        storage = Storage(root: dataDirectory, info: info)
        for p in peers.values {
            if let raw = p.rawBitfield { p.bitfield = Torrent.decodeBitfield(raw, count: info.pieceCount) }
            else if p.bitfield.count != info.pieceCount { p.bitfield = Array(repeating: false, count: info.pieceCount) }
            for h in p.pendingHaves where h >= 0 && h < info.pieceCount { p.bitfield[h] = true }
            p.rawBitfield = nil
            p.pendingHaves = []
        }
        orderDirty = true
        lock.broadcast()
        // Re-check pieces recorded in the resume file in the background.
        if let resume = try? Data(contentsOf: resumeFile), resume.count == info.pieceCount {
            let candidates = resume.enumerated().filter { $0.element == 1 }.map { $0.offset }
            verifying.formUnion(candidates)
            let storage = self.storage!
            Thread.detachNewThread { [weak self] in
                for idx in candidates {
                    guard let self = self, !self.isStopped else { return }
                    let ok = (try? storage.readPiece(idx)).map { SHA1.hash($0) == info.pieceHashes[idx] } ?? false
                    self.lock.lock()
                    self.verifying.remove(idx)
                    if ok && !self.have[idx] { self.have[idx] = true; self.haveCount += 1 }
                    self.orderDirty = true
                    self.lock.broadcast()
                    self.lock.unlock()
                }
            }
        }
    }

    private func saveResumeLocked() {
        guard info != nil else { return }
        try? Data(have.map { $0 ? 1 : 0 }).write(to: resumeFile, options: .atomic)
        resumeDirty = false
        lastResumeSave = Date()
    }

    // MARK: piece download

    func nextActions(for peer: PeerConnection, pipelineDepth: Int) -> PeerActions {
        lock.lock(); defer { lock.unlock() }
        var actions = PeerActions()
        if stopped { actions.disconnectReason = "stopped"; return actions }
        if paused { actions.disconnectReason = "paused"; return actions }
        let now = Date()

        guard let info = info else {
            // Fetch metadata from peers supporting ut_metadata.
            if let id = peer.utMetadataID, !metadataPieces.isEmpty, peer.metadataRequestedAt.count < 2 {
                for i in 0..<metadataPieces.count where metadataPieces[i] == nil {
                    if let t = metadataRequestedAt[i], now.timeIntervalSince(t) < 8 { continue }
                    metadataRequestedAt[i] = now
                    peer.metadataRequestedAt[i] = now
                    actions.metadataRequests.append((i, id))
                    if peer.metadataRequestedAt.count >= 2 { break }
                }
            }
            return actions
        }

        let peerHasWanted = peer.bitfield.count == info.pieceCount
        if !peer.amInterested && peerHasWanted && peer.bitfield.contains(true) {
            peer.amInterested = true
            actions.sendInterested = true
        }

        if !peer.pending.isEmpty && now.timeIntervalSince(peer.lastBlockAt) > 25 {
            actions.disconnectReason = "snubbed"
            return actions
        }
        if peer.peerChoking, let since = connectedAt[ObjectIdentifier(peer)], now.timeIntervalSince(since) > 120,
           peers.count >= maxPeers - 5 {
            actions.disconnectReason = "choked for too long"
            return actions
        }

        if !peer.peerChoking {
            if needsCriticalBlocks(from: peer, info: info, now: now) {
                // The player waits on blocks this peer could fetch (right after a seek, or a straggler worth racing):
                // drop its other requests so they are served next instead of after its whole queue.
                let me = ObjectIdentifier(peer)
                let stale = peer.pending.filter { !criticalPieces.contains($0.piece) }
                for r in stale {
                    peer.pending.remove(r)
                    inProgress[r.piece]?.release(r.offset / blockSize, peer: me)
                }
                actions.cancels = Array(stale)
            }
            if peer.pending.count < pipelineDepth / 2 {
                let wasIdle = peer.pending.isEmpty
                actions.requests = pickBlocks(for: peer, count: pipelineDepth - peer.pending.count, info: info, now: now)
                if wasIdle && !actions.requests.isEmpty { peer.lastBlockAt = now }
            }
        }
        return actions
    }

    /// Whether the peer has a block of a critical piece that nobody has been asked for, or that is overdue and
    /// may be raced by this peer, and the peer is below its share of critical blocks.
    private func needsCriticalBlocks(from peer: PeerConnection, info: TorrentInfo, now: Date) -> Bool {
        if orderDirty { rebuildOrder(info) }
        guard !criticalPieces.isEmpty,
              peer.pending.filter({ criticalPieces.contains($0.piece) }).count < criticalShareLocked(peer: peer) else { return false }
        let me = ObjectIdentifier(peer)
        let nowT = now.timeIntervalSinceReferenceDate
        for piece in criticalPieces where !have[piece] && !verifying.contains(piece) && piece < peer.bitfield.count && peer.bitfield[piece] {
            guard let pp = inProgress[piece] else { return true }
            for b in 0..<pp.blockCount where !pp.received[b] {
                let reqs = pp.requesters[b]
                if reqs.isEmpty { return true }
                if reqs.count < 3 && !reqs.contains(me) && nowT - pp.requestedAt[b] > Torrent.criticalRaceAfter { return true }
            }
        }
        return false
    }

    private func rebuildOrder(_ info: TorrentInfo) {
        orderDirty = false
        var order: [Int] = []
        var seen = Set<Int>()
        urgentPieces.removeAll()
        criticalPieces.removeAll()
        let window = max(4, min(64, (16 * 1024 * 1024) / info.pieceLength))

        func add(_ p: Int, urgent: Bool, critical: Bool = false) {
            guard p >= 0 && p < info.pieceCount, !have[p] else { return }
            if urgent { urgentPieces.insert(p) }
            if critical { criticalPieces.insert(p) }
            if seen.insert(p).inserted { order.append(p) }
        }

        let activeReaders = readers.values.sorted { $0.updated > $1.updated }
        // First what the player is blocked on, the latest seek first.
        for r in activeReaders {
            let file = info.files[r.fileIndex]
            let start = file.offset + r.offset
            let end = min(file.offset + file.length, start + Torrent.criticalBytes)
            guard end > start else { continue }
            for p in info.pieces(from: start, to: end) where p < r.piece + window { add(p, urgent: true, critical: true) }
        }
        // Container indexes live at the start/end of media files (MP4 moov, MKV cues): fetch them early.
        for fi in streamingFiles {
            let f = info.files[fi]
            let range = info.pieces(for: f)
            add(range.lowerBound, urgent: true)
            let tailStart = max(f.offset, f.offset + f.length - 2 * 1024 * 1024)
            for p in info.pieces(from: tailStart, to: f.offset + f.length) { add(p, urgent: true) }
        }
        for r in activeReaders {
            let file = info.files[r.fileIndex]
            let last = info.pieces(for: file).upperBound
            var p = r.piece
            while p <= min(last, r.piece + window - 1) { add(p, urgent: true); p += 1 }
        }
        // Then a bounded readahead past each reader, so playback survives slow patches without fetching the whole file.
        for r in activeReaders {
            let file = info.files[r.fileIndex]
            let ahead = readahead[r.fileIndex] ?? Torrent.defaultReadahead
            let end = min(file.offset + file.length, file.offset + r.offset + ahead)
            guard end > file.offset + r.offset else { continue }
            for p in info.pieces(from: file.offset + r.offset, to: end) { add(p, urgent: false) }
        }
        // Then the start of the file expected to play next, so it starts instantly.
        if let target = prefetchTarget, target.fileIndex < info.files.count {
            let f = info.files[target.fileIndex]
            if f.length > 0 {
                for p in info.pieces(from: f.offset, to: f.offset + min(f.length, max(1, target.bytes))) { add(p, urgent: false) }
                let tailStart = max(f.offset, f.offset + f.length - 2 * 1024 * 1024)
                for p in info.pieces(from: tailStart, to: f.offset + f.length) { add(p, urgent: false) }
            }
        }
        // Then the rest of each wanted file, sequentially from the reader position.
        let files = wantedFiles.sorted { a, b in
            let sa = streamingFiles.contains(a), sb = streamingFiles.contains(b)
            return sa != sb ? sa : a < b
        }
        for fi in files {
            let range = info.pieces(for: info.files[fi])
            let start = activeReaders.first(where: { $0.fileIndex == fi })?.piece ?? range.lowerBound
            for p in start...range.upperBound { add(p, urgent: false) }
            for p in range.lowerBound..<start { add(p, urgent: false) }
        }
        priorityOrder = order
    }

    /// Most blocks of critical pieces this peer may have outstanding: what it can deliver in half a second at its
    /// recent peak rate (a few while that's unknown). Fast peers take most of what the player waits on, slow or
    /// stalled ones can't hold much of it, and every peer comes back for more as it delivers.
    private func criticalShareLocked(peer: PeerConnection) -> Int {
        peer.capacity > 0 ? max(1, Int(peer.capacity / 2) / blockSize) : 4
    }

    private func pickBlocks(for peer: PeerConnection, count: Int, info: TorrentInfo, now: Date) -> [BlockRequest] {
        if orderDirty { rebuildOrder(info) }
        let me = ObjectIdentifier(peer)
        let nowT = now.timeIntervalSinceReferenceDate
        let maxInProgress = max(6, min(handshaked.count + 6, (128 * 1024 * 1024) / info.pieceLength))
        var criticalHeld = 0
        var criticalShare = Int.max
        if !criticalPieces.isEmpty {
            criticalHeld = peer.pending.filter { criticalPieces.contains($0.piece) }.count
            criticalShare = criticalShareLocked(peer: peer)
        }
        var out: [BlockRequest] = []
        for piece in priorityOrder {
            if out.count >= count { break }
            if have[piece] || verifying.contains(piece) || !peer.bitfield[piece] { continue }
            let urgent = urgentPieces.contains(piece)
            let critical = criticalPieces.contains(piece)
            // Blocks the player waits on are raced against a second peer sooner.
            let raceAfter: TimeInterval = critical ? Torrent.criticalRaceAfter : 3
            let pp: PieceProgress
            if let existing = inProgress[piece] {
                pp = existing
            } else {
                if !urgent && inProgress.count >= maxInProgress { continue }
                pp = PieceProgress(index: piece, size: info.pieceSize(piece))
                inProgress[piece] = pp
            }
            for b in 0..<pp.blockCount where out.count < count && !pp.received[b] {
                if critical && criticalHeld >= criticalShare { break }
                let reqs = pp.requesters[b]
                if reqs.contains(me) { continue }
                if !reqs.isEmpty {
                    // Near the playhead, race a slow block against another peer.
                    guard urgent, reqs.count < 3, nowT - pp.requestedAt[b] > raceAfter else { continue }
                }
                pp.requesters[b].append(me)
                pp.requestedAt[b] = nowT
                let r = BlockRequest(piece: piece, offset: b * blockSize, length: pp.blockLength(b))
                peer.pending.insert(r)
                out.append(r)
                if critical { criticalHeld += 1 }
            }
            // Peers serve requests in order: while critical blocks are unassigned, keep this peer's queue short so
            // it takes more of them as soon as it has room.
            if critical && criticalHeld >= criticalShare,
               (0..<pp.blockCount).contains(where: { !pp.received[$0] && pp.requesters[$0].isEmpty }) { break }
        }
        return out
    }

    func blockReceived(_ peer: PeerConnection, piece: Int, offset: Int, data: Data) {
        lock.lock()
        peer.pending.remove(BlockRequest(piece: piece, offset: offset, length: data.count))
        peer.lastBlockAt = Date()
        peer.downloadedBytes += Int64(data.count)
        bytesSinceTick += data.count
        downloadedTotal += Int64(data.count)
        guard let pp = inProgress[piece], offset % blockSize == 0 else { lock.unlock(); return }
        let b = offset / blockSize
        guard b < pp.blockCount, data.count == pp.blockLength(b), !pp.received[b] else { lock.unlock(); return }
        pp.buffer.replaceSubrange(offset ..< offset + data.count, with: data)
        pp.received[b] = true
        pp.receivedCount += 1
        pp.requesters[b] = []
        let complete = pp.receivedCount == pp.blockCount
        if complete {
            inProgress[piece] = nil
            verifying.insert(piece)
        }
        let storage = self.storage
        let expected = info?.pieceHashes[piece]
        lock.unlock()

        guard complete, let storage = storage, let expected = expected else { return }
        let ok = SHA1.hash(pp.buffer) == expected
        var writeError: String?
        if ok {
            do { try storage.writePiece(piece, data: pp.buffer) } catch { writeError = "\(error)" }
        }
        lock.lock()
        verifying.remove(piece)
        if ok && writeError == nil && !have[piece] {
            have[piece] = true
            haveCount += 1
            resumeDirty = true
            if urgentPieces.contains(piece) || priorityOrder.first == piece { orderDirty = true }
        } else if let e = writeError {
            failure = "Disk write failed: \(e)"
        } else if !ok {
            log("piece \(piece) failed hash check")
        }
        orderDirty = orderDirty || !ok
        lock.broadcast()
        lock.unlock()
    }

    // MARK: public API

    /// Readahead past a reader when none was set for its file: about 10 minutes of 1080p video.
    public static let defaultReadahead: Int64 = 256 * 1024 * 1024

    /// How far past the playback position a file is loaded in the background (`nil` restores the default).
    /// Only applies while the file is being read; nothing beyond it is fetched.
    public func setReadahead(_ bytes: Int64?, fileIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        readahead[fileIndex] = bytes.map { max(0, $0) }
        orderDirty = true
    }

    /// Loads the first `bytes` of a file (plus its container index at the end) at low priority, replacing any
    /// earlier prefetch. Resumes a paused torrent.
    public func prefetch(fileIndex: Int, bytes: Int64) {
        lock.lock()
        prefetchTarget = (fileIndex, bytes)
        orderDirty = true
        lock.unlock()
        resume()
    }

    public func cancelPrefetch() {
        lock.lock(); defer { lock.unlock() }
        prefetchTarget = nil
        orderDirty = true
    }

    /// Every piece of the first `bytes` of a file (and of its last 2 MB) is on disk.
    public func hasPrefix(fileIndex: Int, bytes: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { return false }
        let f = info.files[fileIndex]
        guard f.length > 0 else { return true }
        let head = info.pieces(from: f.offset, to: f.offset + min(f.length, max(1, bytes)))
        let tail = info.pieces(from: max(f.offset, f.offset + f.length - 2 * 1024 * 1024), to: f.offset + f.length)
        return head.allSatisfy { have[$0] } && tail.allSatisfy { have[$0] }
    }

    /// Marks a whole file for background download, or stops downloading it. Streaming doesn't need this:
    /// readers fetch what they read plus the readahead.
    public func setWanted(_ wanted: Bool, fileIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        if wanted { wantedFiles.insert(fileIndex) } else { wantedFiles.remove(fileIndex); streamingFiles.remove(fileIndex) }
        orderDirty = true
    }

    public func setAllWanted(_ wanted: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let info = info else { return }
        if wanted { wantedFiles = Set(info.files.filter { !$0.isPadding }.map { $0.index }) } else { wantedFiles.removeAll(); streamingFiles.removeAll() }
        orderDirty = true
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

    /// Registers a streaming reader at `offset` of a file and blocks until `length` bytes from there are on disk.
    /// Returns false on timeout (the reader stays registered so priorities keep following it).
    public func waitForData(fileIndex: Int, offset: Int64, length: Int, readerID: UUID, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        guard let info = info, fileIndex >= 0, fileIndex < info.files.count else { throw TorrentError.io("no such file") }
        let file = info.files[fileIndex]
        let start = file.offset + offset
        let end = min(file.offset + file.length, start + Int64(max(length, 1)))
        let range = info.pieces(from: start, to: end)
        if paused && !range.allSatisfy({ have[$0] }) {
            // Playing something un-pauses the torrent.
            paused = false
            retryAfter.removeAll()
            let ts = trackers
            DispatchQueue.global().async { ts.forEach { $0.poke() } }
        }
        let moved = readers[readerID].map { $0.piece != range.lowerBound || $0.fileIndex != fileIndex } ?? true
        if moved { orderDirty = true }
        readers[readerID] = Reader(fileIndex: fileIndex, offset: offset, piece: range.lowerBound,
                                   updated: moved ? Date() : readers[readerID]!.updated)
        if streamingFiles.insert(fileIndex).inserted { orderDirty = true }
        while true {
            if stopped { throw TorrentError.stopped }
            if let f = failure { throw TorrentError.io(f) }
            if range.allSatisfy({ have[$0] }) { return true }
            if !lock.wait(until: deadline) { return false }
        }
    }

    public func removeReader(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if readers.removeValue(forKey: id) != nil { orderDirty = true }
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

    public func status() -> TorrentStatus {
        lock.lock(); defer { lock.unlock() }
        var files: [FileStatus] = []
        var downloaded: Int64 = 0
        if let info = info {
            for f in info.files {
                var bytes: Int64 = 0
                if f.length > 0 {
                    for p in info.pieces(for: f) where have[p] {
                        let ps = Int64(p) * Int64(info.pieceLength)
                        let pe = ps + Int64(info.pieceSize(p))
                        bytes += min(pe, f.offset + f.length) - max(ps, f.offset)
                    }
                }
                files.append(FileStatus(file: f, downloadedBytes: bytes, wanted: wantedFiles.contains(f.index)))
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
            let fileEnd = file.offset + file.length
            var p = r.piece
            while p < info.pieceCount && have[p] {
                let pe = min(fileEnd, Int64(p) * Int64(info.pieceLength) + Int64(info.pieceSize(p)))
                ahead = pe - (file.offset + r.offset)
                if pe >= fileEnd { break }
                p += 1
            }
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
        return AnnounceRequest(infoHash: infoHash, peerID: peerID, port: 6881, downloaded: downloadedTotal,
                               left: left, uploaded: 0, event: event)
    }
}
