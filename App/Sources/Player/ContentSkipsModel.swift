import Foundation
import Network
import TorrentKit
import CatalogKit
import SkipKit

/// Another episode's file, compared with the one playing to find the songs they share.
struct SkipReference {
    let torrent: Torrent
    let file: TorrentFile
    /// Its number when it's in the same season as the one playing, so it's remembered with that season.
    let episode: Int?
}

/// Finds the playing episode's opening and ending in its audio as it downloads, by comparing it with other episodes
/// of the season: ones heard before (kept on disk) and the next one while it prefetches. The result goes to
/// `SkipResolver` with the chapters and the catalog's times.
@MainActor
final class ContentSkipsModel: ObservableObject {
    /// What the audio has shown so far. Nil when the file can't be analysed (not Matroska, or a codec the system
    /// can't decode); then the catalog's times are used as they are.
    @Published private(set) var content: ContentSkips? = ContentSkips()

    static let library = SkipLibrary(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SkipPrints", isDirectory: true))

    private static let interval: UInt64 = 15_000_000_000
    private static let wantTag = "skips"
    /// The part of the next episode's end fetched when no episode of the season has been heard before.
    private static let tailSeconds = 480.0

    private var session: SkipSession?
    private var series: String?
    private var loop: Task<Void, Never>?
    private var nextProvider: (@MainActor () -> SkipReference?)?
    private var next: (ref: SkipReference, listener: EpisodeListener)?
    private var tailWanted = false

    /// Starts listening to an episode of a series. `next` is asked for the next episode's file until it has one.
    func start(_ request: PlaybackRequest, next: @escaping @MainActor () -> SkipReference?) {
        guard session == nil, let ctx = request.show, !ctx.isMovie else { return }
        let series = "\(ctx.show.id).\(ctx.seasonID)"
        let target = Self.listener(request.torrent, request.file)
        session = SkipSession(target: target, series: series, episode: ctx.episode, library: Self.library)
        self.series = series
        nextProvider = next
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let model = self else { return }
                    await model.tick()
                }
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
    }

    /// The file's chapters, once the player has them: openings and endings they name are matched with priority.
    func setChapters(_ chapters: [(name: String, start: Double, end: Double?)], duration: Double) {
        guard let session else { return }
        let themes = ChapterSkips.segments(chapters, duration: duration).filter { $0.kind == .intro || $0.kind == .credits }
        Task { await session.setThemes(themes) }
    }

    /// Stops listening and saves what was heard for the next episodes.
    func stop() {
        loop?.cancel()
        loop = nil
        if let n = next { n.ref.torrent.clearWants(tag: Self.wantTag) }
        if let session { Task.detached(priority: .utility) { await session.finish() } }
        session = nil
        next = nil
        nextProvider = nil
    }

    private func tick() async {
        guard let session else { return }
        if next == nil, let ref = nextProvider?() {
            let listener = Self.listener(ref.torrent, ref.file)
            next = (ref, listener)
            await session.addReference(listener, episode: ref.episode)
        }
        let found = await session.refresh()
        guard self.session === session else { return }
        if found != content { content = found }
        await fetchNextEnding(found)
    }

    /// The first time a season is watched there is no earlier episode to find the ending with, and the next one is
    /// only prefetched at its start: fetch the end of it too, in the background and not on a metered network.
    private func fetchNextEnding(_ found: ContentSkips?) async {
        guard !tailWanted, let n = next, let series, let session, let found, found.credits == .unknown,
              NetworkCost.shared.isCheap else { return }
        let heard = await Self.library.episodes(series: series).contains { entry in
            entry.key != session.episode && entry.key != n.ref.episode
                && entry.value.print.coverage(from: entry.value.duration / 2, to: entry.value.duration) > 0.9
        }
        guard !heard else { return }
        let duration = await n.listener.duration
        guard duration > 0 else { return }
        let from = max(duration / 2, duration - Self.tailSeconds)
        let ranges = await n.listener.byteRanges(for: [from...duration])
        guard !ranges.isEmpty else { return }
        n.ref.torrent.want(fileIndex: n.ref.file.index, ranges: ranges, urgency: .background, tag: Self.wantTag)
        tailWanted = true
    }

    private static func listener(_ torrent: Torrent, _ file: TorrentFile) -> EpisodeListener {
        EpisodeListener(id: "\(torrent.infoHashHex)/\(file.index)", fileSize: file.length,
                        read: TorrentFileBytes(torrent: torrent, fileIndex: file.index).reader,
                        decoder: AudioToolboxDecoder.factory)
    }
}

/// Reads a file of a torrent for SkipKit: only bytes already downloaded, never waiting for or prioritizing any.
private struct TorrentFileBytes: @unchecked Sendable {
    let torrent: Torrent
    let fileIndex: Int

    var reader: ByteReader {
        let source = self
        return { offset, length in
            source.torrent.availableData(fileIndex: source.fileIndex, offset: offset, length: length)
        }
    }
}

/// Whether the network is one to fetch extra data on: not cellular or a personal hotspot, not Low Data Mode.
private final class NetworkCost: @unchecked Sendable {
    static let shared = NetworkCost()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cheap = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let cheap = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            self.lock.lock()
            self.cheap = cheap
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "ContentSkips.network", qos: .utility))
    }

    var isCheap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cheap
    }
}
