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
