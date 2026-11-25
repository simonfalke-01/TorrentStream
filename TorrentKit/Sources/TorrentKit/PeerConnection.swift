import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct BlockRequest: Hashable {
    let piece: Int
    let offset: Int
    let length: Int
}

let blockSize = 16 * 1024

/// An outstanding request: when it was sent, when it should arrive, and how urgent it was.
struct PendingRequest {
    let at: TimeInterval
    let eta: TimeInterval
    var priority: Int
    /// The peer's downloaded byte count when this was requested: requests are answered in order, so what it delivered
    /// since tells how far it got (see `expectedArrivalLocked`).
    var deliveredBefore: Int64 = 0
    /// Requests of this peer outstanding when this one was sent.
    var queuedAhead = 0
    /// Position in the order requests were sent to the peer.
    var seq = 0
    /// Bytes between the reader position (or the start of the want) and the block when it was requested: how long
    /// the player could wait for it. `Int64.max` for blocks nobody reads soon.
    var distance: Int64 = .max
}

/// What the scheduler wants sent to a peer.
struct PeerActions {
    var sendInterested = false
    var requests: [BlockRequest] = []
    var cancels: [BlockRequest] = []
    var metadataRequests: [(Int, Int)] = []
    var disconnectReason: String?
}

/// One connection to a remote peer: a non-blocking socket driven by the client's event loop.
/// I/O state is touched only on the loop thread; state marked "torrent lock" only while holding `Torrent.lock`.
final class PeerConnection: LoopHandler {
    enum Phase { case idle, connecting, handshaking, active, closed }

    let address: PeerAddress
    private weak var torrent: Torrent?
    private(set) var fd: Int32 = -1
    private(set) var phase = Phase.idle

    // loop thread
    private var inbuf = [UInt8](repeating: 0, count: 64 * 1024)
    private var inLen = 0
    private var outbuf: [UInt8] = []
    private var outStart = 0
    /// Our bitfield went out with the handshake (ahead of early requests).
    private var sentBitfield = false
    private(set) var lastSendAt = Date.timeIntervalSinceReferenceDate

    // torrent lock
    var peerChoking = true
    var amInterested = false
    var bitfield: [Bool] = []
    var rawBitfield: Data?
    var pendingHaveAll = false
    var pendingHaves: [Int] = []
    var pending: [BlockRequest: PendingRequest] = [:]
    /// Requests sent with our handshake, before knowing whether the peer has the pieces or unchokes us (see
    /// `Torrent.earlyRequestsLocked`): a reject or a missing piece just releases them.
    var early = Set<BlockRequest>()
    /// Requests we cancelled and the peer hasn't answered yet (with the fast extension it answers each with the
    /// block or a reject). Not re-requested from this peer meanwhile: libtorrent ignores a request that duplicates one
    /// still queued, and the reject for the cancel would otherwise be taken for a reject of the new request.
    /// Also holds requests the peer rejected, so they go to other peers for a while.
    var cancelled: [BlockRequest: TimeInterval] = [:]
    /// Cancelled requests a peer with the fast extension may have sent already: the block stays assigned to it until
    /// it arrives or the peer rejects the request, so it isn't downloaded twice.
    var cancelHeld = Set<BlockRequest>()
    var lastBlockAt = Date.timeIntervalSinceReferenceDate
    var downloadedBytes: Int64 = 0
    /// Recent peak download rate from this peer in bytes/s, decaying while it is slow.
    var rate: Double = 0
    var bytesAtLastSample: Int64 = 0
    /// Requests kept outstanding while the peer's rate is still being found out. It grows by one per block received
    /// (doubling every round trip, like TCP slow start) until a rate sample shows no gain: a queue sized from the
    /// measured rate alone only grows as fast as the rate it limits.
    var window = 32
    var windowGrowing = true
    var rateSamples = 0
    /// Numbers requests in the order they were sent (a peer answers them in that order).
    var requestSeq = 0
    /// Connect round trip, a floor for how soon a request can be answered.
    var rtt: TimeInterval = 0.3
    /// How soon the peer answers a request once the blocks before it are sent: round trip plus its disk, without
    /// the queues on the way (lowest recent value). Its queue only needs to cover that at its rate; more waits in
    /// buffers in front of the next urgent block. Nil until measured.
    var answerTime: TimeInterval?
    var supportsExtensions = false
    var supportsFast = false
    /// The peer wants to download from us.
    var peerInterested = false
    /// We refuse its requests; unchoked only while a download reciprocates.
    var amChoking = true
    var uploadedBytes: Int64 = 0
    /// The peer connected to our listener.
    private(set) var isIncoming = false
    var utMetadataID: Int?
    var utPexID: Int?
    var maxRequests = 250
    var allowedFast = Set<Int>()
    var metadataRequestedAt: [Int: Date] = [:]
    var closed = false
    var snubbed = false
    var clientName = ""
    var startedAt = Date.timeIntervalSinceReferenceDate
    var connectedAt: TimeInterval?
    var firstUnchokeAt: TimeInterval?
    var chokedSince = Date.timeIntervalSinceReferenceDate
    var hashFailures = 0

