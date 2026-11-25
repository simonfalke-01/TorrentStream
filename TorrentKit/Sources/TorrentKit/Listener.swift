import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Glibc)
private let LISTEN_SOCK_STREAM = Int32(SOCK_STREAM.rawValue)
#else
private let LISTEN_SOCK_STREAM = SOCK_STREAM
#endif

/// Accepts connections from peers that found us through trackers, the DHT or PEX. Most of a swarm can only be
/// reached this way (peers behind NAT connect out but can't be connected to), so listening adds peers no outgoing
/// connection would. Runs on the client's event loop.
final class PeerListener: LoopHandler {
    private(set) var fd: Int32 = -1
    private(set) var port: UInt16 = 0
    private weak var client: TorrentClient?
    private let loop: EventLoop
    /// Accepted sockets whose handshake hasn't arrived yet. Loop thread.
    private var pending: [IncomingPeer] = []
    private var aborted = 0

    static let handshakeTimeout: TimeInterval = 10
    static let maxPending = 64

    var wantsWrite: Bool { false }

    init(client: TorrentClient, loop: EventLoop) {
        self.client = client
        self.loop = loop
    }

    /// Binds every interface on `preferred` (the port used last time, so peers that learned it still reach us), else
    /// another. Returns the port.
    @discardableResult
    func open(preferred: UInt16) -> UInt16? {
        var candidates: [UInt16] = preferred != 0 ? [preferred] : []
        for _ in 0..<8 { candidates.append(UInt16.random(in: 20000...60000)) }
        candidates.append(0)
        for p in candidates {
            if let (fd, bound) = Self.bind(port: p) {
                self.fd = fd
                port = bound
                loop.add(self)
                loop.addTicker(owner: self, interval: 5) { [weak self] in
                    guard let self else { return nil }
                    self.prune()
                    return 5
                }
                return bound
            }
        }
        return nil
    }

    private static func bind(port: UInt16) -> (Int32, UInt16)? {
        let fd = socket(AF_INET, LISTEN_SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var sa = PeerAddress(ip: 0, port: port).sockaddr
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 128) == 0 else { _ = Glue.close(fd); return nil }
        Net.setNonBlocking(fd)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    /// Loop thread: brings the socket back on the same port (iOS reclaims listening sockets of suspended apps).
    func reopen() {
        if fd >= 0 { _ = Glue.close(fd); fd = -1 }
        if let (fd, _) = Self.bind(port: port) {
            self.fd = fd
            loop.add(self)
        } else {
            log("listener: port \(port) could not be reopened")
        }
    }

    func close() {
        if fd >= 0 { _ = Glue.close(fd); fd = -1 }
        for p in pending { p.drop() }
        pending.removeAll()
    }

    func handleEvents(_ revents: Int16) {
        while fd >= 0 {
            var sa = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.accept(fd, $0, &len) }
            }
            if c < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                // A reclaimed listener reports aborted connections forever.
                aborted += 1
                if errno != ECONNABORTED || aborted > 20 { aborted = 0; reopen() }
                return
            }
            aborted = 0
            Net.setNonBlocking(c)
            Net.setNoSigPipe(c)
            var one: Int32 = 1
            setsockopt(c, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            pending.removeAll { $0.fd < 0 }
            guard pending.count < Self.maxPending, let client else { _ = Glue.close(c); continue }
            let peer = IncomingPeer(fd: c, address: PeerAddress(sockaddr: sa), client: client)
            pending.append(peer)
            loop.add(peer)
        }
    }

    /// Drops connections that never sent a handshake.
    private func prune() {
        let now = Date.timeIntervalSinceReferenceDate
        for p in pending where p.fd >= 0 && now - p.acceptedAt > Self.handshakeTimeout { p.drop() }
        pending.removeAll { $0.fd < 0 }
    }
}

/// An accepted socket until its handshake names a torrent; then the torrent takes the socket over.
final class IncomingPeer: LoopHandler {
    private(set) var fd: Int32
    let address: PeerAddress
    let acceptedAt = Date.timeIntervalSinceReferenceDate
    private weak var client: TorrentClient?
    private var buf: [UInt8] = []

    var wantsWrite: Bool { false }

    init(fd: Int32, address: PeerAddress, client: TorrentClient) {
        self.fd = fd
        self.address = address
        self.client = client
    }

    func drop() {
        if fd >= 0 { _ = Glue.close(fd); fd = -1 }
    }

    func handleEvents(_ revents: Int16) {
        var chunk = [UInt8](repeating: 0, count: 68)
        while fd >= 0 && buf.count < 68 {
            let want = 68 - buf.count
            let n = chunk.withUnsafeMutableBytes { Glue.recv(fd, $0.baseAddress!, want, 0) }
            if n > 0 { buf.append(contentsOf: chunk[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            drop()
            return
        }
        guard fd >= 0, buf.count >= 48 else { return }
        guard buf[0] == 19, Array(buf[1..<20]) == Array("BitTorrent protocol".utf8) else { drop(); return }
        let hash = Data(buf[28..<48])
        guard let torrent = client?.torrent(infoHashHex: hash.hexString),
              torrent.acceptIncoming(fd: fd, address: address, received: buf) else {
            drop()
            return
        }
        // The torrent's connection owns the socket now.
        fd = -1
    }
}
