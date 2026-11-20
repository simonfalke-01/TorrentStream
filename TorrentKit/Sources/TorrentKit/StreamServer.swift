import Foundation

/// Loopback HTTP/1.1 server that exposes torrent files to media players with full Range (seek) support.
/// URL layout: http://127.0.0.1:<port>/stream/<infohash>/<fileIndex>/<fileName>
final class StreamServer {
    private weak var client: TorrentClient?
    private var listener: TCPListener?
    private let lock = NSLock()
    private var preferredPort: UInt16
    private(set) var port: UInt16 = 0
    private var generation = 0

    init(client: TorrentClient, preferredPort: UInt16) {
        self.client = client
        self.preferredPort = preferredPort
    }

    /// Starts (or restarts after iOS reclaimed the socket) the listener.
    func ensureRunning() throws {
        lock.lock(); defer { lock.unlock() }
        if listener != nil { return }
        let l: TCPListener
        do { l = try TCPListener(port: preferredPort) } catch { l = try TCPListener(port: 0) }
        listener = l
        port = l.port
        preferredPort = l.port
        generation += 1
        let gen = generation
        let t = Thread { [weak self] in self?.acceptLoop(l, generation: gen) }
        t.name = "stream-server"
        t.start()
        log("stream server listening on 127.0.0.1:\(port)")
    }

    func stop() {
        lock.lock(); listener?.close(); listener = nil; lock.unlock()
    }

    private func acceptLoop(_ l: TCPListener, generation gen: Int) {
        while true {
            do {
                guard let sock = try l.accept() else { continue }
                let t = Thread { [weak self] in self?.serve(sock) }
                t.name = "stream-conn"
                t.start()
            } catch {
                log("stream server accept failed: \(error)")
                lock.lock()
                if generation == gen { listener?.close(); listener = nil }
                lock.unlock()
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
            guard let d = try sock.receive(max: 8192) else { continue }
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
        sock.setSendTimeout(30)
        var buffer = Data()
        defer { sock.close() }
        do {
            while let req = try readRequest(sock, buffer: &buffer) {
                let keepAlive = try handle(req, sock: sock)
                if !keepAlive { return }
            }
        } catch {
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
        defer { torrent.removeReader(readerID) }
        var pos = start
        let chunk: Int64 = 256 * 1024
        let pieceLength = Int64(info.pieceLength)
        while pos <= end {
            // Send each piece as soon as it is verified rather than waiting for a whole chunk.
            let pieceEnd = ((file.offset + pos) / pieceLength + 1) * pieceLength - file.offset
            let n = Int(min(chunk, end - pos + 1, pieceEnd - pos))
            // Wait for the bytes, checking often whether the player gave up on this request (it does on every
            // seek), so a stale reader doesn't keep its priority.
            while try !torrent.waitForData(fileIndex: fileIndex, offset: pos, length: n, readerID: readerID, timeout: 0.25) {
                if sock.isPeerClosed() { return false }
            }
            let data = try torrent.readData(fileIndex: fileIndex, offset: pos, length: n)
            try sock.send(data)
            pos += Int64(n)
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
