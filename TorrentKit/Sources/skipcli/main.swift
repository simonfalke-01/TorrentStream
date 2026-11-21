import Foundation
import SkipKit
import CatalogKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Development harness for SkipKit on real episodes.
//
//   skipcli print <audio.f32le> <sampleRate> <channels> <out.json>   fingerprint raw interleaved float PCM
//   skipcli match <a.json> <b.json>                                  audio the two episodes share
//   skipcli detect <target.json> <ref.json>...                       intro and credits of the target

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func clock(_ t: Double) -> String {
    let tenths = Int((t * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

struct StoredPrint: Codable {
    var duration: Double
    var print: AudioPrint
}

final class LockedHandle: @unchecked Sendable {
    let handle: FileHandle
    let lock = NSLock()
    init(_ handle: FileHandle) { self.handle = handle }
}

func fileReader(_ handle: FileHandle) -> ByteReader {
    let h = LockedHandle(handle)
    return { offset, length in
        h.lock.withLock {
            h.handle.seek(toFileOffset: UInt64(offset))
            let data = h.handle.readData(ofLength: length)
            return data.count == length ? data : nil
        }
    }
}

func loadPrint(_ path: String) -> StoredPrint {
    guard let data = FileManager.default.contents(atPath: path),
          let p = try? JSONDecoder().decode(StoredPrint.self, from: data) else { fail("can't read \(path)") }
    return p
}

guard args.count >= 2 else { fail("usage: skipcli print|match|detect|aniskip|packets|listen ...") }
switch args[1] {
case "print":
    guard args.count == 6, let rate = Double(args[3]), let channels = Int(args[4]) else { fail("usage: skipcli print <audio.f32le> <rate> <channels> <out.json>") }
    guard let raw = FileManager.default.contents(atPath: args[2]) else { fail("can't read \(args[2])") }
    var samples = [Float](repeating: 0, count: raw.count / 4)
    _ = samples.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
    let t0 = Date()
    var print = AudioPrint()
    // Feed it the way the decoder does: a minute at a time, each run overlapping the last by a second.
    let mono = Fingerprinter.mono(samples, channels: channels)
    let chunk = Int(rate * 60), overlap = Int(rate)
    var start = 0
    while start < mono.count {
        let end = min(mono.count, start + chunk + overlap)
        Fingerprinter.add(Array(mono[start..<end]), sampleRate: rate, startTime: Double(start) / rate, to: &print)
        start += chunk
    }
    let duration = Double(mono.count) / rate
    let out = try JSONEncoder().encode(StoredPrint(duration: duration, print: print))
    try out.write(to: URL(fileURLWithPath: args[5]))
    Swift.print(String(format: "%@: %.1fs of audio, %d frames in %.2fs", args[2], duration, print.frameCount, Date().timeIntervalSince(t0)))
case "match":
    guard args.count == 4 else { fail("usage: skipcli match <a.json> <b.json>") }
    let a = loadPrint(args[2]), b = loadPrint(args[3])
    let t0 = Date()
    let found = PrintMatcher.shared(a.print, b.print, minLength: 10)
    Swift.print(String(format: "matched in %.2fs", Date().timeIntervalSince(t0)))
    for s in found {
        Swift.print("  \(clock(s.start))-\(clock(s.end)) (\(String(format: "%.1f", s.length))s) ~ \(clock(s.otherStart))  sim \(String(format: "%.1f", s.similarity))")
    }
case "detect":
    guard args.count >= 4 else { fail("usage: skipcli detect <a.json> <b.json>...") }
    let paths = Array(args[2...])
    let episodes = paths.map { path -> EpisodeAudio in
        let p = loadPrint(path)
        return EpisodeAudio(id: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, duration: p.duration, print: p.print)
    }
    let t0 = Date()
    let result = SkipDetector.analyze(episodes)
    Swift.print(String(format: "analyzed in %.2fs", Date().timeIntervalSince(t0)))
    func show(_ v: SkipVerdict) -> String {
        switch v {
        case .unknown: return "unknown        "
        case .absent: return "absent         "
        case .found(let s): return "\(clock(s.start))-\(clock(s.end))"
        }
    }
    for e in episodes {
        let r = result[e.id]!
        Swift.print("\(e.id)  dur \(clock(e.duration))  OP \(show(r.intro))  ED \(show(r.credits))")
    }
case "aniskip":
    // What the player showed before content detection: AniSkip plus inferred neighbours.
    guard args.count == 5, let mal = Int(args[2]), let episode = Int(args[3]), let duration = Double(args[4]) else {
        fail("usage: skipcli aniskip <malID> <episode> <duration>")
    }
    let segments = try await ShowCatalog().skipSegments(malID: mal, episode: episode, duration: duration)
    for s in segments {
        Swift.print("\(s.kind.rawValue) \(String(format: "%.1f %.1f", s.start, s.end))\(s.isInferred ? " inferred" : "")")
    }
case "packets":
    // Audio packets as the demuxer sees them: count, first times and sizes, to compare with ffprobe -show_packets.
    guard args.count == 3, let handle = FileHandle(forReadingAtPath: args[2]) else { fail("usage: skipcli packets <file.mkv>") }
    let size = Int64(handle.seekToEndOfFile())
    let read = fileReader(handle)
    guard let layout = await MatroskaAudio.layout(read: read, fileSize: size) else { fail("no audio track") }
    Swift.print("\(layout.audio.codecID) \(layout.audio.sampleRate) Hz \(layout.audio.channels) ch, private \(layout.audio.codecPrivate.count) bytes, duration \(layout.duration), \(layout.cues.count) cues")
    var offset: Int64? = layout.cues.first?.offset
    var count = 0, bytes = 0, clusters = 0
    var first: [AudioPacket] = []
    var last: AudioPacket?
    while let o = offset, let cluster = await MatroskaAudio.cluster(at: o, layout: layout, read: read, fileSize: size) {
        clusters += 1
        count += cluster.packets.count
        bytes += cluster.packets.reduce(0) { $0 + $1.data.count }
        if first.count < 5 { first += cluster.packets.prefix(5 - first.count) }
        last = cluster.packets.last ?? last
        offset = cluster.end
    }
    Swift.print("\(clusters) clusters, \(count) packets, \(bytes) bytes")
    for p in first { Swift.print(String(format: "  %.3f %d", p.time, p.data.count)) }
    if let last { Swift.print(String(format: "  last %.3f %d", last.time, last.data.count)) }
case "listen":
    // Fingerprint an MKV with PCM audio the way the app does, reading it as if it were downloading.
    guard args.count == 4, let handle = FileHandle(forReadingAtPath: args[2]) else { fail("usage: skipcli listen <file.mkv> <out.json>") }
    let size = Int64(handle.seekToEndOfFile())
    let listener = EpisodeListener(id: "x", fileSize: size, read: fileReader(handle), decoder: PCMDecoder.factory)
    let t0 = Date()
    await listener.update()
    guard let audio = await listener.audio() else { fail("unsupported: \(await listener.state)") }
    let out = try JSONEncoder().encode(StoredPrint(duration: audio.duration, print: audio.print))
    try out.write(to: URL(fileURLWithPath: args[3]))
    Swift.print(String(format: "%.1fs decoded of %.1fs in %.2fs", audio.print.decodedSeconds, audio.duration, Date().timeIntervalSince(t0)))
default:
    fail("unknown command \(args[1])")
}
