import Foundation

/// Minimal Mainline DHT client (BEP 5) that performs iterative `get_peers` lookups.
/// It only queries; it does not store or announce, which is enough to find peers for magnet links.
final class DHT {
    static let bootstrapHosts: [(String, UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        ("dht.libtorrent.org", 25401),
        ("dht.aelitis.com", 6881),
    ]

    private struct Node: Hashable { let id: Data; let address: PeerAddress }

    private final class Lookup {
        let infoHash: Data
        let started = Date()
        var candidates: [Node] = []          // sorted by distance, closest first
        var queried = Set<PeerAddress>()
        var inFlight: [PeerAddress: Date] = [:]
        var responded = 0
        var peers = Set<PeerAddress>()
        let onPeers: ([PeerAddress]) -> Void
        init(infoHash: Data, onPeers: @escaping ([PeerAddress]) -> Void) { self.infoHash = infoHash; self.onPeers = onPeers }
    }

    private let nodeID = Data.random(count: 20)
    private var socket: UDPSocket?
    private let lock = NSLock()
    private var lookups: [Lookup] = []
    private var transactions: [Data: (Lookup?, PeerAddress)] = [:]
    private var goodNodes: [Node] = []
    private var bootstrapAddresses: [PeerAddress] = []
    private var running = false
    private var nextTxid: UInt16 = 0

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.run() }
        t.name = "dht"
        t.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    /// Starts a lookup; `onPeers` is called (on the DHT thread) as peers are discovered.
    func findPeers(infoHash: Data, onPeers: @escaping ([PeerAddress]) -> Void) {
        let l = Lookup(infoHash: infoHash, onPeers: onPeers)
        lock.lock()
        lookups.removeAll { $0.infoHash == infoHash }
        seed(l)
        lookups.append(l)
        lock.unlock()
    }

    private func seed(_ l: Lookup) {
        for n in goodNodes { insert(n, into: l) }
        for a in bootstrapAddresses where !l.candidates.contains(where: { $0.address == a }) {
            // Unknown ID: use the target itself so bootstrap nodes are queried first.
            l.candidates.insert(Node(id: l.infoHash, address: a), at: 0)
        }
    }

    private func insert(_ n: Node, into l: Lookup) {
        guard !l.queried.contains(n.address), !l.candidates.contains(where: { $0.address == n.address }) else { return }
        let d = DHT.distance(n.id, l.infoHash)
        let idx = l.candidates.firstIndex { DHT.distance($0.id, l.infoHash).lexicographicallyPrecedes(d) == false } ?? l.candidates.count
        l.candidates.insert(n, at: idx)
        if l.candidates.count > 200 { l.candidates.removeLast(l.candidates.count - 200) }
    }

    static func distance(_ a: Data, _ b: Data) -> [UInt8] {
        zip(a, b).map { $0 ^ $1 }
    }

    private func run() {
        do { socket = try UDPSocket() } catch { log("dht: socket failed \(error)"); return }
        socket?.setReceiveTimeout(0.2)
        var resolved: [PeerAddress] = []
        for (h, p) in DHT.bootstrapHosts { resolved += Net.resolve(host: h, port: p) }
        lock.lock()
        bootstrapAddresses = resolved
        for l in lookups { seed(l) }
        lock.unlock()
        log("dht: bootstrap nodes \(resolved.count)")

        while true {
            lock.lock()
            let isRunning = running
            lock.unlock()
            if !isRunning { return }
            pump()
            if let (data, from) = socket?.receive() { handle(data, from: from) }
        }
    }

    private func pump() {
        var toSend: [(Data, PeerAddress)] = []
        let now = Date()
        lock.lock()
        for l in lookups {
            for (a, t) in l.inFlight where now.timeIntervalSince(t) > 3 { l.inFlight[a] = nil }
            while l.inFlight.count < 8, !l.candidates.isEmpty, l.queried.count < 400 {
                let n = l.candidates.removeFirst()
                if l.queried.contains(n.address) { continue }
                l.queried.insert(n.address)
                l.inFlight[n.address] = now
                let tid = makeTxid()
                transactions[tid] = (l, n.address)
                let msg = BValue.dict([
                    "t": .bytes(tid), "y": .str("q"), "q": .str("get_peers"),
                    "a": .dict(["id": .bytes(nodeID), "info_hash": .bytes(l.infoHash)]),
                ]).encoded()
                toSend.append((msg, n.address))
            }
        }
        lookups.removeAll { l in
            let done = (l.candidates.isEmpty && l.inFlight.isEmpty) || now.timeIntervalSince(l.started) > 45 || l.queried.count >= 400
            if done { log("dht: lookup done, queried \(l.queried.count), responses \(l.responded), peers \(l.peers.count)") }
            return done
        }
        if transactions.count > 4000 { transactions.removeAll() }
        lock.unlock()
        for (m, a) in toSend { socket?.send(m, to: a) }
    }

    private func makeTxid() -> Data {
        nextTxid &+= 1
        var d = Data(); d.appendBE(nextTxid); return d
    }

    private func handle(_ data: Data, from: PeerAddress) {
        guard let msg = try? BDecoder.decode(data), let y = msg["y"]?.string else { return }
        if y == "q" {
            // Answer pings so other nodes keep us around; ignore other queries.
            if msg["q"]?.string == "ping", let t = msg["t"]?.data {
                let r = BValue.dict(["t": .bytes(t), "y": .str("r"), "r": .dict(["id": .bytes(nodeID)])]).encoded()
                socket?.send(r, to: from)
            }
            return
        }
        guard y == "r", let t = msg["t"]?.data, let r = msg["r"] else { return }
        lock.lock()
        guard let (lookup, _) = transactions.removeValue(forKey: t) else { lock.unlock(); return }
        var newPeers: [PeerAddress] = []
        if let id = r["id"]?.data, id.count == 20 {
            let node = Node(id: id, address: from)
            if !goodNodes.contains(where: { $0.address == from }) {
                goodNodes.append(node)
                if goodNodes.count > 300 { goodNodes.removeFirst(goodNodes.count - 300) }
            }
        }
        if let l = lookup {
            l.inFlight[from] = nil
            l.responded += 1
            for v in r["values"]?.list ?? [] {
                if let d = v.data, let p = PeerAddress(compact: d), l.peers.insert(p).inserted { newPeers.append(p) }
            }
            if let nodes = r["nodes"]?.data {
                var i = 0
                while i + 26 <= nodes.count {
                    let base = nodes.startIndex + i
                    let id = nodes.subdata(in: base ..< base + 20)
                    if let addr = PeerAddress(compact: nodes.subdata(in: base + 20 ..< base + 26)), !addr.isPrivateOrInvalid {
                        insert(Node(id: id, address: addr), into: l)
                    }
                    i += 26
                }
            }
        }
        lock.unlock()
        if let l = lookup, !newPeers.isEmpty { l.onPeers(newPeers) }
    }
}
