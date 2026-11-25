import SwiftUI
import UIKit
import TorrentKit
import CatalogKit
import SourceKit

/// What an episode's download control shows.
enum DownloadStatus: Equatable {
    case notDownloaded
    /// Queued, or its release is being found.
    case waiting
    case downloading(Double)
    case paused(Double)
    case completed
    case failed(String?)

    var isPresent: Bool { self != .notDownloaded }
}

/// Episodes and movies kept on the device to watch offline. Each download is an episode resolved to a file in a
/// release, the same way Play finds one; the file is then fetched in full in the background and its release is kept
/// out of the streaming cache until the download is removed.
///
/// Releases are found one at a time, and at most `maxActiveReleases` fetch at once, in the order shows were added
/// and then episode order, so the first episodes are ready first. While a player streams something that isn't on
/// the device yet, other releases wait so it has the bandwidth.
@MainActor
final class DownloadsModel: ObservableObject {
    @Published private(set) var library: DownloadLibrary
    /// How much of each started download is on the device, by episode key.
    @Published private(set) var fractions: [String: Double] = [:]

    private unowned let app: AppModel
    private unowned let shows: ShowsModel
    private let fileURL: URL
    private var finder: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// Torrent objects each download's file was marked wanted on, so it's marked once per torrent.
    private var marked: [String: ObjectIdentifier] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let maxActiveReleases = 2
    /// Space left free on the phone beyond what a download needs.
    private static let spareSpace: Int64 = 1_000_000_000

    init(app: AppModel, shows: ShowsModel) {
        self.app = app
        self.shows = shows
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentStream/downloads.json")
        library = (try? Data(contentsOf: fileURL)).map(DownloadLibrary.decode) ?? DownloadLibrary()
        // An attempt cut short by the app closing starts over.
        for r in library.records where r.state == .finding { library.update(r.id) { $0.state = .queued } }
        // Releases holding downloads are known before the cache is first trimmed.
        syncPins()
        app.refreshStorage()
        app.trimCache()
        startTicking()
        findNext()
    }

    // MARK: reading

    func status(_ key: String) -> DownloadStatus {
        guard let r = library[key] else { return .notDownloaded }
        switch r.state {
        case .queued, .finding: return .waiting
        case .downloading: return .downloading(fractions[key] ?? 0)
        case .paused: return .paused(fractions[key] ?? 0)
        case .completed: return .completed
        case .failed: return .failed(r.failure)
        }
    }

    func status(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) -> DownloadStatus {
        status(ShowsModel.key(d.show.id, s.id, e.number))
    }

    func summary(_ show: Show) -> DownloadSummary { library.summary(show: show.id) }

    /// Shows with downloads, the most recently downloaded first.
    var downloadedShows: [Show] { library.shows }

    /// The release a download comes from, which Play uses so the episode plays from the device.
    func release(forKey key: String) -> DownloadRelease? {
        library[key]?.release
    }

    // MARK: downloading

    func download(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) {
        if add(d, s, e) { changed() }
        findNext()
    }

    /// Every aired episode of a season not downloaded yet. Returns how many were added.
    @discardableResult
    func download(season s: ShowSeason, of d: ShowDetails) -> Int {
        let n = s.episodes.filter { $0.isAired && add(d, s, $0) }.count
        if n > 0 { changed() }
        findNext()
        return n
    }

    /// Every aired episode of every season. Returns how many were added.
    @discardableResult
    func downloadAll(_ d: ShowDetails) -> Int {
        let n = d.seasons.reduce(0) { sum, s in sum + s.episodes.filter { $0.isAired && add(d, s, $0) }.count }
        if n > 0 { changed() }
        findNext()
        return n
    }

    /// The movie, or a show's only episode.
    func downloadMovie(_ d: ShowDetails) {
        guard let s = d.seasons.first, let e = s.episodes.first(where: \.isAired) else { return }
        download(d, s, e)
    }

    /// The movie's download key, as `status` takes it.
    func movieKey(_ d: ShowDetails) -> String? {
        guard let s = d.seasons.first, let e = s.episodes.first(where: \.isAired) else { return nil }
        return ShowsModel.key(d.show.id, s.id, e.number)
    }

