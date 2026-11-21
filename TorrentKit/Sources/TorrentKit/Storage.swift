import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Maps the torrent's linear byte space onto files on disk. Files are created sparse on first write,
/// so only the parts that were actually downloaded consume space.
final class Storage {
    let root: URL
    let info: TorrentInfo
    private var fds: [Int: Int32] = [:]
    private let lock = NSLock()

    init(root: URL, info: TorrentInfo) {
        self.root = root
        self.info = info
    }

    deinit { closeAll() }

    func url(for file: TorrentFile) -> URL {
        var u = root
        if !info.isSingleFile { u.appendPathComponent(info.name, isDirectory: true) }
        for c in file.path { u.appendPathComponent(c) }
        return u
    }

    private func fd(for file: TorrentFile, create: Bool) throws -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if let fd = fds[file.index] { return fd }
        let u = url(for: file)
        if !create && !FileManager.default.fileExists(atPath: u.path) { return nil }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(u.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw TorrentError.io("open \(u.lastPathComponent): \(Net.lastError)") }
        fds[file.index] = fd
        return fd
    }

    /// Calls `body` for each file segment overlapping the absolute range.
    private func segments(offset: Int64, length: Int, _ body: (TorrentFile, Int64, Int, Int) throws -> Void) rethrows {
        var remaining = length
        var pos = offset
        var bufOffset = 0
        // Binary search the first file containing `offset`.
        var lo = 0, hi = info.files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if info.files[mid].offset <= pos { lo = mid } else { hi = mid - 1 }
        }
        var i = lo
        while remaining > 0 && i < info.files.count {
            let f = info.files[i]
            let fileEnd = f.offset + f.length
            if pos < fileEnd && f.length > 0 {
                let inFile = pos - f.offset
                let n = Int(min(Int64(remaining), fileEnd - pos))
                try body(f, inFile, n, bufOffset)
                remaining -= n; pos += Int64(n); bufOffset += n
            }
            i += 1
        }
    }

    func write(offset: Int64, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            try segments(offset: offset, length: data.count) { file, fileOffset, n, bufOffset in
                guard !file.isPadding, let fd = try fd(for: file, create: true) else { return }
                var written = 0
                while written < n {
                    let r = pwrite(fd, raw.baseAddress! + bufOffset + written, n - written, off_t(fileOffset) + off_t(written))
                    if r < 0 { if errno == EINTR { continue }; throw TorrentError.io("write: \(Net.lastError)") }
                    written += r
                }
            }
        }
    }

    /// Writes raw bytes (a block straight out of the peer's receive buffer) at an absolute torrent offset.
    func write(offset: Int64, bytes raw: UnsafeRawBufferPointer) throws {
        guard let base = raw.baseAddress else { return }
        try segments(offset: offset, length: raw.count) { file, fileOffset, n, bufOffset in
            guard !file.isPadding, let fd = try fd(for: file, create: true) else { return }
            var written = 0
            while written < n {
                let r = pwrite(fd, base + bufOffset + written, n - written, off_t(fileOffset) + off_t(written))
                if r < 0 { if errno == EINTR { continue }; throw TorrentError.io("write: \(Net.lastError)") }
                written += r
            }
        }
    }

    func read(offset: Int64, length: Int) throws -> Data {
        var out = Data(count: length)
        try out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            try segments(offset: offset, length: length) { file, fileOffset, n, bufOffset in
                guard !file.isPadding, let fd = try fd(for: file, create: false) else { return } // zeros
                var done = 0
                while done < n {
                    let r = pread(fd, raw.baseAddress! + bufOffset + done, n - done, off_t(fileOffset) + off_t(done))
                    if r < 0 { if errno == EINTR { continue }; throw TorrentError.io("read: \(Net.lastError)") }
                    if r == 0 { break }
                    done += r
                }
            }
        }
        return out
    }

    func writePiece(_ index: Int, data: Data) throws {
        try write(offset: Int64(index) * Int64(info.pieceLength), data: data)
    }

    func readPiece(_ index: Int) throws -> Data {
        try read(offset: Int64(index) * Int64(info.pieceLength), length: info.pieceSize(index))
    }

    func closeAll() {
        lock.lock()
        for (_, fd) in fds { close(fd) }
        fds.removeAll()
        lock.unlock()
    }
}
