import Foundation
import SubtitleKit
import TorrentKit

/// A second subtitle track drawn by the app above the video, for reading two languages at once or keeping
/// signs alongside dialogue. Sources are the release's text subtitle tracks (read straight from the downloaded
/// parts of an MKV) and subtitle files shipped with it.
@MainActor
final class SecondarySubtitles: ObservableObject {
    struct Option: Identifiable, Hashable {
        enum Source: Hashable {
            case embedded(Int)
            case file(URL, SubtitleFormat)
        }
        let id: String
        let title: String
        let source: Source
    }

    @Published private(set) var options: [Option] = []
    @Published private(set) var selected: String?
    @Published private(set) var text: String?
    @Published private(set) var delay: Double = 0

    private var reader: MatroskaSubtitleReader?
    private var cues: [SubtitleCue] = []
    private var window: ClosedRange<Double>?
    private var lastFetch = Date.distantPast
    private var fetchTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?

    func prepare(_ request: PlaybackRequest) {
        var files: [Option] = []
        for (i, s) in request.subtitles.prefix(12).enumerated() {
            let ext = (s.name as NSString).pathExtension
            guard let format = SubtitleFormat(fileExtension: ext) else { continue }
            let name = ((s.name as NSString).lastPathComponent as NSString).deletingPathExtension
            files.append(Option(id: "file.\(i)", title: name, source: .file(s.url, format)))
        }
        options = files

        guard request.file.fileExtension == "mkv" else { return }
        let torrent = request.torrent
        let index = request.file.index
        let r = MatroskaSubtitleReader(fileLength: request.file.length, decompress: { Self.inflate($0) }) { offset, length in
            torrent.availableData(fileIndex: index, offset: offset, length: length)
        }
        reader = r
        setupTask = Task { [weak self] in
            // The track list sits at the start of the file, which arrives first; wait for it briefly.
            for _ in 0..<20 {
                if Task.isCancelled { return }
                if let tracks = try? await r.tracks() {
                    let embedded = tracks.enumerated().map { i, t in
                        Option(id: "track.\(t.number)",
                               title: SubtitleLabels.label(language: t.language, name: t.name, fallbackIndex: i + 1),
                               source: .embedded(t.number))
                    }
                    self?.options = embedded + files
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func select(_ id: String?) {
        selected = id
        cues = []
        window = nil
        text = nil
        lastFetch = .distantPast
        fetchTask?.cancel()
        fetchTask = nil
        guard let option = options.first(where: { $0.id == id }) else { return }
        if case .file(let url, let format) = option.source {
            fetchTask = Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                let parsed = SubtitleParser.parse(data, format: format)
                guard !Task.isCancelled else { return }
                self?.cues = parsed
                self?.window = -Double.infinity...Double.infinity
            }
        }
    }

    func setDelay(_ seconds: Double) { delay = seconds }

    /// Shows the cues at `time` and keeps the next half minute loaded.
    func update(time: Double) {
        guard let id = selected, let option = options.first(where: { $0.id == id }) else {
            if text != nil { text = nil }
            return
        }
        let t = time - delay
        if case .embedded(let track) = option.source, let reader {
            let stale = Date().timeIntervalSince(lastFetch) > 2
            let outside = window.map { !$0.contains(t) || t + 10 > $0.upperBound } ?? true
            if (stale || outside) && fetchTask == nil {
                lastFetch = Date()
                let from = max(0, t - 5), to = t + 30
                fetchTask = Task { [weak self] in
                    let found = (try? await reader.cues(track: track, from: from, to: to)) ?? []
                    guard let self, !Task.isCancelled else { return }
                    if self.selected == id {
                        self.cues = found
                        self.window = from...to
                    }
                    self.fetchTask = nil
                }
            }
        }
        let now = cues.filter { $0.start <= t && t < $0.end }.map(\.text)
        let joined = now.isEmpty ? nil : now.joined(separator: "\n")
        if joined != text { text = joined }
    }

    func shutdown() {
        setupTask?.cancel()
        fetchTask?.cancel()
    }

    /// zlib (RFC 1950) to raw deflate for Foundation: drop the 2-byte header and the 4-byte checksum.
    nonisolated static func inflate(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let body = data.subdata(in: data.startIndex + 2 ..< data.endIndex - 4)
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

/// The subtitle line already on screen where playback lands. libVLC reads a Matroska file's subtitles from the
/// keyframe it seeks to (demux/mkv SegmentSeeker::get_seekpoints takes subtitle seekpoints at or after the video
/// keyframe), so a line that began before that keyframe never shows and the screen stays empty until the next
/// one. The app draws that line itself, from the same track, until it ends.
@MainActor
final class CarriedSubtitle: ObservableObject {
    /// What to draw: the text, and for an ASS track the style libVLC draws it in, so the line looks the same.
    struct Line: Equatable {
        let text: String
        let style: ASSStyle?
        /// The script's coordinate space (PlayResX, PlayResY), which the style's sizes are in.
        let playRes: CGSize
    }

    @Published private(set) var line: Line?

    private static let tag = "player.subtitle.carry"
    private var reader: MatroskaSubtitleReader?
    private var torrent: Torrent?
    private var fileIndex = 0
    private var cues: [SubtitleCue] = []
    private var header: ASSHeader?
    private var headers: [Int: ASSHeader] = [:]
    private var task: Task<Void, Never>?
    private var time: Double = 0
    private var landedAt: Double?

    func prepare(_ request: PlaybackRequest) {
        guard reader == nil, request.file.fileExtension == "mkv" else { return }
        let torrent = request.torrent
        let index = request.file.index
        self.torrent = torrent
        fileIndex = index
        let reader = MatroskaSubtitleReader(fileLength: request.file.length, decompress: { SecondarySubtitles.inflate($0) }) { offset, length in
            torrent.availableData(fileIndex: index, offset: offset, length: length)
        }
        self.reader = reader
        // The fonts the styles name come with the file, near its start; libVLC reads them from the same place.
        Task.detached(priority: .utility) {
            for _ in 0..<30 {
                if Task.isCancelled { return }
                do {
                    SubtitleFonts.add(try await reader.fonts().map(\.data))
                    return
                } catch MatroskaError.dataUnavailable {
                    try? await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    /// The Matroska track number of a libVLC subtitle track: libVLC names a file's own tracks "spu/<TrackNumber>"
    /// (es_out.c EsOutCreateStrId with the demuxer's i_id); added files and closed captions are named otherwise.
    static func trackNumber(_ id: String) -> Int? {
        let parts = id.split(separator: "/")
        guard parts.count == 2, parts[0] == "spu" else { return nil }
        return Int(parts[1])
    }

    /// Playback landed at `time`, read from `keyframe` on, with `track` showing (nil: none of the file's own).
    /// - Parameters:
    ///   - delay: the subtitle delay, in seconds.
    ///   - bytes: where the lines before the keyframe are, fetched soon so they can be read.
    func landed(at time: Double, keyframe: Double, track: Int?, delay: Double, bytes: Range<Int64>?) {
        task?.cancel()
        task = nil
        cues = []
        if line != nil { line = nil }
        torrent?.clearWants(tag: Self.tag)
        landedAt = time
        guard let track, let reader, keyframe <= time + 0.05 else { return }
        if let bytes, let torrent { torrent.want(fileIndex: fileIndex, ranges: [bytes], urgency: .soon, tag: Self.tag) }
        header = headers[track]
        task = Task { [weak self] in
            if self?.header == nil, let h = try? await reader.assHeader(track: track) {
                guard !Task.isCancelled, let self else { return }
                self.headers[track] = h
                self.header = h
            }
            // Lines last a few seconds; past that there's nothing left to carry.
            for _ in 0..<10 {
                let found = (try? await reader.cues(track: track, from: time - delay, to: time - delay)) ?? []
                guard !Task.isCancelled, let self else { return }
                let carried = found
                    .filter { $0.start + delay < keyframe - 0.05 && $0.end + delay > time }
                    .map { SubtitleCue(start: $0.start + delay, end: $0.end + delay, text: $0.text, style: $0.style) }
                if !carried.isEmpty || found.contains(where: { $0.start + delay >= keyframe - 0.05 }) {
                    self.torrent?.clearWants(tag: Self.tag)
                    self.cues = carried
                    self.update(time: self.time)
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled || self.time > time + 4 { return }
            }
            self?.torrent?.clearWants(tag: Self.tag)
        }
    }

    func update(time: Double) {
        self.time = time
        guard !cues.isEmpty else { return }
        // Moved back before the spot without a landing (a reopen still on its way): the line no longer belongs.
        if let at = landedAt, time < at - 1 { cues = [] }
        let now = cues.filter { $0.start <= time && time < $0.end }
        var next: Line?
        if let first = now.first {
            let style = header?.style(named: first.style)
            let res = header.map { CGSize(width: $0.playResX, height: $0.playResY) } ?? .zero
            next = Line(text: now.map(\.text).joined(separator: "\n"), style: style, playRes: res)
        }
        if next != line { line = next }
        if next == nil, cues.allSatisfy({ $0.end <= time }) { cues = [] }
    }

    func clear() {
        task?.cancel()
        task = nil
        cues = []
        if line != nil { line = nil }
        torrent?.clearWants(tag: Self.tag)
    }
}
