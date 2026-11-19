import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnnounceRequest {
    let infoHash: Data
    let peerID: Data
    let port: UInt16
    let downloaded: Int64
    let left: Int64
    let uploaded: Int64
    let event: Event

    enum Event: UInt32 { case none = 0, completed = 1, started = 2, stopped = 3 }
}

struct AnnounceResponse {
    let interval: TimeInterval
    let peers: [PeerAddress]
}

/// HTTP(S) and UDP tracker client (BEP 3, BEP 15, BEP 23).
enum TrackerClient {
    static func announce(url: String, request: AnnounceRequest) throws -> AnnounceResponse {
        if url.lowercased().hasPrefix("udp://") { return try announceUDP(url: url, request: request) }
        if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") {
            return try announceHTTP(url: url, request: request)
        }
        throw TorrentError.io("unsupported tracker \(url)")
    }

    // MARK: HTTP

    static func percentEncodeBytes(_ data: Data) -> String {
        var s = ""
        for b in data {
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || "-_.~".contains(c) {
                s.append(c)
            } else {
                s += String(format: "%%%02X", b)
            }
        }
        return s
    }

    private static func announceHTTP(url: String, request r: AnnounceRequest) throws -> AnnounceResponse {
        var q = "info_hash=\(percentEncodeBytes(r.infoHash))&peer_id=\(percentEncodeBytes(r.peerID))"
        q += "&port=\(r.port)&uploaded=\(r.uploaded)&downloaded=\(r.downloaded)&left=\(r.left)&compact=1&numwant=200"
        switch r.event {
        case .started: q += "&event=started"
        case .completed: q += "&event=completed"
        case .stopped: q += "&event=stopped"
        case .none: break
        }
        let full = url + (url.contains("?") ? "&" : "?") + q
        guard let u = URL(string: full) else { throw TorrentError.io("bad tracker url") }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("TorrentStream/1.0", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var failure: Error?
        let task = URLSession.shared.dataTask(with: req) { data, _, error in
            body = data; failure = error; sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 25) == .timedOut { task.cancel(); throw TorrentError.timeout }
        if let e = failure { throw e }
        guard let data = body else { throw TorrentError.io("empty tracker response") }
        let value = try BDecoder.decode(data)
        if let reason = value["failure reason"]?.string { throw TorrentError.io("tracker: \(reason)") }
        var peers: [PeerAddress] = []
        if let compact = value["peers"]?.data {
            peers = PeerAddress.parseCompactList(compact)
        } else if let list = value["peers"]?.list {
            for p in list {
                guard let ip = p["ip"]?.string, let port = p["port"]?.int else { continue }
                let parts = ip.split(separator: ".").compactMap { UInt32($0) }
                guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { continue }
                peers.append(PeerAddress(ip: parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3], port: UInt16(clamping: port)))
            }
        }
        let interval = TimeInterval(value["interval"]?.int ?? 1800)
        return AnnounceResponse(interval: interval, peers: peers)
    }

    // MARK: UDP (BEP 15)

    private static func announceUDP(url: String, request r: AnnounceRequest) throws -> AnnounceResponse {
        guard let comps = URLComponents(string: url), let host = comps.host, let port = comps.port else {
            throw TorrentError.io("bad udp tracker url")
        }
        guard let addr = Net.resolve(host: host, port: UInt16(port)).first else { throw TorrentError.io("cannot resolve \(host)") }
        let sock = try UDPSocket()

        func transact(_ packet: Data, expectAction: UInt32, txid: UInt32, attempts: Int) throws -> Data {
            for attempt in 0..<attempts {
                sock.setReceiveTimeout(Double(3 + attempt * 3))
                sock.send(packet, to: addr)
                let deadline = Date().addingTimeInterval(Double(3 + attempt * 3))
                while Date() < deadline {
                    guard let (resp, _) = sock.receive() else { break }
                    guard resp.count >= 8, resp.readUInt32BE(at: 4) == txid else { continue }
                    let action = resp.readUInt32BE(at: 0)
                    if action == 3 {
                        throw TorrentError.io("tracker error: \(String(decoding: resp.dropFirst(8), as: UTF8.self))")
                    }
                    if action == expectAction { return resp }
                }
            }
            throw TorrentError.timeout
        }

        var txid = UInt32.random(in: 0...UInt32.max)
        var connect = Data()
        connect.appendBE(UInt64(0x41727101980))
        connect.appendBE(UInt32(0))
        connect.appendBE(txid)
        let connResp = try transact(connect, expectAction: 0, txid: txid, attempts: 2)
        guard connResp.count >= 16 else { throw TorrentError.io("short connect response") }
        let connID = connResp.subdata(in: connResp.startIndex + 8 ..< connResp.startIndex + 16)

        txid = UInt32.random(in: 0...UInt32.max)
        var ann = Data()
        ann.append(connID)
        ann.appendBE(UInt32(1))
        ann.appendBE(txid)
        ann.append(r.infoHash)
        ann.append(r.peerID)
        ann.appendBE(UInt64(r.downloaded))
        ann.appendBE(UInt64(r.left))
        ann.appendBE(UInt64(r.uploaded))
        ann.appendBE(r.event.rawValue)
        ann.appendBE(UInt32(0))                       // ip
        ann.appendBE(UInt32.random(in: 0...UInt32.max)) // key
        ann.appendBE(UInt32(bitPattern: -1))          // num_want
        ann.appendBE(r.port)
        let resp = try transact(ann, expectAction: 1, txid: txid, attempts: 2)
        guard resp.count >= 20 else { throw TorrentError.io("short announce response") }
        let interval = TimeInterval(resp.readUInt32BE(at: 8))
        let peers = PeerAddress.parseCompactList(resp.subdata(in: resp.startIndex + 20 ..< resp.endIndex))
        return AnnounceResponse(interval: interval, peers: peers)
    }
}

