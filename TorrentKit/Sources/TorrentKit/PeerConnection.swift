import Foundation

struct BlockRequest: Hashable {
    let piece: Int
    let offset: Int
    let length: Int
}

let blockSize = 16 * 1024

/// One connection to a remote peer, driven by its own thread.
/// State marked "torrent lock" is only touched while holding `Torrent.lock`.
final class PeerConnection {
    let address: PeerAddress
    private weak var torrent: Torrent?
    private var socket: TCPSocket?
    private var buffer = Data()

    // torrent lock
    var peerChoking = true
    var amInterested = false
    var bitfield: [Bool] = []
    var rawBitfield: Data?
    var pendingHaves: [Int] = []
    var pending = Set<BlockRequest>()
    var lastBlockAt = Date()
    var downloadedBytes: Int64 = 0
    /// Recent peak download rate from this peer in bytes/s, decaying while it is slow (updated by the torrent's tick).
    var capacity: Double = 0
    var bytesAtLastTick: Int64 = 0
    var supportsExtensions = false
    var utMetadataID: Int?
    var utPexID: Int?
    var metadataRequestedAt: [Int: Date] = [:]
    var closed = false
    var clientName = ""

    private var lastSend = Date()
    private let pipelineDepth = 48

    init(address: PeerAddress, torrent: Torrent) {
        self.address = address
        self.torrent = torrent
    }

    func start() {
        let t = Thread { [self] in self.run() }
        t.name = "peer \(address)"
        t.stackSize = 256 * 1024
        t.start()
    }

    func close() {
        socket?.close()
    }

    // MARK: main loop

    private func run() {
        defer {
            socket?.close()
            torrent?.peerDisconnected(self)
        }
        guard let torrent = torrent else { return }
        do {
            // Reachable peers answer within a second or two; most tracker entries never do.
            let sock = try TCPSocket.connect(to: address, timeout: 4)
            socket = sock
            sock.setSendTimeout(30)
            sock.setReceiveTimeout(4)
            try handshake(torrent: torrent)
            // Short, so new priorities (a seek) reach idle peers quickly.
            sock.setReceiveTimeout(0.2)
            guard torrent.peerConnected(self) else { return }
            if supportsExtensions { try sendExtendedHandshake(torrent: torrent) }
            if let bf = torrent.ourBitfieldMessage() { try send(bf) }

            while true {
                if torrent.isStopped || closed { return }
                if let data = try sock.receive() {
                    buffer.append(data)
                    try processBuffer(torrent: torrent)
                }
                try housekeeping(torrent: torrent)
            }
        } catch {
            log("peer \(address) closed: \(error)")
        }
    }

    private func handshake(torrent: Torrent) throws {
        var hs = Data([19])
        hs.append(contentsOf: Array("BitTorrent protocol".utf8))
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10 // extension protocol (BEP 10)
        hs.append(contentsOf: reserved)
        hs.append(torrent.infoHash)
        hs.append(torrent.peerID)
        try socket!.send(hs)
        let resp = try socket!.receiveExactly(68, deadline: Date().addingTimeInterval(8))
        guard resp[resp.startIndex] == 19,
              resp.subdata(in: resp.startIndex + 1 ..< resp.startIndex + 20) == Data("BitTorrent protocol".utf8) else {
            throw TorrentError.io("bad handshake")
        }
        guard resp.subdata(in: resp.startIndex + 28 ..< resp.startIndex + 48) == torrent.infoHash else {
            throw TorrentError.io("info-hash mismatch")
        }
        supportsExtensions = resp[resp.startIndex + 25] & 0x10 != 0
        let peerID = resp.subdata(in: resp.startIndex + 48 ..< resp.startIndex + 68)
        if peerID == torrent.peerID { throw TorrentError.io("connected to self") }
        clientName = String(decoding: peerID.prefix(8), as: UTF8.self)
    }

    private func processBuffer(torrent: Torrent) throws {
        var consumed = 0
        let bytes = buffer
        let base = bytes.startIndex
        while bytes.count - consumed >= 4 {
            let len = Int(bytes.readUInt32BE(at: consumed))
            guard len <= 4 * 1024 * 1024 else { throw TorrentError.io("message too large (\(len))") }
            guard bytes.count - consumed - 4 >= len else { break }
            if len > 0 {
                let id = bytes[base + consumed + 4]
                let payload = bytes.subdata(in: base + consumed + 5 ..< base + consumed + 4 + len)
                try handleMessage(id: id, payload: payload, torrent: torrent)
            }
            consumed += 4 + len
        }
        if consumed > 0 { buffer = bytes.subdata(in: base + consumed ..< bytes.endIndex) }
    }