    func retry(_ key: String) {
        guard let r = library[key], r.state == .failed else { return }
        library.update(key) { $0.state = $0.release == nil ? .queued : .downloading; $0.failure = nil }
        changed()
        findNext()
    }

    /// Adds a record for an episode not downloaded yet; a failed one is tried again.
    private func add(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) -> Bool {
        guard e.isAired else { return false }
        let key = ShowsModel.key(d.show.id, s.id, e.number)
        if library[key]?.state == .failed {
            library.update(key) { $0.state = $0.release == nil ? .queued : .downloading; $0.failure = nil }
            return true
        }
        return library.add(DownloadRecord(id: key, show: d.show, seasonID: s.id, season: s.number, episode: e.number,
                                          episodeTitle: e.title, thumbnailURL: e.thumbnailURL,
                                          isMovie: d.show.isMovie || s.media.isMovie))
    }

    // MARK: removing

    /// Deletes the episode from the device, or stops it downloading.
    func remove(_ key: String) {
        guard let r = library.remove(key) else { return }
        fractions[key] = nil
        marked[key] = nil
        if let rel = r.release { letGo(rel) }
        changed()
    }

    func removeAll(show: Show) {
        for r in library.records(show: show.id) { remove(r.id) }
    }

    func removeEverything() {
        for r in library.records { remove(r.id) }
    }

    /// A release a download no longer needs: the episode's file stops downloading, and the release's data goes once
    /// no other download uses it.
    private func letGo(_ rel: DownloadRelease) {
        let others = library.others(using: rel.infoHash)
        if others.isEmpty {
            app.releaseDownload(rel.infoHash)
        } else if !others.contains(where: { $0.release?.fileIndex == rel.fileIndex }) {
            app.client.torrent(infoHashHex: rel.infoHash)?.setWanted(false, fileIndex: rel.fileIndex)
        }
    }

    // MARK: finding releases

    private func findNext() {
        guard finder == nil, library.nextToFind != nil else { return }
        finder = Task { [weak self] in
            while let self, let r = self.library.nextToFind {
                await self.find(r)
            }
            self?.finder = nil
        }
    }

    private func find(_ r: DownloadRecord) async {
        library.update(r.id) { $0.state = .finding }
        guard let d = try? await shows.loadDetails(r.show) else {
            return fail(r.id, "Episodes couldn’t be loaded. Check your connection and try again.")
        }
        guard let s = d.season(id: r.seasonID), let e = s.episodes.first(where: { $0.number == r.episode }) else {
            return fail(r.id, "This episode is no longer listed.")
        }
        let found: (torrent: Torrent, file: TorrentFile, release: DownloadRelease)
        if let pack = packHolding(d, s, e, isMovie: r.isMovie) {
            found = pack
        } else {
            do {
                let res = try await shows.resolve(d, s, e, source: nil) { _ in }
                found = (res.torrent, res.file,
                         DownloadRelease(infoHash: res.torrent.infoHashHex, fileIndex: res.file.index, magnet: res.source.magnet,
                                         torrentURL: res.source.torrentURL, group: res.source.group,
                                         isBatch: res.source.isBatch, length: res.file.length))
            } catch {
                return fail(r.id, PlaybackLauncher.message(for: error))
            }
        }
        // Removed while its release was being found.
        guard library[r.id] != nil else { return }
        let missing = found.file.length - (found.torrent.downloadedBytes(fileIndex: found.file.index) ?? 0)
        let need = missing + remainingBytes() + Self.spareSpace
        if let free = app.availableCapacity, free > 0, need > free {
            return fail(r.id, "There isn’t enough storage. Free up \(Format.bytes(need - free)) and try again.")
        }
        library.update(r.id) {
            $0.release = found.release
            $0.state = .downloading
            $0.failure = nil
        }
        changed()
    }

    /// The episode's file in a season pack another download of the show already uses, so its release isn't searched.
    private func packHolding(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode,
                             isMovie: Bool) -> (torrent: Torrent, file: TorrentFile, release: DownloadRelease)? {
        for pack in library.packs(show: d.show.id) {
            guard let info = app.sourceInfo(pack.infoHash) ?? app.client.torrent(infoHashHex: pack.infoHash)?.torrentInfo,
                  let f = ShowsModel.pickFile(info, s, e, isMovie: isMovie),
                  let t = app.sourceTorrent(pack.infoHash) else { continue }
            var rel = pack
            rel.fileIndex = f.index
            rel.length = f.length
            return (t, f, rel)
        }
        return nil
    }

