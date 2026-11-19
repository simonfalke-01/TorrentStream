import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Glibc)
private let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
private let SOCK_DGRAM_VALUE = Int32(SOCK_DGRAM.rawValue)
private let SEND_FLAGS = Int32(MSG_NOSIGNAL)
#else
private let SOCK_STREAM_VALUE = SOCK_STREAM
private let SOCK_DGRAM_VALUE = SOCK_DGRAM
private let SEND_FLAGS: Int32 = 0
#endif

enum SocketError: Error {
    case failed(String)
    case closed
    case timeout
}

/// IPv4 peer/node address.
public struct PeerAddress: Hashable, CustomStringConvertible {
    /// IPv4 address bytes in network order (a.b.c.d -> a is the most significant byte).
    public let ip: UInt32
    public let port: UInt16

    public init(ip: UInt32, port: UInt16) { self.ip = ip; self.port = port }

    /// Parses a 6-byte compact peer entry.
    init?(compact: Data) {
        guard compact.count >= 6 else { return nil }
        ip = compact.readUInt32BE(at: 0)
        port = compact.readUInt16BE(at: 4)
        guard ip != 0, port != 0 else { return nil }
    }

    init(sockaddr sa: sockaddr_in) {
        ip = UInt32(bigEndian: sa.sin_addr.s_addr)
        port = UInt16(bigEndian: sa.sin_port)
    }

    static func parseCompactList(_ data: Data) -> [PeerAddress] {
        var out: [PeerAddress] = []
        var i = 0
        while i + 6 <= data.count {
            if let p = PeerAddress(compact: data.subdata(in: data.startIndex + i ..< data.startIndex + i + 6)) { out.append(p) }
            i += 6
        }
        return out
    }

    var compact: Data {
        var d = Data()
        d.appendBE(ip)
        d.appendBE(port)
        return d
    }

    var sockaddr: sockaddr_in {
        var sa = sockaddr_in()
        #if canImport(Darwin)
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr.s_addr = ip.bigEndian
        return sa
    }

    public var description: String {
        "\(ip >> 24).\((ip >> 16) & 0xff).\((ip >> 8) & 0xff).\(ip & 0xff):\(port)"
    }

    var isPrivateOrInvalid: Bool {
        let a = ip >> 24
        return a == 0 || a >= 224
    }
}

enum Net {
    static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// Resolves a host name to IPv4 addresses.
    static func resolve(host: String, port: UInt16) -> [PeerAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM_VALUE
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        var out: [PeerAddress] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            if ai.pointee.ai_family == AF_INET, let addr = ai.pointee.ai_addr {
                let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let p = PeerAddress(sockaddr: sin)
                if !out.contains(p) { out.append(p) }
            }
            cur = ai.pointee.ai_next
        }
        return out
    }

    static func setTimeout(_ fd: Int32, option: Int32, seconds: Double) {
        var tv = timeval()
        tv.tv_sec = Int(seconds)
        #if canImport(Darwin)
        tv.tv_usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        #else
        tv.tv_usec = Int((seconds - Double(Int(seconds))) * 1_000_000)
        #endif
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setNoSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static var lastError: String { String(cString: strerror(errno)) }

    static func isTimeoutErrno(_ e: Int32) -> Bool { e == EAGAIN || e == EWOULDBLOCK || e == EINTR }
}