/// Periodically announces to one tracker on a background thread.
final class TrackerAnnouncer {
    private let url: String
    private weak var torrent: Torrent?
    private var stopped = false
    private let cond = NSCondition()
    private var forceAnnounce = false

    init(url: String, torrent: Torrent) {
        self.url = url
        self.torrent = torrent
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "tracker \(url)"
        t.start()
    }

    func stop() {
        cond.lock(); stopped = true; cond.broadcast(); cond.unlock()
    }

    /// Requests a re-announce soon (e.g. when the torrent is starving for peers).
    func poke() {
        cond.lock(); forceAnnounce = true; cond.broadcast(); cond.unlock()
    }

    private func run() {
        var event = AnnounceRequest.Event.started
        var failures = 0
        while true {
            cond.lock(); let isStopped = stopped; forceAnnounce = false; cond.unlock()
            guard !isStopped, let torrent = torrent else { return }
            let req = torrent.makeAnnounceRequest(event: event)
            var wait: TimeInterval
            do {
                let resp = try TrackerClient.announce(url: url, request: req)
                log("tracker \(url): \(resp.peers.count) peers, interval \(resp.interval)")
                torrent.addPeers(resp.peers, source: "tracker")
                event = .none
                failures = 0
                wait = min(max(resp.interval, 60), 1800)
            } catch {
                failures += 1
                log("tracker \(url) failed: \(error)")
                wait = min(30 * pow(2, Double(min(failures, 5))), 1800)
            }
            let deadline = Date().addingTimeInterval(wait)
            // A starving torrent may poke us, but never re-announce more often than every 60s.
            let earliest = Date().addingTimeInterval(min(wait, 60))
            cond.lock()
            while !stopped && Date() < deadline {
                if forceAnnounce && Date() >= earliest { break }
                _ = cond.wait(until: min(deadline, Date().addingTimeInterval(5)))
            }
            cond.unlock()
        }
    }
}