    init(address: PeerAddress, torrent: Torrent) {
        self.address = address
        self.torrent = torrent
    }

    var wantsWrite: Bool { phase == .connecting || outStart < outbuf.count }
    var isActive: Bool { phase == .active }

    func has(_ piece: Int) -> Bool { piece >= 0 && piece < bitfield.count && bitfield[piece] }

    // MARK: lifecycle (loop thread)

    /// Starts a non-blocking connect; the loop reports completion as writability.
    func startConnect(loop: EventLoop) {
        guard phase == .idle else { return }
        startedAt = Date.timeIntervalSinceReferenceDate
        do {
            fd = try Net.startConnect(to: address)
            phase = .connecting
            loop.add(self)
        } catch {
            close(reason: "\(error)")
        }
    }

    /// Closes the socket; the torrent forgets the peer. Safe to call more than once.
    func close(reason: String) {
        guard phase != .closed else { return }
        phase = .closed
        if fd >= 0 {
            _ = Glue.close(fd)
            fd = -1
        }
        outbuf = []
        log("peer \(address) closed: \(reason)")
        torrent?.peerDisconnected(self)
    }

    func handleEvents(_ revents: Int16) {
        if phase == .connecting {
            if revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0 { finishConnect() }
            return
        }
        if revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 { readAvailable() }
        if phase != .closed && revents & Int16(POLLOUT) != 0 { flush() }
    }

    /// Takes over a socket our listener accepted, with what the peer sent so far (at least the start of its
    /// handshake). Loop thread.
    func adoptIncoming(fd: Int32, received: [UInt8], loop: EventLoop) {
        guard phase == .idle, let torrent else { _ = Glue.close(fd); return }
        self.fd = fd
        isIncoming = true
        startedAt = Date.timeIntervalSinceReferenceDate
        phase = .handshaking
        if inbuf.count < received.count { inbuf = [UInt8](repeating: 0, count: max(64 * 1024, received.count)) }
        inbuf.replaceSubrange(0..<received.count, with: received)
        inLen = received.count
        enqueue(Self.handshake(torrent))
        loop.add(self)
        if inLen >= 68 { processInput() }
        flush()
    }

    private static func handshake(_ torrent: Torrent) -> [UInt8] {
        var hs = [UInt8]()
        hs.reserveCapacity(68)
        hs.append(19)
        hs.append(contentsOf: Array("BitTorrent protocol".utf8))
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10 // extension protocol (BEP 10)
        reserved[7] |= 0x04 // fast extension (BEP 6)
        hs.append(contentsOf: reserved)
        hs.append(contentsOf: torrent.infoHash)
        hs.append(contentsOf: torrent.peerID)
        return hs
    }