/// Blocking TCP socket with timeouts.
final class TCPSocket {
    private(set) var fd: Int32
    private let closeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        Net.setNoSigPipe(fd)
    }

    deinit { close() }

    static func connect(to address: PeerAddress, timeout: Double) throws -> TCPSocket {
        let fd = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard fd >= 0 else { throw SocketError.failed("socket: \(Net.lastError)") }
        let sock = TCPSocket(fd: fd)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var sa = address.sockaddr
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { throw SocketError.failed("connect: \(Net.lastError)") }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(timeout * 1000))
            if pr == 0 { throw SocketError.timeout }
            guard pr > 0 else { throw SocketError.failed("poll: \(Net.lastError)") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw SocketError.failed("connect: \(String(cString: strerror(err)))") }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return sock
    }

    func setReceiveTimeout(_ seconds: Double) { Net.setTimeout(fd, option: SO_RCVTIMEO, seconds: seconds) }
    func setSendTimeout(_ seconds: Double) { Net.setTimeout(fd, option: SO_SNDTIMEO, seconds: seconds) }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Glue.send(fd, base + sent, raw.count - sent, SEND_FLAGS)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
                    throw SocketError.closed
                }
                if n == 0 { throw SocketError.closed }
                sent += n
            }
        }
    }

    /// Reads available bytes (up to `max`). Returns nil on timeout, throws when the connection closed.
    func receive(max: Int = 65536) throws -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { Glue.recv(fd, $0.baseAddress, max, 0) }
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 { throw SocketError.closed }
        if Net.isTimeoutErrno(errno) { return nil }
        throw SocketError.closed
    }

    /// Reads exactly `count` bytes or throws.
    func receiveExactly(_ count: Int, deadline: Date) throws -> Data {
        var out = Data()
        while out.count < count {
            if Date() > deadline { throw SocketError.timeout }
            if let d = try receive(max: count - out.count) { out.append(d) }
        }
        return out
    }

    /// True if the peer has closed its side (non-blocking check).
    func isPeerClosed() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, 0)
        if r <= 0 { return false }
        if pfd.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
        var b: UInt8 = 0
        let n = Glue.recv(fd, &b, 1, Int32(MSG_PEEK) | MSG_DONTWAIT_VALUE)
        return n == 0
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        if fd >= 0 {
            _ = Glue.shutdown(fd, Int32(SHUT_RDWR_VALUE))
            _ = Glue.close(fd)
            fd = -1
        }
    }
}

#if canImport(Glibc)
private let MSG_DONTWAIT_VALUE = Int32(MSG_DONTWAIT)
private let SHUT_RDWR_VALUE = Int32(SHUT_RDWR)
#else
private let MSG_DONTWAIT_VALUE = MSG_DONTWAIT
private let SHUT_RDWR_VALUE = SHUT_RDWR
#endif

/// Listening TCP socket bound to the loopback interface.
final class TCPListener {
    private(set) var fd: Int32 = -1
    private(set) var port: UInt16 = 0

    init(port requested: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard fd >= 0 else { throw SocketError.failed("socket: \(Net.lastError)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var sa = PeerAddress(ip: 0x7f00_0001, port: requested).sockaddr
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = Net.lastError; _ = Glue.close(fd); throw SocketError.failed("bind: \(e)") }
        guard listen(fd, 64) == 0 else { let e = Net.lastError; _ = Glue.close(fd); throw SocketError.failed("listen: \(e)") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
    }

    /// Blocks until a client connects. Returns nil for transient errors, throws for fatal ones.
    func accept() throws -> TCPSocket? {
        let c = Glue.accept(fd, nil, nil)
        if c >= 0 { return TCPSocket(fd: c) }
        if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { return nil }
        throw SocketError.failed("accept: \(Net.lastError)")
    }

    func close() {
        if fd >= 0 { _ = Glue.shutdown(fd, Int32(SHUT_RDWR_VALUE)); _ = Glue.close(fd); fd = -1 }
    }
}

/// Unconnected UDP socket.
final class UDPSocket {
    let fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM_VALUE, 0)
        guard fd >= 0 else { throw SocketError.failed("socket: \(Net.lastError)") }
        var sa = PeerAddress(ip: 0, port: 0).sockaddr
        _ = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    deinit { _ = Glue.close(fd) }

    func setReceiveTimeout(_ seconds: Double) { Net.setTimeout(fd, option: SO_RCVTIMEO, seconds: seconds) }

    func send(_ data: Data, to address: PeerAddress) {
        var sa = address.sockaddr
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glue.sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Returns nil on timeout.
    func receive() -> (Data, PeerAddress)? {
        var buf = [UInt8](repeating: 0, count: 65536)
        var sa = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buf.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.recvfrom(fd, raw.baseAddress, 65536, 0, $0, &len) }
            }
        }
        guard n > 0 else { return nil }
        return (Data(buf[0..<n]), PeerAddress(sockaddr: sa))
    }
}

/// Disambiguates libc functions from same-named Swift methods.
enum Glue {
    #if canImport(Darwin)
    static let connect = Darwin.connect
    static let send = Darwin.send
    static let recv = Darwin.recv
    static let close = Darwin.close
    static let shutdown = Darwin.shutdown
    static let bind = Darwin.bind
    static let accept = Darwin.accept
    static let sendto = Darwin.sendto
    static let recvfrom = Darwin.recvfrom
    #else
    static let connect = Glibc.connect
    static let send = Glibc.send
    static let recv = Glibc.recv
    static let close = Glibc.close
    static let shutdown = Glibc.shutdown
    static let bind = Glibc.bind
    static let accept = Glibc.accept
    static let sendto = Glibc.sendto
    static let recvfrom = Glibc.recvfrom
    #endif
}
