import Foundation
import MediaKit
import TorrentKit

extension PlaybackRequest {
    /// The video file's extension, lowercased ("mkv").
    var fileExtension: String { file.fileExtension }
}

/// Container indexes (Matroska Cues, MP4 sample tables) read before playback, so the player can open on a keyframe
/// and the seek previews don't read them again. Kept for the last few files.
@MainActor
final class KeyframeIndexCache {
    static let shared = KeyframeIndexCache()

    private var entries: [String: any KeyframeIndex] = [:]
    private var order: [String] = []
    private static let capacity = 12

    nonisolated static func supports(fileExtension: String) -> Bool {
        ["mkv", "webm", "mk3d", "mp4", "m4v", "mov"].contains(fileExtension.lowercased())
    }

    func index(_ torrent: Torrent, fileIndex: Int) -> (any KeyframeIndex)? {
        entries[Self.key(torrent, fileIndex)]
    }

    func store(_ index: any KeyframeIndex, torrent: Torrent, fileIndex: Int) {
        let k = Self.key(torrent, fileIndex)
        if entries[k] == nil { order.append(k) }
        entries[k] = index
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    /// The keyframe at or before `seconds` in the request's file, when its index is known and one is within
    /// `within` seconds. Opening there needs no decoding of frames before the spot.
    func keyframeTime(atOrBefore seconds: Double, for request: PlaybackRequest, within: Double = 30) -> Double? {
        guard let k = index(request.torrent, fileIndex: request.file.index)?.keyframes, !k.isEmpty else { return nil }
        guard let i = Self.lastIndex(k, atOrBefore: seconds) else { return nil }
        let t = k[i].time
        return seconds - t <= within ? t : nil
    }

    /// Reads a file's index, asking the swarm for what it needs at `urgency` under `tag`. Nil when the container has
    /// none or the bytes didn't come in time. Stops early when the task is cancelled.
    nonisolated static func read(torrent: Torrent, fileIndex: Int, fileLength: Int64, urgency: Torrent.RangeUrgency,
                                 tag: String, timeout: TimeInterval, attempts: Int) async -> (any KeyframeIndex)? {
        let read = SeekPreviews.reader(torrent: torrent, fileIndex: fileIndex, urgency: urgency, tag: tag, timeout: timeout)
        for attempt in 0..<max(1, attempts) {
            do {
                return try await MediaIndex.load(fileLength: fileLength, read: read)
            } catch MediaIndexError.dataUnavailable {
                if Task.isCancelled || attempt == attempts - 1 { return nil }
                try? await Task.sleep(nanoseconds: UInt64(5 + attempt * 5) * 1_000_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Index of the last keyframe at or before `seconds`; the first one when all are later.
    nonisolated static func lastIndex(_ k: [Keyframe], atOrBefore seconds: Double) -> Int? {
        guard !k.isEmpty else { return nil }
        var lo = 0, hi = k.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if k[mid].time <= seconds { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    private static func key(_ t: Torrent, _ fileIndex: Int) -> String { "\(t.infoHashHex)#\(fileIndex)" }
}

/// Gets episodes the viewer is likely to play ready before Play is pressed: finds the release, wakes its swarm, and
/// loads what the player reads before its first frame (the container's head and index, then the opening seconds or
/// the group of pictures at the resume point). Nothing of it shows; it only makes Play start sooner.
///
/// Warm-ups belong to a scope (a page). Leaving the page releases them after a short grace, so going back and forth
/// keeps them; opening a player releases everything. At most `maxWarms` episodes are held, the likeliest kept, and
/// what is loaded beyond the essentials stays within the app's warm-up budget, a share of the cache.
@MainActor
final class Prewarmer {
    /// How likely the episode is to be played next, weakest first.
    enum Reason: Int, Comparable {
        /// On screen, such as the episode after the one the Play button starts. Only releases already known.
        case prominent
        /// Further down Continue Watching.
        case likely
        /// What a show page's Play button or the front of Continue Watching starts.
        case primary
        /// A finger is on its row or card.
        case touch

        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
    }

    struct Target {
        /// Episode key (`ShowsModel.key`).
        let key: String
        /// For the playback log.
        let label: String
        let resumeAt: Double?
        /// Resume position as a share of the duration, to guess its byte offset before the index is read.
        let resumeFraction: Double?
        let reason: Reason
        /// Finds the release and file; nil when there is none to warm.
        let resolve: () async -> ResolvedEpisode?
    }

    private final class Warm {
        let key: String
        let torrent: Torrent
        let fileIndex: Int
        var reason: Reason
        var scopes: Set<String>
        /// Bytes asked for.
        var bytes: Int64 = 0
        let at = Date()

        init(key: String, torrent: Torrent, fileIndex: Int, reason: Reason, scope: String) {
            self.key = key
            self.torrent = torrent
            self.fileIndex = fileIndex
            self.reason = reason
            scopes = [scope]
        }

        var tags: [String] { [Prewarmer.tag(key), Prewarmer.tag(key) + ".index", Prewarmer.tag(key) + ".more"] }
    }

    private struct Lane {
        let scope: String
        let keys: [String]
        let task: Task<Void, Never>
        var done = false
    }

    private unowned let app: AppModel
    private var warms: [String: Warm] = [:]
    /// Running warm-ups by lane; a lane runs its targets one after another so the first gets the bandwidth.
    private var lanes: [String: Lane] = [:]
    private var releases: [String: Task<Void, Never>] = [:]
    /// Releases held back while an episode is being opened, which may be one of them.
    private var deferred = Set<String>()
    private var launches = 0
    /// Source a launch is opening; never paused by a release.
    private weak var launched: Torrent?

    static let maxWarms = 3
    /// Opening bytes asked for when starting from the beginning: enough for the first picture of a high-bitrate
    /// 1080p episode with margin.
    static let headBytes: Int64 = 28 << 20
    private static let tailBytes: Int64 = 2 << 20
    private static let mb: Int64 = 1 << 20

    init(app: AppModel) {
        self.app = app
    }

    nonisolated static func tag(_ key: String) -> String { "warm.\(key)" }

    /// Warms `targets` in order under `scope`. A lane already running the same targets carries on; otherwise
    /// it starts over, and warm-ups of this lane's previous targets that no other scope holds are dropped.
    func warm(_ targets: [Target], scope: String, lane: String? = nil) {
        let laneID = lane ?? scope
        releases[scope]?.cancel()
        releases[scope] = nil
        deferred.remove(scope)
        guard !app.isPlayingAnything, !targets.isEmpty else { return }
        // A player is likely soon: have libVLC's plugin list built and held before it's needed.
        PlaybackEngine.prepareLibrary()
        let keys = targets.map(\.key)
        if let l = lanes[laneID], l.keys == keys, l.scope == scope, !l.done { return }
        if let old = lanes[laneID] {
            old.task.cancel()
            if old.scope == scope && laneID == scope {
                for k in old.keys where !keys.contains(k) { drop(scope: scope, from: k) }
            }
        }
        let task = Task { [weak self] in
            for t in targets {
                guard let self, !Task.isCancelled else { return }
                await self.run(t, scope: scope)
            }
            self?.laneFinished(laneID, keys: keys)
        }
        lanes[laneID] = Lane(scope: scope, keys: keys, task: task)
    }

    /// The scope's page went away: its warm-ups go quiet after a short grace, unless it comes back.
    func release(scope: String) {
        releases[scope]?.cancel()
        releases[scope] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.releases[scope] = nil
            if self.launches > 0 { self.deferred.insert(scope) } else { self.perform(release: scope) }
        }
    }

    /// A player is opening: every warm-up stops asking for data. Sources are left running; the app pauses
    /// those the player doesn't use.
    func releaseAll() {
        for l in lanes.values { l.task.cancel() }
        lanes.removeAll()
        for r in releases.values { r.cancel() }
        releases.removeAll()
        deferred.removeAll()
        for w in warms.values { w.tags.forEach(w.torrent.clearWants) }
        warms.removeAll()
    }

    /// An episode is being opened; releases wait until it has (or has failed to).
    func beginLaunch() { launches += 1 }

    func endLaunch() {
        launches = max(0, launches - 1)
        guard launches == 0 else { return }
        let pending = deferred
        deferred.removeAll()
        pending.forEach(perform(release:))
    }

    /// The source a launch is about to play; releases leave it running.
    func launching(_ torrent: Torrent) { launched = torrent }

    /// Whether a lane is open (running or done, not released).
    func holds(lane: String) -> Bool { lanes[lane] != nil }

    // MARK: work

    private func laneFinished(_ lane: String, keys: [String]) {
        if lanes[lane]?.keys == keys { lanes[lane]?.done = true }
    }

    private func perform(release scope: String) {
        for (id, l) in lanes where l.scope == scope {
            l.task.cancel()
            lanes[id] = nil
        }
        for k in Array(warms.keys) { drop(scope: scope, from: k) }
    }

    private func drop(scope: String, from key: String) {
        guard let w = warms[key] else { return }
        w.scopes.remove(scope)
        if w.scopes.isEmpty { discard(w) }
    }

    private func discard(_ w: Warm) {
        warms[w.key] = nil
        w.tags.forEach(w.torrent.clearWants)
        quiet(w.torrent)
    }

    /// Pauses a source no warm-up, launch or player uses any more, so it stops taking connections.
    private func quiet(_ torrent: Torrent) {
        guard !warms.values.contains(where: { $0.torrent === torrent }), torrent !== launched,
              !app.isPlaying(torrent), !torrent.isPaused else { return }
        torrent.pause()
    }

    /// Makes room for a warm-up of `reason`: drops the weakest (then oldest) held by none of `scope`'s lanes.
    private func makeRoom(for reason: Reason, scope: String) -> Bool {
        while warms.count >= Self.maxWarms {
            let candidates = warms.values.filter { !$0.scopes.contains(scope) || $0.reason < reason }
            guard let weakest = candidates.min(by: { ($0.reason, $0.at) < ($1.reason, $1.at) }),
                  weakest.reason <= reason else { return false }
            discard(weakest)
        }
        return true
    }

    private var spent: Int64 { warms.values.reduce(0) { $0 + $1.bytes } }

    private func run(_ t: Target, scope: String) async {
        if let w = warms[t.key] {
            w.scopes.insert(scope)
            w.reason = max(w.reason, t.reason)
            return
        }
        let started = Date()
        guard let r = await t.resolve() else { return }
        if let w = warms[t.key] {
            w.scopes.insert(scope)
            w.reason = max(w.reason, t.reason)
            return
        }
        // Resolving joins the swarm; if the page went away meanwhile, leave it quiet.
        guard !Task.isCancelled, !app.isPlayingAnything, makeRoom(for: t.reason, scope: scope) else {
            quiet(r.torrent)
            return
        }
        let torrent = r.torrent, fileIndex = r.file.index, length = r.file.length
        if torrent.isPaused { torrent.resume() }
        let w = Warm(key: t.key, torrent: torrent, fileIndex: fileIndex, reason: t.reason, scope: scope)
        warms[t.key] = w
        let tag = Self.tag(t.key)
        let tail = max(0, length - Self.tailBytes)..<length

        // Before the index is known: the head, the tail (where Matroska Cues and many MP4 sample tables are) and,
        // when resuming, the spot estimated by proportion.
        var guess: [Range<Int64>] = [tail]
        if let f = t.resumeFraction, f > 0 {
            let at = Int64(Double(length) * min(1, f))
            guess.append(0..<min(length, 4 * Self.mb))
            guess.append(max(0, at - 2 * Self.mb)..<min(length, at + 10 * Self.mb))
        } else {
            guess.append(0..<min(length, Self.headBytes))
        }
        torrent.want(fileIndex: fileIndex, ranges: guess, urgency: .soon, tag: tag)
        w.bytes = Self.total(guess)

        var index = KeyframeIndexCache.shared.index(torrent, fileIndex: fileIndex)
        if index == nil, KeyframeIndexCache.supports(fileExtension: r.file.fileExtension) {
            index = await KeyframeIndexCache.read(torrent: torrent, fileIndex: fileIndex, fileLength: length, urgency: .soon,
                                                  tag: tag + ".index", timeout: 30, attempts: 2)
            torrent.clearWants(tag: tag + ".index")
            if let index { KeyframeIndexCache.shared.store(index, torrent: torrent, fileIndex: fileIndex) }
        }
        guard !Task.isCancelled, warms[t.key] === w else { return }

        // With the index: exactly what the player reads first.
        var soon = guess
        var more: [Range<Int64>] = []
        if let index, let first = index.keyframes.first {
            let headerEnd = min(first.clusterOffset, 32 * Self.mb)
            let duration = index.duration ?? index.keyframes.last?.time ?? 0
            let rate = duration > 0 ? Double(length) / duration : 0
            soon = [tail, 0..<min(length, headerEnd + 2 * Self.mb)]
            if let at = t.resumeAt, at > 0, let gop = Self.pictures(index, at: at, length: length) {
                soon.append(gop)
            } else {
                // About the first half minute.
                let lead = rate > 0 ? min(28 * Self.mb, max(6 * Self.mb, Int64(rate * 30))) : 16 * Self.mb
                let end = min(length, headerEnd + lead)
                soon.append(0..<end)
                if end < min(length, Self.headBytes) { more.append(end..<min(length, Self.headBytes)) }
            }
            torrent.want(fileIndex: fileIndex, ranges: soon, urgency: .soon, tag: tag)
            w.bytes = Self.total(soon)
        }
        if !more.isEmpty, spent + Self.total(more) <= app.warmBudget {
            torrent.want(fileIndex: fileIndex, ranges: more, urgency: .background, tag: tag + ".more")
            w.bytes += Self.total(more)
        }

        // Wait (up to 45 s) for it to land before the lane moves on, so the likeliest episode isn't sharing the
        // connection with the others.
        for _ in 0..<90 {
            if await Self.isLoaded(torrent: torrent, fileIndex: fileIndex, ranges: soon) {
                PlaybackTrace.shared.timing("warm ready: \(t.label) (\(Self.total(soon) / Self.mb) MB\(index == nil ? ", no index" : ""))",
                                            since: started)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled || warms[t.key] !== w { return }
        }
        PlaybackTrace.shared.timing("warm still loading: \(t.label)", since: started)
    }

    /// From the keyframe at or before `at` to the first one at least 8 s after it: what playing from there reads
    /// before its first frame and the next few seconds. 2–24 MB.
    private static func pictures(_ index: any KeyframeIndex, at: Double, length: Int64) -> Range<Int64>? {
        let k = index.keyframes
        guard let i = KeyframeIndexCache.lastIndex(k, atOrBefore: at) else { return nil }
        let start = min(k[i].clusterOffset, length)
        var j = i + 1
        while j < k.count, k[j].time < k[i].time + 8 { j += 1 }
        let next = j < k.count ? k[j].clusterOffset : length
        let end = min(length, start + min(24 * mb, max(2 * mb, next - start)))
        return start < end ? start..<end : nil
    }

    private static func total(_ ranges: [Range<Int64>]) -> Int64 { ranges.reduce(0) { $0 + Int64($1.count) } }

    /// Every range has arrived, checked one byte every 2 MB and at each end. Doesn't fetch or wait.
    nonisolated private static func isLoaded(torrent: Torrent, fileIndex: Int, ranges: [Range<Int64>]) async -> Bool {
        for r in ranges where !r.isEmpty {
            var probes = Array(stride(from: r.lowerBound, to: r.upperBound, by: Int64(2 << 20)))
            probes.append(r.upperBound - 1)
            for p in probes.reversed() {
                if await torrent.waitForBlocks(fileIndex: fileIndex, offset: p, length: 1, timeout: 0) == nil { return false }
            }
        }
        return true
    }
}
