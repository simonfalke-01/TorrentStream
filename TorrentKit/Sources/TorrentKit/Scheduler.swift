import Foundation

/// Blocks `start..<end` of one piece that should be downloaded, at a priority. Spans are kept most urgent first.
struct Span {
    let piece: Int
    let start: Int
    let end: Int
    let priority: Int
    /// Blocks before this one were already received or requested (an optimization; reset when requests are released).
    var cursor: Int
    /// The first blocks of a window the player jumped to, requested from several peers at once: a seeder serving
    /// from a busy disk can take seconds for a cold block while it keeps sending blocks that are in its cache.
    var raceHead = 0
    /// Bytes between the start of the window this span belongs to (a reader's position) and the span: how long the
    /// player can wait for it.
    var distance: Int64 = 0

    /// What a reader (the player) or a `.now` want is blocked on.
    static let now = 0
    /// Needed within seconds: container index, the rest of the first megabytes past readers, `.soon` wants.
    static let soon = 1
    static let readahead = 2
    /// `.background` wants, far read-ahead, finishing partly downloaded pieces.
    static let background = 3
    static let prefetch = 4
    static let wanted = 5
}

extension Torrent {
    /// Lock held: recomputes `spans` from readers, wants, prefetch and wanted files.
    func rebuildOrder(_ info: TorrentInfo) {
        orderDirty = false
        cursorsStale = false
        var out: [Span] = []
        let pl = Int64(info.pieceLength)
        let bs = Int64(blockSize)

        func add(_ s: Int64, _ e: Int64, _ priority: Int, raceHead: Int = 0, lead: Int64 = 0) {
            let start = max(0, s), end = min(info.totalLength, e)
            guard end > start else { return }
            var head = raceHead
            var piece = Int(start / pl)
            while piece < info.pieceCount {
                let ps = Int64(piece) * pl
                if ps >= end { break }
                if !have[piece] {
                    let size = Int64(info.pieceSize(piece))
                    let b0 = Int((max(start, ps) - ps) / bs)
                    let b1 = Int((min(end, ps + size) - ps + bs - 1) / bs)
                    if b1 > b0 {
                        let distance = lead + max(0, ps + Int64(b0) * bs - start)
                        out.append(Span(piece: piece, start: b0, end: b1, priority: priority, cursor: b0, raceHead: head, distance: distance))
                    }
                }
                head = 0
                piece += 1
            }
        }
        func fileRange(_ fi: Int, _ from: Int64, _ to: Int64, _ priority: Int, raceHead: Int = 0, lead: Int64 = 0) {
            guard fi >= 0, fi < info.files.count else { return }
            let f = info.files[fi]
            add(f.offset + max(0, from), f.offset + min(f.length, to), priority, raceHead: raceHead, lead: lead)
        }

        // A reader's windows are measured in bytes the player will read: attachments served as a Void element are
        // skipped (the player gets them instantly), so its window continues at the first cluster.
        var skipped: [Int: Range<Int64>] = [:]
        var pending = Set<Int>()
        for fi in streamingFiles where fi < info.files.count {
            if let a = skippedAttachmentsLocked(fi, info) { skipped[fi] = a }
            if layoutPendingLocked(fi, info) { pending.insert(fi) }
        }
        func readerRange(_ r: Reader, _ from: Int64, _ to: Int64, _ priority: Int, raceHead: Int = 0, lead: Int64 = 0) {
            guard let a = skipped[r.fileIndex], r.offset < a.upperBound, r.offset + to > a.lowerBound else {
                fileRange(r.fileIndex, r.offset + from, r.offset + to, priority, raceHead: raceHead, lead: lead)
                return
            }
            // Offsets relative to the reader, past the skipped range.
            let before = max(0, a.lowerBound - r.offset)
            if from < before { fileRange(r.fileIndex, r.offset + from, r.offset + min(to, before), priority, raceHead: raceHead, lead: lead) }
            if to > before {
                let s = max(from, before) - before, e = to - before
                fileRange(r.fileIndex, a.upperBound + s, a.upperBound + e, priority, raceHead: from < before ? 0 : raceHead,
                          lead: lead + max(0, before - from))
            }
        }
        /// A reader at the head of a Matroska file whose layout isn't known yet: only the first elements are urgent,
        /// what follows them may be skipped attachments.
        func critical(_ r: Reader) -> Int64 {
            pending.contains(r.fileIndex) && r.offset < 1 << 20 ? min(criticalBytes, 256 * 1024) : criticalBytes
        }

        let now = Date.timeIntervalSinceReferenceDate
        for (id, r) in readers { readers[id]?.settledUntil = settledUntilLocked(r, info, now: now) }
        let activeReaders = readers.values.filter { $0.fileIndex < info.files.count }.sorted { $0.updated > $1.updated }
        let sortedWants = wants.values.filter { $0.fileIndex >= 0 && $0.fileIndex < info.files.count }.sorted { $0.seq > $1.seq }
        // Embedded fonts the player can do without (served as a Void element while missing) come last in a want, after
        // the first cluster that follows them: a warm-up's first megabytes go to what the first frame waits on.
        var wantSkipped: [Int: Range<Int64>] = [:]
        for w in sortedWants where w.urgency != .now && wantSkipped[w.fileIndex] == nil {
            if let a = skippedAttachmentsLocked(w.fileIndex, info) { wantSkipped[w.fileIndex] = a }
        }
        func wantRanges(_ u: RangeUrgency, _ priority: Int) {
            for w in sortedWants where w.urgency == u {
                for r in w.ranges {
                    if let a = wantSkipped[w.fileIndex], u != .now, r.lowerBound < a.upperBound, r.upperBound > a.upperBound {
                        fileRange(w.fileIndex, r.lowerBound, min(r.upperBound, a.lowerBound), priority)
                        fileRange(w.fileIndex, a.upperBound, r.upperBound, priority)
                        fileRange(w.fileIndex, max(r.lowerBound, a.lowerBound), a.upperBound, priority)
                        continue
                    }
                    fileRange(w.fileIndex, r.lowerBound, r.upperBound, priority, raceHead: priority == Span.now ? Torrent.raceHeadBlocks : 0)
                }
            }
        }

        // What the player is blocked on, the latest seek first.
        for r in activeReaders where r.settledUntil == 0 { readerRange(r, 0, critical(r), Span.now, raceHead: Torrent.raceHeadBlocks) }
        wantRanges(.now, Span.now)
        // What a player reads of a Matroska file before its first frame, besides the head, all at once: cues and tags
        // where the SeekHead points (the end of the file, until the head says), and the start of the first cluster.
        for fi in streamingFiles.sorted() where fi < info.files.count {
            let len = info.files[fi].length
            if pending.contains(fi) {
                let frontier = containers[fi]?.layout.frontier ?? 0
                fileRange(fi, frontier, frontier + 64 * 1024, Span.now)
                // MKV cues and tags usually end the file; the SeekHead in the first block tells exactly.
                fileRange(fi, len - 64 * 1024, len, Span.now)
            }
            for r in containerRangesLocked(fi, info) { fileRange(fi, r.lowerBound, r.upperBound, Span.now) }
        }
        // The next bytes of a player with plenty buffered: needed soon, not raced.
        for r in activeReaders where r.settledUntil > 0 { readerRange(r, 0, critical(r), Span.soon) }
        // Container indexes (MKV cues, MP4 moov at the end) are read when a file is opened or seeked: the last few
        // hundred kilobytes (MKV cues) right after what the player waits on, the rest of the tail (a large moov) once
        // the start is under way, so it doesn't hold back the first frame (a player reading it asks for it anyway).
        // A guess (the exact cues come from the layout above), so it doesn't hold back a seek either: it counts as
        // needed after the critical window.
        for fi in streamingFiles.sorted() where fi < info.files.count {
            let len = info.files[fi].length
            fileRange(fi, len - Torrent.indexTailUrgentBytes, len, Span.soon, lead: criticalBytes)
        }
        for r in activeReaders {
            let c = critical(r), mid = min(soonBytes, 3 * criticalBytes)
            readerRange(r, c, mid, Span.soon, lead: c)
        }
        wantRanges(.soon, Span.soon)
        let mid = min(soonBytes, 3 * criticalBytes)
        for r in activeReaders { readerRange(r, mid, soonBytes, Span.soon, lead: mid) }
        // Read-ahead: the near part before seek-preview wants, the rest after them.
        let nearAhead: Int64 = 64 * 1024 * 1024
        for fi in streamingFiles.sorted() where fi < info.files.count {
            let len = info.files[fi].length
            fileRange(fi, len - Torrent.indexTailBytes, len - Torrent.indexTailUrgentBytes, Span.readahead)
        }
        for r in activeReaders {
            let ahead = readahead[r.fileIndex] ?? Torrent.defaultReadahead
            readerRange(r, soonBytes, min(ahead, nearAhead), Span.readahead)
        }
        wantRanges(.background, Span.background)
        for r in activeReaders {
            let ahead = readahead[r.fileIndex] ?? Torrent.defaultReadahead
            if ahead > nearAhead { readerRange(r, nearAhead, ahead, Span.background) }
        }
        // Pieces left half done by a seek: finish them so they get verified and kept.
        let pl32 = Int64(info.pieceLength)
        for piece in inProgress.keys.sorted() {
            guard let pp = inProgress[piece], pp.receivedCount > 0, !pp.verifying else { continue }
            add(Int64(piece) * pl32, Int64(piece) * pl32 + Int64(pp.size), Span.background)
        }
        // The start (and index) of the file expected to play next.
        if let target = prefetchTarget, target.fileIndex >= 0, target.fileIndex < info.files.count {
            let len = info.files[target.fileIndex].length
            if len > 0 {
                // With a known Matroska layout: everything before the first cluster (fonts included, so a prefetched
                // episode plays with them), its cues, tags and first cluster, then the rest of the requested start.
                for r in containerRangesLocked(target.fileIndex, info) { fileRange(target.fileIndex, r.lowerBound, r.upperBound, Span.prefetch) }
                if let fc = containers[target.fileIndex]?.layout.firstCluster { fileRange(target.fileIndex, 0, fc, Span.prefetch) }
                fileRange(target.fileIndex, 0, max(1, target.bytes), Span.prefetch)
                fileRange(target.fileIndex, len - Torrent.indexTailBytes, len, Span.prefetch)
            }
        }
        // The rest of each wanted file, sequentially from the reader position.
        let files = wantedFiles.filter { $0 >= 0 && $0 < info.files.count }.sorted { a, b in
            let sa = streamingFiles.contains(a), sb = streamingFiles.contains(b)
            return sa != sb ? sa : a < b
        }
        for fi in files {
            let len = info.files[fi].length
            let from = activeReaders.first(where: { $0.fileIndex == fi })?.offset ?? 0
            fileRange(fi, from, len, Span.wanted)
            if from > 0 { fileRange(fi, 0, from, Span.wanted) }
        }
        spans = out
        // What was urgent may not be anymore (a seek): phase 1 marks queued blocks urgent again as it meets them, and
        // the rest may be cancelled to make room. How soon the player needs each queued block is measured again.
        var urgentSpans: [Int: [Int]] = [:]
        for (k, s) in out.enumerated() where s.priority <= Span.soon { urgentSpans[s.piece, default: []].append(k) }
        for p in peersByID.values {
            for (r, v) in p.pending {
                var d = Int64.max
                if let ks = urgentSpans[r.piece] {
                    let b = r.offset / blockSize
                    for k in ks where b >= out[k].start && b < out[k].end { d = min(d, out[k].distance + Int64(b - out[k].start) * bs) }
                }
                p.pending[r]?.distance = d
                if v.priority == Span.now { p.pending[r]?.priority = Span.soon }
            }
        }
    }