    private func finishConnect() {
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else { close(reason: "connect: \(String(cString: strerror(err)))"); return }
        guard let torrent = torrent else { close(reason: "torrent gone"); return }
        rtt = max(0.02, Date.timeIntervalSinceReferenceDate - startedAt)
        phase = .handshaking
        enqueue(Self.handshake(torrent))
        // Requests for what the player waits on go out with the handshake, a round trip before the peer's bitfield
        // and unchoke would allow them: peers that unchoke right away (most seeders) answer them at once. Our
        // bitfield has to come first.
        let early = torrent.earlyRequests(for: self)
        if !early.isEmpty, let bitfield = torrent.ourBitfieldMessage(orEmpty: true) {
            sentBitfield = true
            enqueue([UInt8](bitfield))
            var out: [UInt8] = [0, 0, 0, 1, 2]
            for r in early {
                out.append(contentsOf: [0, 0, 0, 13, 6])
                for v in [r.piece, r.offset, r.length] {
                    out.append(contentsOf: [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
                }
            }
            enqueue(out)
        }
        flush()
    }

    // MARK: reading

    private func readAvailable() {
        var total = 0
        while phase != .closed {
            if inbuf.count - inLen < 32 * 1024 { inbuf.append(contentsOf: [UInt8](repeating: 0, count: max(64 * 1024, inbuf.count))) }
            let space = inbuf.count - inLen
            let n = inbuf.withUnsafeMutableBytes { raw in Glue.recv(fd, raw.baseAddress! + inLen, space, 0) }
            if n > 0 {
                inLen += n
                total += n
                // Bounded per wake-up so one fast peer can't starve the rest.
                if total >= 1 << 20 { break }
                continue
            }
            if n == 0 { close(reason: "eof"); return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            close(reason: "recv: \(Net.lastError)")
            return
        }
        if total > 0 { processInput() }
    }

    private func processInput() {
        guard let torrent = torrent else { close(reason: "torrent gone"); return }
        var consumed = 0
        if phase == .handshaking {
            guard inLen >= 68 else { return }
            let hs = Data(inbuf[0..<68])
            consumed = 68
            guard hs[0] == 19, hs[1..<20] == Data("BitTorrent protocol".utf8) else { close(reason: "bad handshake"); return }
            guard hs[28..<48] == torrent.infoHash else { close(reason: "info-hash mismatch"); return }
            let peerID = hs.subdata(in: 48..<68)
            if peerID == torrent.peerID { close(reason: "connected to self"); return }
            supportsExtensions = hs[25] & 0x10 != 0
            supportsFast = hs[27] & 0x04 != 0
            clientName = String(decoding: peerID.prefix(8), as: UTF8.self)
            guard torrent.peerConnected(self) else { close(reason: "not accepted"); return }
            phase = .active
            if supportsExtensions { sendExtendedHandshake(torrent: torrent) }
            if sentBitfield {}
            else if let bf = torrent.ourBitfieldMessage() { enqueue([UInt8](bf)) }
            else if supportsFast { enqueueMessage([0x0F]) } // have_none
        }
        guard phase == .active else { return }

        var error: String?
        torrent.lock.lock()
        inbuf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while inLen - consumed >= 4 && error == nil && phase == .active {
                let p = base + consumed
                let len = Int(UInt32(p.load(fromByteOffset: 0, as: UInt8.self)) << 24 | UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) << 16
                    | UInt32(p.load(fromByteOffset: 2, as: UInt8.self)) << 8 | UInt32(p.load(fromByteOffset: 3, as: UInt8.self)))
                guard len <= 2 * 1024 * 1024 else { error = "message too large (\(len))"; break }
                guard inLen - consumed - 4 >= len else { break }
                if len > 0 {
                    let id = p.load(fromByteOffset: 4, as: UInt8.self)
                    let payload = UnsafeRawBufferPointer(start: p + 5, count: len - 1)
                    error = handleMessageLocked(id: id, payload: payload, torrent: torrent)
                }
                consumed += 4 + len
            }
        }
        if error == nil && phase == .active {
            let actions = torrent.nextActionsLocked(for: self)
            apply(actions)
        }
        torrent.lock.unlock()
        if consumed > 0 {
            let remaining = inLen - consumed
            if remaining > 0 {
                inbuf.withUnsafeMutableBytes { raw in _ = memmove(raw.baseAddress!, raw.baseAddress! + consumed, remaining) }
            }
            inLen = remaining
            if inbuf.count > 256 * 1024 && inLen < 64 * 1024 { inbuf = Array(inbuf[0..<max(64 * 1024, inLen)]) }
        }
        if let e = error { close(reason: e); return }
        torrent.flushPeersAfterEvent()
        flush()
    }

    private static func u32(_ b: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3]))
    }

    /// Returns a reason to disconnect, if any. Torrent lock held.
    private func handleMessageLocked(id: UInt8, payload: UnsafeRawBufferPointer, torrent: Torrent) -> String? {
        switch id {
        case 0: torrent.peerChokedLocked(self)
        case 1: torrent.peerUnchokedLocked(self)
        case 2:
            peerInterested = true
            // A free upload slot goes to it now rather than at the next choke round.
            if amChoking && torrent.hasFreeUploadSlotLocked() { setChoking(false) }
        case 3: peerInterested = false
        case 4:
            guard payload.count >= 4 else { return nil }
            torrent.peerHaveLocked(self, piece: Self.u32(payload, 0))
        case 5:
            torrent.peerBitfieldLocked(self, data: Data(payload))
        case 6:
            // Served while we unchoke the peer (downloads reciprocate); refused otherwise, which the fast extension
            // has to say explicitly.
            guard payload.count >= 12 else { return nil }
            let r = BlockRequest(piece: Self.u32(payload, 0), offset: Self.u32(payload, 4), length: Self.u32(payload, 8))
            if !amChoking, outbuf.count - outStart < Self.maxQueuedUpload, let data = torrent.uploadBlockLocked(r) {
                enqueuePiece(r, data)
            } else if supportsFast {
                var m: [UInt8] = [0x10]
                m.append(contentsOf: Array(payload[0..<12]))
                enqueueMessage(m)
            }
        case 7:
            guard payload.count >= 8 else { return nil }
            let piece = Self.u32(payload, 0), offset = Self.u32(payload, 4)
            torrent.blockReceivedLocked(self, piece: piece, offset: offset,
                                        data: UnsafeRawBufferPointer(rebasing: payload[8...]))
        case 8: break
        case 0x0D: break // suggest piece
        case 0x0E: torrent.peerHaveAllLocked(self)
        case 0x0F: torrent.peerBitfieldLocked(self, data: Data())
        case 0x10:
            guard payload.count >= 12 else { return nil }
            torrent.requestRejectedLocked(self, BlockRequest(piece: Self.u32(payload, 0), offset: Self.u32(payload, 4),
                                                             length: Self.u32(payload, 8)))
        case 0x11:
            guard payload.count >= 4 else { return nil }
            allowedFast.insert(Self.u32(payload, 0))
        case 20:
            guard let ext = payload.first else { return nil }
            handleExtendedLocked(ext, payload: Data(payload.dropFirst()), torrent: torrent)
        default: break
        }
        return nil
    }

    // MARK: extension protocol (BEP 10)

    static let ourUtMetadataID = 1
    static let ourUtPexID = 2

    private func sendExtendedHandshake(torrent: Torrent) {
        var d: [String: BValue] = [
            "m": .dict(["ut_metadata": .int(Int64(Self.ourUtMetadataID)), "ut_pex": .int(Int64(Self.ourUtPexID))]),
            "v": .str("TorrentStream 2.0"),
            "reqq": .int(500),
        ]
        // Where we listen, so peers that learn of us through PEX can connect.
        if let port = torrent.client?.announcePort { d["p"] = .int(Int64(port)) }
        if let size = torrent.metadataSizeIfKnown { d["metadata_size"] = .int(Int64(size)) }
        sendExtended(id: 0, payload: BValue.dict(d).encoded())
    }

    func sendExtended(id: Int, payload: Data) {
        var m: [UInt8] = [20, UInt8(id)]
        m.append(contentsOf: payload)
        enqueueMessage(m)
    }

    private func handleExtendedLocked(_ ext: UInt8, payload: Data, torrent: Torrent) {
        if ext == 0 {
            guard let hs = try? BDecoder.decode(payload) else { return }
            if let m = hs["m"] {
                if let v = m["ut_metadata"]?.int, v > 0 { utMetadataID = Int(v) }
                if let v = m["ut_pex"]?.int, v > 0 { utPexID = Int(v) }
            }
            if let v = hs["v"]?.string { clientName = v }
            if let q = hs["reqq"]?.int, q > 0 { maxRequests = max(8, min(500, Int(q))) }
            if let size = hs["metadata_size"]?.int { torrent.peerReportedMetadataSizeLocked(self, size: Int(size)) }
        } else if Int(ext) == Self.ourUtMetadataID {
            var dec = BDecoder(payload)
            guard let header = try? dec.decode(), let type = header["msg_type"]?.int, let piece = header["piece"]?.int else { return }
            switch type {
            case 0:
                if let id = utMetadataID, let reply = torrent.metadataPieceReplyLocked(Int(piece)) { sendExtended(id: id, payload: reply) }
            case 1:
                let data = payload.subdata(in: payload.startIndex + dec.position ..< payload.endIndex)
                torrent.metadataPieceReceivedLocked(self, piece: Int(piece), data: data)
            default:
                torrent.metadataPieceRejectedLocked(self, piece: Int(piece))
            }
        } else if Int(ext) == Self.ourUtPexID {
            guard let msg = try? BDecoder.decode(payload), let added = msg["added"]?.data else { return }
            torrent.queuePexPeers(PeerAddress.parseCompactList(added))
        }
    }

    // MARK: writing (loop thread)

    /// Queues the scheduler's messages. Torrent lock held (or the peer isn't shared yet).
    func apply(_ actions: PeerActions) {
        if let reason = actions.disconnectReason {
            torrent?.deferClose(self, reason: reason)
            return
        }
        guard phase == .active else { return }
        var out = [UInt8]()
        out.reserveCapacity(5 + 17 * (actions.requests.count + actions.cancels.count))
        func be32(_ v: Int) { out.append(UInt8(truncatingIfNeeded: v >> 24)); out.append(UInt8(truncatingIfNeeded: v >> 16)); out.append(UInt8(truncatingIfNeeded: v >> 8)); out.append(UInt8(truncatingIfNeeded: v)) }
        if actions.sendInterested { be32(1); out.append(2) }
        for r in actions.cancels { be32(13); out.append(8); be32(r.piece); be32(r.offset); be32(r.length) }
        for r in actions.requests { be32(13); out.append(6); be32(r.piece); be32(r.offset); be32(r.length) }
        for (piece, id) in actions.metadataRequests {
            let p = BValue.dict(["msg_type": .int(0), "piece": .int(Int64(piece))]).encoded()
            be32(2 + p.count); out.append(20); out.append(UInt8(id)); out.append(contentsOf: p)
        }
        if !out.isEmpty { enqueue(out) }
    }

    func enqueueCancel(_ r: BlockRequest) {
        var m: [UInt8] = [8]
        for v in [r.piece, r.offset, r.length] { m.append(contentsOf: [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]) }
        enqueueMessage(m)
    }

    func enqueueKeepAlive() { enqueue([0, 0, 0, 0]) }

    /// Output waiting past this means the peer's link is full; further requests are refused until it drains.
    static let maxQueuedUpload = 1024 * 1024

    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// Loop thread: tells the peer whether it may request from us.
    func setChoking(_ choke: Bool) {
        guard amChoking != choke else { return }
        amChoking = choke
        enqueueMessage([choke ? 0 : 1])
    }

    func enqueueHave(_ piece: Int) { enqueueMessage([4] + Self.be32(piece)) }

    private func enqueuePiece(_ r: BlockRequest, _ data: Data) {
        var m: [UInt8] = [7]
        m.reserveCapacity(9 + data.count)
        m += Self.be32(r.piece) + Self.be32(r.offset)
        m.append(contentsOf: data)
        enqueueMessage(m)
        uploadedBytes += Int64(data.count)
    }

    private func enqueueMessage(_ body: [UInt8]) {
        let n = body.count
        enqueue([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)] + body)
    }

    private func enqueue(_ bytes: [UInt8]) {
        guard phase != .closed else { return }
        if outStart > 0 && outStart == outbuf.count { outbuf.removeAll(keepingCapacity: true); outStart = 0 }
        outbuf.append(contentsOf: bytes)
    }

    /// Writes as much queued output as the socket takes.
    func flush() {
        guard fd >= 0, phase == .handshaking || phase == .active else { return }
        while outStart < outbuf.count {
            let n = outbuf.withUnsafeBytes { raw in Glue.send(fd, raw.baseAddress! + outStart, outbuf.count - outStart, Net.sendFlags) }
            if n > 0 { outStart += n; lastSendAt = Date.timeIntervalSinceReferenceDate; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            close(reason: "send: \(Net.lastError)")
            return
        }
        if outStart == outbuf.count { outbuf.removeAll(keepingCapacity: outbuf.count < 64 * 1024); outStart = 0 }
    }
}
