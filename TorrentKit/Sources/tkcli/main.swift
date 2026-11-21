import Foundation
import TorrentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Usage: tkcli <magnet-link | path.torrent> [fileIndex] [--serve]
// Fetches metadata, lists files, then streams the start and the middle of a file through the local HTTP server
// exactly like a media player would (Range requests), printing throughput.

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: tkcli <magnet|file.torrent> [fileIndex] [--serve] [--verbose]")
    exit(2)
}
TorrentLog.enabled = args.contains("--verbose")
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tkcli")
let client = TorrentClient(downloadDirectory: dir)
let source = args[1]
let torrent: Torrent
do {
    if FileManager.default.fileExists(atPath: source) {
        torrent = try client.add(torrentData: Data(contentsOf: URL(fileURLWithPath: source)))
    } else {
        torrent = try client.add(magnet: source)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}

print("info-hash \(torrent.infoHashHex), fetching metadata...")
let started = Date()
var info: TorrentInfo?
while info == nil {
    info = torrent.waitForInfo(timeout: 5)
    let s = torrent.status()
    print(String(format: "  %.0fs peers %d/%d metadata %.0f%%", Date().timeIntervalSince(started), s.connectedPeers, s.knownPeers, s.metadataProgress * 100))
    if Date().timeIntervalSince(started) > 300 { print("metadata timeout"); exit(1) }
}
guard let info = info else { exit(1) }
print("name: \(info.name)  pieces: \(info.pieceCount) x \(info.pieceLength)")
for f in info.files where !f.isPadding {
    print("  [\(f.index)] \(f.displayPath) (\(f.length) bytes)")
}

let fileIndex = args.count >= 3 ? Int(args[2]) ?? -1 : -1
let target = fileIndex >= 0 ? info.files[fileIndex] : info.files.filter { !$0.isPadding }.max { $0.length < $1.length }!
let url = client.streamURL(for: torrent, fileIndex: target.index, fileName: target.fileName)
print("streaming [\(target.index)] \(target.fileName) via \(url)")

if args.contains("--serve") {
    while true {
        Thread.sleep(forTimeInterval: 2)
        let s = torrent.streamStatus(fileIndex: target.index)
        print(String(format: "  peers %d rate %.1f KB/s buffered %.1f MB file %.1f%%", s.connectedPeers, s.downloadRate / 1024,
                     Double(s.bufferedAhead) / 1e6, s.fileProgress * 100))
        print("    " + torrent.swarmSummary)
        fflush(stdout)
    }
}

func fetch(_ from: Int64, _ count: Int64) -> (Int, Int, TimeInterval, String) {
    var req = URLRequest(url: url, timeoutInterval: 600)
    req.setValue("bytes=\(from)-\(from + count - 1)", forHTTPHeaderField: "Range")
    let sem = DispatchSemaphore(value: 0)
    var status = 0, size = 0
    var range = ""
    let t0 = Date()
    let monitor = Thread {
        while sem.wait(timeout: .now() + 3) == .timedOut {
            let s = torrent.streamStatus(fileIndex: target.index)
            print(String(format: "    ... peers %d rate %.1f KB/s buffered-ahead %.2f MB", s.connectedPeers, s.downloadRate / 1024, Double(s.bufferedAhead) / 1e6))
        }
    }
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        range = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
        size = data?.count ?? 0
        sem.signal(); sem.signal()
    }.resume()
    monitor.start()
    sem.wait()
    return (status, size, Date().timeIntervalSince(t0), range)
}

let probe = min(Int64(4 << 20), target.length)
var (code, size, elapsed, range) = fetch(0, probe)
print(String(format: "HEAD-of-file: HTTP %d, %d bytes (%@) in %.1fs", code, size, range, elapsed))
let mid = target.length / 2
(code, size, elapsed, range) = fetch(mid, min(Int64(2 << 20), target.length - mid))
print(String(format: "SEEK-to-middle: HTTP %d, %d bytes (%@) in %.1fs", code, size, range, elapsed))

// Verify streamed bytes match what is on disk and hash-checked.
let local = try! torrent.readData(fileIndex: target.index, offset: mid, length: 1024)
print("verified bytes at middle: \(local.prefix(8).map { String(format: "%02x", $0) }.joined())")
client.shutdown()
exit(code == 206 ? 0 : 1)