    /// What downloads already under way still have to write.
    private func remainingBytes() -> Int64 {
        library.records.filter { $0.state == .downloading }.reduce(0) { sum, r in
            guard let rel = r.release, let length = rel.length else { return sum }
            let done = app.client.torrent(infoHashHex: rel.infoHash)?.downloadedBytes(fileIndex: rel.fileIndex) ?? 0
            return sum + max(0, length - done)
        }
    }

    private func fail(_ key: String, _ message: String) {
        guard library[key] != nil else { return }
        library.update(key) {
            $0.state = .failed
            $0.failure = message
        }
        changed()
    }

    // MARK: fetching

    private func startTicking() {
        guard ticker == nil, library.records.contains(where: { $0.state == .downloading }) else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.tick() else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.ticker = nil
        }
    }

    /// Keeps the releases that should be fetching running, notes progress and finished files. Returns whether
    /// anything is still downloading.
    private func tick() -> Bool {
        let downloading = library.records.filter { $0.state == .downloading }
        guard !downloading.isEmpty else { return false }
        let streaming = app.isStreamingFromNetwork
        let ordered = Self.order(downloading)
        var active: [String] = []
        for r in ordered {
            guard let h = r.release?.infoHash, !active.contains(h) else { continue }
            if active.count < Self.maxActiveReleases || app.isPlaying(hash: h) { active.append(h) }
        }
        var next = fractions
        var stateChanged = false
        var finished: Set<String> = []
        for r in ordered {
            guard let rel = r.release else { continue }
            guard app.hasTorrent(rel.infoHash) else {
                // The release went (removed with a title added by link): it's found again.
                library.update(r.id) { $0.release = nil; $0.state = .queued }
                next[r.id] = nil
                stateChanged = true
                continue
            }
            let isActive = active.contains(rel.infoHash)
            // Releases waiting their turn stay as they are; dormant ones aren't woken.
            guard isActive || app.client.torrent(infoHashHex: rel.infoHash) != nil,
                  let t = isActive ? app.sourceTorrent(rel.infoHash) : app.client.torrent(infoHashHex: rel.infoHash)
            else { continue }
            if isActive {
                if marked[r.id] != ObjectIdentifier(t) {
                    t.setWanted(true, fileIndex: rel.fileIndex)
                    marked[r.id] = ObjectIdentifier(t)
                }
                if streaming && !app.isPlaying(hash: rel.infoHash) {
                    if !t.isPaused { t.pause() }
                } else if t.isPaused {
                    t.resume()
                }
            }
            guard let done = t.downloadedBytes(fileIndex: rel.fileIndex),
                  let length = rel.length ?? t.torrentInfo?.files.first(where: { $0.index == rel.fileIndex })?.length else { continue }
            if done >= length {
                library.update(r.id) {
                    $0.state = .completed
                    $0.completedAt = Date()
                    $0.release?.length = length
                }
                next[r.id] = nil
                marked[r.id] = nil
                finished.insert(rel.infoHash)
                stateChanged = true
            } else {
                // Steps of half a percent, so pages redraw when the ring would move.
                next[r.id] = (Double(done) / Double(max(1, length)) * 200).rounded(.down) / 200
            }
        }
        // A release with nothing more to fetch goes quiet unless a player has it.
        for h in finished where !library.records.contains(where: { $0.release?.infoHash == h && $0.state.isPending })
            && !app.isPlaying(hash: h) {
            app.client.torrent(infoHashHex: h)?.pause()
        }
        if next != fractions { fractions = next }
        if stateChanged {
            changed()
            app.refreshStorage()
            findNext()
        }
        return library.records.contains { $0.state == .downloading }
    }

    /// Shows in the order their first download was added, then season and episode order.
    private static func order(_ records: [DownloadRecord]) -> [DownloadRecord] {
        let firstAdded = Dictionary(records.map { ($0.show.id, $0.addedAt) }, uniquingKeysWith: min)
        return records.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.show.id != b.show.id {
                let fa = firstAdded[a.show.id] ?? a.addedAt, fb = firstAdded[b.show.id] ?? b.addedAt
                return fa != fb ? fa < fb : a.show.id < b.show.id
            }
            return (a.season, a.episode) < (b.season, b.episode)
        }
    }

    // MARK: saving

    private func changed() {
        if let data = library.encoded() { try? data.write(to: fileURL, options: .atomic) }
        syncPins()
        startTicking()
    }

    private func syncPins() {
        let pending = Set(library.records.filter { $0.state.isPending }.compactMap { $0.release?.infoHash })
        app.setPinned(library.infoHashes, downloading: pending)
    }

    // MARK: app lifecycle

    /// iOS gives a backgrounded app a little time; downloads use it rather than stopping at once.
    func enteredBackground() {
        guard backgroundTask == .invalid, library.records.contains(where: { $0.state.isPending }) else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
            MainActor.assumeIsolated {
                // Out of time: progress is saved before the app is suspended.
                self?.app.client.applicationDidEnterBackground()
                self?.endBackgroundTask()
            }
        }
    }

    func enteredForeground() {
        endBackgroundTask()
        startTicking()
        findNext()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Download control

/// An episode's download button: an arrow to start, a ring while it comes in, a filled arrow once it's on the
/// device. After the first tap it opens a menu, so a download is never removed by a stray touch.
struct DownloadControl: View {
    let status: DownloadStatus
    /// Drawn as a filled circle beside the Play button, like My List.
    var prominent = false
    let onDownload: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    var body: some View {
        Group {
            if status == .notDownloaded {
                Button(action: onDownload) { glyph }
            } else {
                Menu { menu } label: { glyph }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .sensoryFeedback(.start, trigger: status.isPresent) { old, new in !old && new }
    }

    private var glyph: some View {
        DownloadGlyph(status: status)
            .font(prominent ? .title3.weight(.semibold) : .title3)
            .frame(width: prominent ? Metrics.playButtonHeight : Metrics.touchTarget,
                   height: prominent ? Metrics.playButtonHeight : Metrics.touchTarget)
            .background { if prominent { Circle().fill(.fill.tertiary) } }
            .contentShape(.circle)
    }

    @ViewBuilder
    private var menu: some View {
        switch status {
        case .notDownloaded:
            EmptyView()
        case .waiting:
            Section("Waiting to Download") {
                Button(role: .destructive, action: onRemove) { Label("Cancel Download", systemImage: "xmark") }
            }
        case .downloading(let f), .paused(let f):
            Section("Downloading, \(f.formatted(.percent.precision(.fractionLength(0))))") {
                Button(role: .destructive, action: onRemove) { Label("Cancel Download", systemImage: "xmark") }
            }
        case .completed:
            Section("Downloaded") {
                Button(role: .destructive, action: onRemove) { Label("Remove Download", systemImage: "trash") }
            }
        case .failed(let reason):
            Section(reason ?? "The download didn’t finish.") {
                Button(action: onRetry) { Label("Try Again", systemImage: "arrow.clockwise") }
                Button(role: .destructive, action: onRemove) { Label("Cancel Download", systemImage: "xmark") }
            }
        }
    }

    private var accessibilityText: String {
        switch status {
        case .notDownloaded: return "Download"
        case .waiting: return "Waiting to download"
        case .downloading(let f), .paused(let f): return "Downloading, \(f.formatted(.percent.precision(.fractionLength(0))))"
        case .completed: return "Downloaded"
        case .failed: return "Download failed"
        }
    }
}

/// The symbol for a download's state, in the current font's size.
struct DownloadGlyph: View {
    let status: DownloadStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch status {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            case .waiting:
                Image(systemName: "arrow.down.circle.dotted")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeat(.continuous), isActive: !reduceMotion)
            case .downloading(let f), .paused(let f):
                DownloadRing(fraction: f)
            case .completed:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .contentTransition(.symbolEffect(.replace))
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: status)
    }
}

/// Progress as a ring around a stop square, as the App Store draws it.
private struct DownloadRing: View {
    let fraction: Double
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = Metrics.indicator

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.03, fraction))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}
