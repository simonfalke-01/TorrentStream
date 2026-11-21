import Foundation

/// Loopback HTTP/1.1 server that exposes torrent files to media players with full Range (seek) support.
/// URL layout: http://127.0.0.1:<port>/stream/<infohash>/<fileIndex>/<fileName>
final class StreamServer {
    private weak var client: TorrentClient?
    private var listener: TCPListener?
    private let lock = NSLock()
    private var preferredPort: UInt16
    private var boundPort: UInt16 = 0
    private var generation = 0
    /// Last time the listener was seen working (a connection accepted, or a probe answered).
    private var healthyAt = Date.distantPast

    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return boundPort }
    /// Incremented every time a listener is bound (the first one is 1).
    var listenerGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }

    init(client: TorrentClient, preferredPort: UInt16) {
        self.client = client
        self.preferredPort = preferredPort
    }

    /// Starts the listener if it isn't running (or was found dead), on the port used before whenever possible: the
    /// player holds URLs with it.
    func ensureRunning() throws {
        lock.lock(); defer { lock.unlock() }
        if listener != nil { return }
        var l: TCPListener?
        if preferredPort != 0 {
            // A reclaimed socket may hold the port for a moment.
            for attempt in 0..<20 {
                if let ok = try? TCPListener(port: preferredPort) { l = ok; break }
                if attempt < 19 { Thread.sleep(forTimeInterval: 0.05) }
            }
            if l == nil { log("stream server: port \(preferredPort) unavailable, moving") }
        }
        let bound = try l ?? TCPListener(port: 0)
        listener = bound
        boundPort = bound.port
        preferredPort = bound.port
        generation += 1
        healthyAt = Date()
        let gen = generation
        let t = Thread { [weak self] in self?.acceptLoop(bound, generation: gen) }
        t.name = "stream-server"
        t.start()
        log("stream server listening on 127.0.0.1:\(boundPort)")
    }

    /// Checks the listener end to end (connect, request, answer) unless it worked moments ago, and restarts it on
    /// the same port when it doesn't answer. iOS reclaims listening sockets of suspended apps: they then refuse
    /// connections, or accept fails forever.
    func validate(maxAge: TimeInterval = 2) {
        lock.lock()
        let running = listener != nil, p = boundPort, fresh = Date().timeIntervalSince(healthyAt) < maxAge
        lock.unlock()
        if running && fresh { return }
        if running && !probe(port: p) {
            log("stream server on port \(p) not answering; restarting it")
            restart(listenerGeneration: nil)
        }
        try? ensureRunning()
    }

    private func probe(port: UInt16) -> Bool {
        guard let s = try? TCPSocket.connect(to: PeerAddress(ip: 0x7f00_0001, port: port), timeout: 0.3) else { return false }
        defer { s.close() }
        // Loopback: a live server answers within milliseconds. Keep it short, this may run on the main thread.
        s.setReceiveTimeout(0.25)
        s.setSendTimeout(0.25)
        guard (try? s.send(Data("GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8))) != nil,
              let reply = try? s.receiveExactly(12, deadline: Date().addingTimeInterval(0.5)) else { return false }
        let ok = String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 204")
        if ok { lock.lock(); healthyAt = Date(); lock.unlock() }
        return ok
    }

    /// Closes the listener (if it is still the given generation) so `ensureRunning` binds a new one.
    private func restart(listenerGeneration gen: Int?) {
        lock.lock()
        if gen == nil || generation == gen { listener?.close(); listener = nil }
        lock.unlock()
    }

    func stop() {
        lock.lock(); listener?.close(); listener = nil; preferredPort = 0; lock.unlock()
    }

    /// Tests: the listening descriptor.
    var listenerFD: Int32 { lock.lock(); defer { lock.unlock() }; return listener?.fd ?? -1 }

    private func acceptLoop(_ l: TCPListener, generation gen: Int) {
        var aborted = 0
        while true {
            do {
                switch try l.accept() {
                case let .socket(sock):
                    aborted = 0
                    lock.lock(); healthyAt = Date(); lock.unlock()
                    let t = Thread { [weak self] in self?.serve(sock) }
                    t.name = "stream-conn"
                    t.start()
                case .transient:
                    continue
                case .aborted:
                    // Now and then a client gives up before being accepted; over and over, the socket is dead.
                    aborted += 1
                    if aborted >= 3 { throw SocketError.failed("accept: connection aborted \(aborted) times") }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            } catch {
                lock.lock()
                let current = generation == gen
                lock.unlock()
                // Closed by `stop` or replaced: nothing to do.
                guard current, l.fd >= 0 else { return }
                log("stream server accept failed: \(error); listening again")
                restart(listenerGeneration: gen)
                try? ensureRunning()
                return
            }
        }
    }

    // MARK: HTTP

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private func readRequest(_ sock: TCPSocket, buffer: inout Data) throws -> Request? {
        let deadline = Date().addingTimeInterval(60)
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            if Date() > deadline { return nil }
            let got: Data?
            do { got = try sock.receive(max: 8192) } catch {
                // The player closed an idle keep-alive connection: the normal end.
                if buffer.isEmpty { return nil }
                throw error
            }
            guard let d = got else { continue }
            buffer.append(d)
            if buffer.count > 64 * 1024 { throw TorrentError.io("request too large") }
        }
        let end = buffer.range(of: terminator)!
        let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw TorrentError.io("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }

    private func serve(_ sock: TCPSocket) {
        sock.setReceiveTimeout(1)
        // Short, so a body send blocked on a player that stopped reading re-checks whether to go on (see `handle`).
        sock.setSendTimeout(1)
        var buffer = Data()
        var clean = true
        defer { if clean { sock.close() } else { sock.abort() } }
        do {
            while let req = try readRequest(sock, buffer: &buffer) {
                let keepAlive = try handle(req, sock: sock)
                if !keepAlive { return }
            }
        } catch {
            // Possibly in the middle of a body: reset, so the player sees an error and reconnects at its offset
            // instead of taking a short body for the end of the file.
            clean = false
            log("stream connection ended: \(error)")
        }
    }

    private func sendHead(_ sock: TCPSocket, status: String, headers: [(String, String)]) throws {
        var s = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        try sock.send(Data(s.utf8))
    }

    private func sendError(_ sock: TCPSocket, _ status: String) throws {
        let body = Data(status.utf8)
        try sendHead(sock, status: status, headers: [("Content-Length", "\(body.count)"), ("Content-Type", "text/plain"), ("Connection", "close")])
        try sock.send(body)
    }

    /// Returns whether the connection may be reused.
    private func handle(_ req: Request, sock: TCPSocket) throws -> Bool {
        guard req.method == "GET" || req.method == "HEAD" else { try sendError(sock, "405 Method Not Allowed"); return false }
        if req.path == "/ping" {
            try sendHead(sock, status: "204 No Content", headers: [("Connection", "close")])
            return false
        }
        let parts = req.path.split(separator: "?")[0].split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "stream", let fileIndex = Int(parts[2]),
              let torrent = client?.torrent(infoHashHex: parts[1].lowercased()) else {
            try sendError(sock, "404 Not Found"); return false
        }
        // Wait for metadata (magnet links) for a little while.
        guard let info = torrent.waitForInfo(timeout: 60), fileIndex >= 0, fileIndex < info.files.count else {
            try sendError(sock, "404 Not Found"); return false
        }
        let file = info.files[fileIndex]
        let total = file.length

        var start: Int64 = 0
        var end: Int64 = total - 1
        var partial = false
        if let range = req.headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",")[0]
            let se = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if se.count == 2 {
                if se[0].isEmpty, let suffix = Int64(se[1]) {
                    start = max(0, total - suffix)
                } else if let s = Int64(se[0]) {
                    start = s
                    if let e = Int64(se[1]) { end = min(e, total - 1) }
                }
                partial = true
            }
        }
        if total == 0 || start >= total || start > end {
            try sendHead(sock, status: "416 Range Not Satisfiable",
                         headers: [("Content-Range", "bytes */\(total)"), ("Content-Length", "0")])
            return true
        }
        let length = end - start + 1
        var headers: [(String, String)] = [
            ("Content-Type", StreamServer.mimeType(for: file.fileExtension)),
            ("Accept-Ranges", "bytes"),
            ("Content-Length", "\(length)"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
        ]
        if partial { headers.append(("Content-Range", "bytes \(start)-\(end)/\(total)")) }
        try sendHead(sock, status: partial ? "206 Partial Content" : "200 OK", headers: headers)
        if req.method == "HEAD" { return true }

        let readerID = UUID()
        log("http request \(start)-\(end) of file \(fileIndex)")
        var firstByteLogged = false
        defer { torrent.removeReader(readerID) }
        let began = Date()
        var pos = start
        defer { log("http \(start)-\(end) sent \(pos - start) in " + String(format: "%.2fs", Date().timeIntervalSince(began))) }
        while pos <= end {
            // Send whatever has arrived as soon as it lands, block by block (pieces needn't be complete or verified):
            // with 16 MB pieces, waiting for whole pieces costs seconds after every seek. Wake often to notice the
            // player giving up on this request (it does on every seek), so a stale reader doesn't keep its priority.
            var n: Int64 = 0
            var waits = 0
            while true {
                n = try torrent.waitForAvailable(fileIndex: fileIndex, offset: pos, maxLength: min(end - pos + 1, 1 << 20),
                                                 readerID: readerID, timeout: 0.25)
                if n > 0 { break }
                if sock.isPeerClosed() { return false }
                waits += 1
                if waits % 4 == 0 && TorrentLog.enabled { log("http stalled \(waits / 4)s at \(pos): " + torrent.blockDebugDescription(fileIndex: fileIndex, offset: pos)) }
            }
            let data = try torrent.readData(fileIndex: fileIndex, offset: pos, length: Int(n))
            // A player that stopped reading (paused, app suspended) gets the rest when it reads again: the response
            // is never cut short while the torrent is there.
            try sock.send(data, keepWaiting: { !torrent.isStopped })
            if !firstByteLogged { firstByteLogged = true; log("http first byte \(pos) after " + String(format: "%.2fs", Date().timeIntervalSince(began))) }
            pos += n
        }
        return true
    }

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "mpg", "mpeg": return "video/mpeg"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        case "srt": return "application/x-subrip"
        case "vtt": return "text/vtt"
        case "ass", "ssa": return "text/x-ssa"
        default: return "application/octet-stream"
        }
    }
}