    private func handleMessage(id: UInt8, payload: Data, torrent: Torrent) throws {
        switch id {
        case 0: torrent.peerChoked(self)
        case 1: torrent.peerUnchoked(self)
        case 2, 3: break // we never upload pieces, so their interest doesn't matter
        case 4:
            guard payload.count >= 4 else { return }
            torrent.peerHave(self, piece: Int(payload.readUInt32BE(at: 0)))
        case 5:
            torrent.peerBitfield(self, data: payload)
        case 6, 8: break // requests/cancels: we don't serve pieces
        case 7:
            guard payload.count >= 8 else { return }
            let piece = Int(payload.readUInt32BE(at: 0))
            let offset = Int(payload.readUInt32BE(at: 4))
            let block = payload.subdata(in: payload.startIndex + 8 ..< payload.endIndex)
            torrent.blockReceived(self, piece: piece, offset: offset, data: block)
        case 20:
            guard let ext = payload.first else { return }
            try handleExtended(ext, payload: payload.dropFirst(), torrent: torrent)
        default: break
        }
    }

    // MARK: extension protocol

    static let ourUtMetadataID = 1
    static let ourUtPexID = 2

    private func sendExtendedHandshake(torrent: Torrent) throws {
        var d: [String: BValue] = [
            "m": .dict(["ut_metadata": .int(Int64(Self.ourUtMetadataID)), "ut_pex": .int(Int64(Self.ourUtPexID))]),
            "v": .str("TorrentStream 1.0"),
            "reqq": .int(500),
        ]
        if let size = torrent.metadataSizeIfKnown { d["metadata_size"] = .int(Int64(size)) }
        try sendExtended(id: 0, payload: BValue.dict(d).encoded())
    }

    func sendExtended(id: Int, payload: Data) throws {
        var msg = Data([20, UInt8(id)])
        msg.append(payload)
        try send(message: msg)
    }

    private func handleExtended(_ ext: UInt8, payload: Data, torrent: Torrent) throws {
        if ext == 0 {
            guard let hs = try? BDecoder.decode(payload) else { return }
            if let m = hs["m"] {
                if let v = m["ut_metadata"]?.int, v > 0 { utMetadataID = Int(v) }
                if let v = m["ut_pex"]?.int, v > 0 { utPexID = Int(v) }
            }
            if let v = hs["v"]?.string { clientName = v }
            if let size = hs["metadata_size"]?.int { torrent.peerReportedMetadataSize(self, size: Int(size)) }
        } else if Int(ext) == Self.ourUtMetadataID {
            var dec = BDecoder(payload)
            guard let header = try? dec.decode(), let type = header["msg_type"]?.int, let piece = header["piece"]?.int else { return }
            switch type {
            case 0: // request: serve metadata if we have it
                if let id = utMetadataID, let reply = torrent.metadataPieceReply(Int(piece)) { try sendExtended(id: id, payload: reply) }
            case 1:
                let data = payload.subdata(in: payload.startIndex + dec.position ..< payload.endIndex)
                torrent.metadataPieceReceived(self, piece: Int(piece), data: data)
            default:
                torrent.metadataPieceRejected(self, piece: Int(piece))
            }
        } else if Int(ext) == Self.ourUtPexID {
            guard let msg = try? BDecoder.decode(payload), let added = msg["added"]?.data else { return }
            torrent.addPeers(PeerAddress.parseCompactList(added), source: "pex")
        }
    }

    // MARK: sending

    private func housekeeping(torrent: Torrent) throws {
        let actions = torrent.nextActions(for: self, pipelineDepth: pipelineDepth)
        if let err = actions.disconnectReason { throw TorrentError.io(err) }
        var out = Data()
        if actions.sendInterested {
            out.appendBE(UInt32(1)); out.append(2)
        }
        for r in actions.cancels {
            out.appendBE(UInt32(13)); out.append(8)
            out.appendBE(UInt32(r.piece)); out.appendBE(UInt32(r.offset)); out.appendBE(UInt32(r.length))
        }
        for r in actions.requests {
            out.appendBE(UInt32(13)); out.append(6)
            out.appendBE(UInt32(r.piece)); out.appendBE(UInt32(r.offset)); out.appendBE(UInt32(r.length))
        }
        for (piece, id) in actions.metadataRequests {
            let p = BValue.dict(["msg_type": .int(0), "piece": .int(Int64(piece))]).encoded()
            out.appendBE(UInt32(2 + p.count)); out.append(20); out.append(UInt8(id)); out.append(p)
        }
        if out.isEmpty && Date().timeIntervalSince(lastSend) > 90 {
            out.appendBE(UInt32(0)) // keep-alive
        }
        if !out.isEmpty { try socket?.send(out); lastSend = Date() }
    }

    /// Sends a complete message body (without length prefix).
    func send(message: Data) throws {
        var d = Data()
        d.appendBE(UInt32(message.count))
        d.append(message)
        try socket?.send(d)
        lastSend = Date()
    }

    /// Sends a pre-framed message.
    func send(_ framed: Data) throws {
        try socket?.send(framed)
        lastSend = Date()
    }
}

struct PeerActions {
    var sendInterested = false
    var requests: [BlockRequest] = []
    var cancels: [BlockRequest] = []
    var metadataRequests: [(Int, Int)] = []
    var disconnectReason: String?
}