    /// Lock held: the progress record of a piece, created on first request; nil while it is being verified.
    private func progressLocked(_ piece: Int, _ info: TorrentInfo) -> PieceProgress? {
        if let pp = inProgress[piece] { return pp.verifying ? nil : pp }
        let pp = PieceProgress(index: piece, size: info.pieceSize(piece))
        inProgress[piece] = pp
        return pp
    }

    private func peerHasNeededLocked(_ peer: PeerConnection) -> Bool {
        guard peer.bitfield.count == have.count else { return false }
        for i in 0..<have.count where peer.bitfield[i] && !have[i] { return true }
        return false
    }

    /// Order in which a peer answers requests (one pass sends many at the same instant).
    static func queuedBefore(_ a: PendingRequest, _ b: PendingRequest) -> Bool { a.seq < b.seq }

    /// Lock held: recomputes requests for every connected peer, fastest first so they get the urgent blocks.
    func rescheduleAllLocked() {
        let active = peers.values.filter { $0.isActive }.sorted { $0.rate > $1.rate }
        for p in active { p.apply(nextActionsLocked(for: p)) }
    }

    /// Lock held: what to send a peer now.
    ///
    /// 1. Blocks the player waits on (`Span.now`) are spread over peers in proportion to their speed — a peer holds
    ///    about what it delivers in half a second (its slow-start window while that speed is being found out) — and
    ///    raced to another peer as soon as no requester is expected to deliver them before the reader gets there.
    ///    The block a reader is blocked on goes to one more peer every `headRaceStep` while it is expected late. A
    ///    peer that takes such blocks has the tail of its queue cancelled, since it serves requests in order.
    /// 2. Then the queue is topped up to cover its rate × (round trip + `queueSeconds`), in span order.
    func nextActionsLocked(for peer: PeerConnection) -> PeerActions {
        var actions = PeerActions()
        if stopped { actions.disconnectReason = "stopped"; return actions }
        if paused { actions.disconnectReason = "paused"; return actions }
        guard !peer.closed else { return actions }
        let now = Date.timeIntervalSinceReferenceDate

        guard let info = info else {
            requestMetadataLocked(peer, into: &actions)
            return actions
        }
        if orderDirty { rebuildOrder(info) }
        if cursorsStale {
            for i in spans.indices { spans[i].cursor = spans[i].start }
            cursorsStale = false
        }
        if !peer.amInterested {
            guard peerHasNeededLocked(peer) else { return actions }
            peer.amInterested = true
            actions.sendInterested = true
        }
        let choked = peer.peerChoking
        if choked && peer.allowedFast.isEmpty { return actions }
        // Next-episode prefetches and background downloads hold back while another torrent's player starves.
        if !isForegroundLocked, let c = client, c.otherTorrentStarving(excluding: self) { return actions }

        let me = ObjectIdentifier(peer)
        let blk = Double(blockSize)
        let rate = peer.rate
        func canRequest(_ piece: Int) -> Bool {
            !have[piece] && peer.has(piece) && (!choked || peer.allowedFast.contains(piece))
        }
        // A new peer is assumed decent, so blocks it doesn't deliver promptly are raced early.
        let assumedRate = rate > 0 ? max(rate, 16 * 1024) : 128 * 1024
        func eta(queued: Int) -> TimeInterval { now + peer.rtt + Double(queued + 1) * blk / assumedRate }
        // A slow peer only takes urgent blocks it can deliver well before the rest of the swarm reaches them: a block
        // first given to a slow peer and then raced is cold on the fast peer's disk, which stalls the player. While
        // the player reads as fast as blocks arrive (start, after a seek) that is a fraction of a second away, so a
        // peer at half the fastest one's speed already holds up the read: it takes blocks further ahead.
        var swarmRate = 0.0, maxRate = 0.0, rateRTT = 0.0
        for p in peers.values where p.isActive && !p.peerChoking && !p.snubbed {
            swarmRate += p.rate
            maxRate = max(maxRate, p.rate)
            rateRTT += p.rate * min(p.answerTime ?? p.rtt, 1)
        }
        let slowPeer = rate > 0 ? rate < 0.5 * maxRate : maxRate > 4 * assumedRate
        func tooSlow(_ s: Span, _ b: Int, queued: Int) -> Bool {
            guard slowPeer, swarmRate > 0 else { return false }
            let dist = Double(s.distance + Int64(b - s.start) * Int64(blockSize))
            return eta(queued: queued) - now > dist / swarmRate - Torrent.slowPeerMargin
        }
        // Updated as this pass cancels requests: a block cancelled moments ago must not be asked again right away.
        var anyCancelled = !peer.cancelled.isEmpty
        func awaitingCancel(_ pp: PieceProgress, _ b: Int) -> Bool {
            anyCancelled && peer.cancelled[BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))] != nil
        }
        func assign(_ pp: PieceProgress, _ b: Int, priority: Int, eta e: TimeInterval, distance: Int64 = .max) {
            let r = BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))
            if pp.owner == nil && !failedAttempts.isEmpty && failedAttempts[pp.index] != nil { pp.owner = me }
            pp.addRequester(b, me)
            pp.requestedAt[b] = now
            pp.eta[b] = e
            peer.requestSeq += 1
            peer.pending[r] = PendingRequest(at: now, eta: e, priority: priority, deliveredBefore: peer.downloadedBytes,
                                             queuedAhead: peer.pending.count, seq: peer.requestSeq, distance: distance)
            actions.requests.append(r)
        }

        func ownedByOther(_ pp: PieceProgress) -> Bool {
            guard let o = pp.owner, o != me else { return false }
            if peersByID[o]?.peerChoking ?? true { pp.owner = nil; return false }
            return true
        }

        // Phase 1: blocks the player waits on.
        var nowPending = 0
        for p in peer.pending.values where p.priority == Span.now { nowPending += 1 }
        // Half a second of the peer's rate (8 blocks at least): its rate is measured on what it is given, so a much
        // smaller share would make a fast peer ramp up slowly while the player waits — and while that rate is still
        // being found out, its whole slow-start window.
        // A peer that hasn't delivered anything yet takes few: most connections of a large swarm are slow or never
        // unchoke, and urgent blocks they hold wait for a race.
        let unproven = peer.downloadedBytes == 0
        let share = peer.snubbed ? 0 : max(8, Int(rate * Torrent.urgentShareSeconds / blk), peer.windowGrowing && !unproven ? peer.window : 0)
        var tookNow = 0
        var blockedByShare = false
        // Urgent blocks already queued at this peer for a lower priority (before a seek moved the window).
        var upgraded = Set<BlockRequest>()
        var i = 0
        // Requests are answered in order: cancels what this peer would send before an urgent block (keeping what is
        // likely on the wire already).
        func trimQueue(keep: Int, protect: (BlockRequest, PendingRequest) -> Bool = { r, v in v.priority == Span.now }) {
            let others = peer.pending.filter { !protect($0.key, $0.value) && !upgraded.contains($0.key) }
            guard others.count > keep else { return }
            for (r, v) in others.sorted(by: { Torrent.queuedBefore($0.value, $1.value) })[keep...] {
                if v.priority == Span.now { nowPending -= 1 }
                cancelRequestLocked(peer, r, now: now)
                anyCancelled = true
                actions.cancels.append(r)
            }
            cursorsStale = true
        }
        // How far past a reader a queued block is now (the distance recorded when it was asked for, or less once the
        // reader moved on towards it).
        var readerStarts: [Int64]?
        func currentDistance(_ r: BlockRequest, _ v: PendingRequest) -> Int64 {
            if readerStarts == nil {
                readerStarts = readers.values.compactMap { $0.fileIndex < info.files.count ? info.files[$0.fileIndex].offset + $0.offset : nil }
            }
            let off = Int64(r.piece) * Int64(info.pieceLength) + Int64(r.offset)
            var best = v.distance
            for s in readerStarts! where off >= s && off - s < best { best = off - s }
            return best
        }
        // How many queued blocks to leave alone when cancelling those queued before an urgent one: what is likely on
        // the wire already. A peer with the fast extension answers each cancel with the block or a reject, and the
        // block stays assigned to it until then (`cancelRequestLocked`), so cancelling one it already sent costs
        // nothing: all but a couple are cancelled, and the urgent block isn't left behind the rest of its queue.
        func onWire(_ seconds: Double) -> Int { peer.supportsFast ? 2 : max(2, Int(rate * seconds / blk)) }
        // Requests are answered in order: before a block the player needs within `limit` bytes, cancels the queued
        // blocks needed later than that (keeping what is likely on the wire already), so they go to other peers.
        func nearCount(within limit: Int64) -> (near: Int, keep: Int) {
            var near = 0, others = 0
            for (r, v) in peer.pending {
                if upgraded.contains(r) || (v.priority <= Span.soon && currentDistance(r, v) <= limit) { near += 1 } else { others += 1 }
            }
            return (near, min(others, onWire(0.15)))
        }
        func trimFar(within limit: Int64) {
            trimQueue(keep: onWire(0.15)) { r, v in v.priority <= Span.soon && currentDistance(r, v) <= limit }
        }
        // The block each reader is blocked on right now. Once nobody asked for it can deliver it promptly, it goes to
        // one more peer every `headRaceStep` — fastest first (rescheduling goes fastest first), even a slow one when
        // it would deliver sooner — with that peer's less urgent queue cancelled so the block comes next: a seeder's
        // disk can take seconds for one block while it keeps serving others from its cache.
        if !peer.snubbed {
            for (piece, b, headDistance) in readerHeadsLocked(info) {
                guard canRequest(piece), let pp = progressLocked(piece, info), b < pp.blockCount, !pp.received[b],
                      !ownedByOther(pp) else { continue }
                let reqs = pp.requesters[b]
                let nearLimit = headDistance + Torrent.headNearBytes
                if reqs.contains(me) {
                    // Asked already, maybe behind blocks that were near another reader then (the connection a
                    // seek replaced): those that are far now are cancelled.
                    let hr = BlockRequest(piece: piece, offset: b * blockSize, length: pp.blockLength(b))
                    guard let hv = peer.pending[hr] else { continue }
                    var farBefore = 0
                    for (r, v) in peer.pending where v.seq < hv.seq && !upgraded.contains(r)
                        && !(v.priority <= Span.soon && currentDistance(r, v) <= nearLimit) { farBefore += 1 }
                    if farBefore > onWire(0.15) { trimFar(within: nearLimit) }
                    continue
                }
                guard !awaitingCancel(pp, b) else { continue }
                // Only blocks the reader needs about as soon as this one stay ahead of it in the peer's queue: urgent
                // blocks further on are released for other peers (the deadline of a block is its distance from the
                // reader, not its priority).
                let (nearQueued, keep) = nearCount(within: nearLimit)
                let mine = eta(queued: nearQueued + keep)
                if reqs.isEmpty {
                    if slowPeer && maxRate > 0 && mine - now > Torrent.deadlineSlack { continue }
                } else {
                    let expected = expectedArrivalLocked(pp, b, now: now)
                    guard now - pp.requestedAt[b] > Torrent.headRaceStep, reqs.count < Torrent.maxHeadRacers,
                          expected > now + Torrent.deadlineSlack, mine < expected - 0.1 else { continue }
                }
                if nearQueued + keep < peer.pending.count { trimFar(within: nearLimit) }
                assign(pp, b, priority: Span.now, eta: mine, distance: headDistance)
                tookNow += 1
            }
        }
        // Blocks raced right now (see `maxHedgedBlocks`).
        var hedged = 0
        for pp in inProgress.values { hedged += pp.extraRequests }
        outer: while i < spans.count && spans[i].priority == Span.now {
            let s = spans[i]
            i += 1
            guard canRequest(s.piece), let pp = progressLocked(s.piece, info), !ownedByOther(pp) else { continue }
            for b in s.start..<s.end where !pp.received[b] {
                let reqs = pp.requesters[b]
                if reqs.contains(me) {
                    let r = BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))
                    if let p = peer.pending[r], p.priority != Span.now {
                        upgraded.insert(r)
                        peer.pending[r]?.priority = Span.now
                        nowPending += 1
                    }
                    continue
                }
                if awaitingCancel(pp, b) { continue }
                let free = reqs.isEmpty
                var race = false
                if !free && reqs.count < Torrent.maxHeadRacers {
                    if b < s.start + s.raceHead {
                        race = reqs.count < Torrent.maxRacers
                    } else if now - pp.requestedAt[b] > Torrent.headRaceStep && !slowPeer && hedged < Torrent.maxHedgedBlocks {
                        // Raced as soon as no requester is expected to deliver it before the reader gets there
                        // (at the swarm's rate): waiting until it is overdue is what keeps the player waiting.
                        let dist = Double(s.distance + Int64(b - s.start) * Int64(blockSize))
                        let deadline = now + (swarmRate > 0 ? dist / swarmRate : 0) + Torrent.deadlineSlack
                        let expected = expectedArrivalLocked(pp, b, now: now)
                        race = expected > deadline && eta(queued: nowPending + tookNow) < expected - 0.1
                    }
                }
                guard free || race else { continue }
                if tooSlow(s, b, queued: nowPending + tookNow) { continue }
                let dist = s.distance + Int64(b - s.start) * Int64(blockSize)
                if b < s.start + s.raceHead {
                    // The first blocks a reader waits on (after a seek, most often): what this peer has queued for
                    // later must not come first.
                    let (nearQueued, keep) = nearCount(within: dist + Torrent.headNearBytes)
                    if nearQueued + keep < peer.pending.count { trimFar(within: dist + Torrent.headNearBytes) }
                    assign(pp, b, priority: Span.now, eta: eta(queued: nearQueued + keep), distance: dist)
                    tookNow += 1
                    continue
                }
                if nowPending + tookNow >= share {
                    // Past its share a peer still takes blocks the requester would deliver too late.
                    if free { blockedByShare = true; continue }
                    if nowPending + tookNow >= 2 * share { break outer }
                }
                assign(pp, b, priority: Span.now, eta: eta(queued: nowPending + tookNow), distance: dist)
                tookNow += 1
                if !free { hedged += 1 }
            }
        }
        while i < spans.count && spans[i].priority == Span.now { i += 1 }
        if tookNow > 0 {
            // Requests are answered in order: cancel what this peer can't deliver before the urgent blocks
            // (keeping what is likely already on the wire).
            trimQueue(keep: max(2, Int(rate * 0.3 / blk)))
        }
        // While urgent blocks wait for a free share, don't bury this peer's queue under less urgent ones.
        if blockedByShare { return actions }

        // Phase 2: keep the pipeline full.
        // All peers share one link: what is requested beyond the bytes in transit (the swarm's rate times the round
        // trip) only queues up — in the peers' send buffers and the link's — in front of the blocks the player will
        // wait on next, after a seek most of all (a popular swarm has a hundred peers). While the player waits,
        // read-ahead and background downloads shrink to a fraction of that and give way.
        var inFlight = 0
        for p in peersByID.values { inFlight += p.pending.count }
        let swarmRTT = swarmRate > 0 ? rateRTT / swarmRate : 0.3
        let budget = max(Torrent.minInFlightBlocks, Int(swarmRate * (swarmRTT + Torrent.inFlightSeconds) / blk))
        let urgent = urgentMissingLocked()
        var soonRoom = (urgent ? budget / 2 : budget) - inFlight
        var laterRoom = (urgent ? budget / 4 : budget) - inFlight
        if urgent && laterRoom < 0 {
            // Requests are answered in order: drop this peer's queued read-ahead beyond what is on the wire.
            let keep = max(2, Int(rate * 0.3 / blk))
            let later = peer.pending.filter { $0.value.priority > Span.soon }.sorted { Torrent.queuedBefore($0.value, $1.value) }
            if later.count > keep {
                for (r, _) in later[keep...] {
                    cancelRequestLocked(peer, r, now: now)
                    anyCancelled = true
                    actions.cancels.append(r)
                }
                cursorsStale = true
            }
        }
        // Requests are answered in order, so a deep queue delays the next urgent block; a shallow one leaves the
        // peer idle between round trips. A little past the time it takes to answer keeps TCP busy.
        var target = max(peer.window, Int(rate * ((peer.answerTime ?? peer.rtt) + Torrent.queueSeconds) / blk) + 8)
        target = min(target, peer.maxRequests)
        if peer.snubbed { target = min(target, 2) }
        var room = target - peer.pending.count
        guard room > 0, room * 4 >= target || peer.pending.count < 4, soonRoom > 0 else { return actions }
        while i < spans.count && room > 0 {
            let k = i
            i += 1
            let s = spans[k]
            if s.priority == Span.soon {
                guard soonRoom > 0 else { break }
                // Scanned whole, so stragglers get raced.
                guard canRequest(s.piece), let pp = progressLocked(s.piece, info), !ownedByOther(pp) else { continue }
                for b in s.start..<s.end where room > 0 && soonRoom > 0 && !pp.received[b] {
                    let reqs = pp.requesters[b]
                    guard reqs.isEmpty || (reqs.count < 2 && !reqs.contains(me) && now > pp.eta[b] + 1.5 && hedged < Torrent.maxHedgedBlocks) else { continue }
                    if awaitingCancel(pp, b) || tooSlow(s, b, queued: peer.pending.count) { continue }
                    if !reqs.isEmpty { hedged += 1 }
                    assign(pp, b, priority: Span.soon, eta: eta(queued: peer.pending.count),
                           distance: s.distance + Int64(b - s.start) * Int64(blockSize))
                    room -= 1
                    soonRoom -= 1
                    laterRoom -= 1
                }
                continue
            }
            guard laterRoom > 0 else { break }
            guard s.cursor < s.end, canRequest(s.piece), let pp = progressLocked(s.piece, info), !ownedByOther(pp) else { continue }
            var b = s.cursor
            var skipped: Int?
            while b < s.end && room > 0 && laterRoom > 0 {
                if !pp.received[b] && pp.requesters[b].isEmpty {
                    if awaitingCancel(pp, b) {
                        if skipped == nil { skipped = b }
                    } else {
                        assign(pp, b, priority: s.priority, eta: eta(queued: peer.pending.count))
                        room -= 1
                        laterRoom -= 1
                    }
                }
                b += 1
            }
            spans[k].cursor = skipped ?? b
        }
        return actions
    }

    /// Most early requests a new connection sends, from the first urgent spans (at most `earlyBlocksPerSpan` each: the
    /// head of the file and its index at the end before the layout is known).
    static let earlyRequestBlocks = 8
    static let earlyBlocksPerSpan = 4

    /// Loop thread, lock not held: requests to send with the handshake to a peer just connected, for the first blocks
    /// the player waits on that fewer than `maxRacers` peers were asked for. Its pieces and choke state are unknown
    /// yet: a peer that unchokes at once (most seeders do) answers them a round trip sooner than requests sent after
    /// its bitfield and unchoke; otherwise they are rejected or released (see `PeerConnection.early`).
    func earlyRequests(for peer: PeerConnection) -> [BlockRequest] {
        lock.lock(); defer { lock.unlock() }
        guard let info = info, !stopped, !paused, !readers.isEmpty || wants.values.contains(where: { $0.urgency == .now }) else { return [] }
        if orderDirty { rebuildOrder(info) }
        let now = Date.timeIntervalSinceReferenceDate
        let me = ObjectIdentifier(peer)
        var out: [BlockRequest] = []
        for s in spans {
            guard s.priority == Span.now, out.count < Torrent.earlyRequestBlocks else { break }
            guard !have[s.piece], let pp = progressLocked(s.piece, info) else { continue }
            var taken = 0
            for b in s.start..<s.end where taken < Torrent.earlyBlocksPerSpan && out.count < Torrent.earlyRequestBlocks {
                guard !pp.received[b], pp.requesters[b].count < Torrent.maxRacers, !pp.requesters[b].contains(me) else { continue }
                let r = BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))
                let eta = now + 2 * peer.rtt + 0.1
                pp.addRequester(b, me)
                pp.requestedAt[b] = now
                pp.eta[b] = eta
                peer.requestSeq += 1
                peer.pending[r] = PendingRequest(at: now, eta: eta, priority: Span.now, deliveredBefore: 0,
                                                 queuedAhead: peer.pending.count, seq: peer.requestSeq,
                                                 distance: s.distance + Int64(b - s.start) * Int64(blockSize))
                peer.early.insert(r)
                out.append(r)
                taken += 1
            }
        }
        if !out.isEmpty { peer.amInterested = true }
        return out
    }

    /// Lock held: whether a block the player (or a `.now` want) waits on is missing.
    func urgentMissingLocked() -> Bool {
        for s in spans {
            guard s.priority == Span.now else { break }
            if have[s.piece] { continue }
            guard let pp = inProgress[s.piece] else { return true }
            for b in s.start..<s.end where !pp.received[b] { return true }
        }
        return false
    }

    /// Lock held: the first missing block (piece, block) at each reader's position, and its distance from it.
    func readerHeadsLocked(_ info: TorrentInfo) -> [(Int, Int, Int64)] {
        var out: [(Int, Int, Int64)] = []
        let pl = Int64(info.pieceLength)
        for r in readers.values where r.fileIndex < info.files.count && r.settledUntil == 0 {
            let f = info.files[r.fileIndex]
            let start = f.offset + r.offset
            let end = f.offset + f.length
            guard start < end else { continue }
            let pos = start + availablePrefixLocked(start, maxLength: criticalBytes)
            guard pos < min(end, start + criticalBytes) else { continue }
            let piece = Int(pos / pl)
            let b = Int((pos - Int64(piece) * pl) / Int64(blockSize))
            out.append((piece, b, Int64(piece) * pl + Int64(b * blockSize) - start))
        }
        return out
    }

    /// Lock held: when the first of the peers asked for a block should deliver it, from how many blocks each had to
    /// send before it and has sent since, at its current rate. A peer that has sent plenty past it (a seeder's slow
    /// disk), is choked or snubbed won't.
    func expectedArrivalLocked(_ pp: PieceProgress, _ b: Int, now: TimeInterval) -> TimeInterval {
        let r = BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))
        var best = TimeInterval.infinity
        for id in pp.requesters[b] {
            guard let p = peersByID[id], !p.snubbed, !p.peerChoking, let pr = p.pending[r] else { continue }
            let since = Int((p.downloadedBytes - pr.deliveredBefore) / Int64(blockSize))
            let rate: Double
            if p.rate > 0 { rate = max(p.rate, 8 * 1024) }
            else if since > 0 { rate = max(8 * 1024, Double(since * blockSize) / max(0.1, now - pr.at - p.rtt)) }
            else if now - pr.at < p.rtt + 0.5 { rate = 128 * 1024 }
            else { continue }
            // Past its turn, the longer the peer keeps sending other blocks the less likely this one comes soon (a
            // seeder reading it from a slow disk sends what it has cached first): a few blocks of reordering are
            // normal, more mean a wait of unknown length, so each skipped block counts several times, and a block
            // overdue for a while is expected to take about as long again.
            let ahead = pr.queuedAhead + 1 - since
            let perBlock = Double(blockSize) / rate
            let t = ahead > 0 ? max(now, pr.at + p.rtt) + Double(ahead) * perBlock
                : now + max(Double(1 - ahead) * 4 * perBlock, 0.5 * (now - pr.at - p.rtt))
            best = min(best, t)
        }
        return best
    }

    /// Lock held: asks a peer for metadata pieces (BEP 9) nobody was asked for recently.
    private func requestMetadataLocked(_ peer: PeerConnection, into actions: inout PeerActions) {
        guard let id = peer.utMetadataID, !metadataPieces.isEmpty else { return }
        let date = Date()
        for (piece, t) in peer.metadataRequestedAt where date.timeIntervalSince(t) > 4 { peer.metadataRequestedAt[piece] = nil }
        for piece in metadataPieces.indices where metadataPieces[piece] == nil && peer.metadataRequestedAt.count < 4 {
            if peer.metadataRequestedAt[piece] != nil { continue }
            if let t = metadataRequestedAt[piece], date.timeIntervalSince(t) < 4 { continue }
            metadataRequestedAt[piece] = date
            peer.metadataRequestedAt[piece] = date
            actions.metadataRequests.append((piece, id))
        }
    }
}
