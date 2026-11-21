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

        let activeReaders = readers.values.filter { $0.fileIndex < info.files.count }.sorted { $0.updated > $1.updated }
        let sortedWants = wants.values.filter { $0.fileIndex >= 0 && $0.fileIndex < info.files.count }.sorted { $0.seq > $1.seq }
        func wantRanges(_ u: RangeUrgency, _ priority: Int) {
            for w in sortedWants where w.urgency == u {
                for r in w.ranges {
                    fileRange(w.fileIndex, r.lowerBound, r.upperBound, priority, raceHead: priority == Span.now ? Torrent.raceHeadBlocks : 0)
                }
            }
        }

        // What the player is blocked on, the latest seek first.
        for r in activeReaders { fileRange(r.fileIndex, r.offset, r.offset + criticalBytes, Span.now, raceHead: Torrent.raceHeadBlocks) }
        wantRanges(.now, Span.now)
        // Container indexes (MKV cues, MP4 moov at the end) are read when a file is opened or seeked.
        for fi in streamingFiles.sorted() where fi < info.files.count {
            let len = info.files[fi].length
            fileRange(fi, len - Torrent.indexTailBytes, len, Span.soon)
        }
        let mid = min(soonBytes, 3 * criticalBytes)
        for r in activeReaders { fileRange(r.fileIndex, r.offset + criticalBytes, r.offset + mid, Span.soon, lead: criticalBytes) }
        wantRanges(.soon, Span.soon)
        for r in activeReaders { fileRange(r.fileIndex, r.offset + mid, r.offset + soonBytes, Span.soon, lead: mid) }
        // Read-ahead: the near part before seek-preview wants, the rest after them.
        let nearAhead: Int64 = 64 * 1024 * 1024
        for r in activeReaders {
            let ahead = readahead[r.fileIndex] ?? Torrent.defaultReadahead
            fileRange(r.fileIndex, r.offset + soonBytes, r.offset + min(ahead, nearAhead), Span.readahead)
        }
        wantRanges(.background, Span.background)
        for r in activeReaders {
            let ahead = readahead[r.fileIndex] ?? Torrent.defaultReadahead
            if ahead > nearAhead { fileRange(r.fileIndex, r.offset + nearAhead, r.offset + ahead, Span.background) }
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
        // the rest may be cancelled to make room.
        for p in peersByID.values {
            for (r, v) in p.pending where v.priority == Span.now { p.pending[r]?.priority = Span.soon }
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

    /// Lock held: recomputes requests for every connected peer, fastest first so they get the urgent blocks.
    func rescheduleAllLocked() {
        let active = peers.values.filter { $0.isActive }.sorted { $0.rate > $1.rate }
        for p in active { p.apply(nextActionsLocked(for: p)) }
    }

    /// Lock held: what to send a peer now.
    ///
    /// 1. Blocks the player waits on (`Span.now`) are spread over peers in proportion to their speed — a peer holds
    ///    at most what it delivers in half a second — and raced to another peer when overdue. A peer that takes such
    ///    blocks has the tail of its queue cancelled, since it serves requests in order.
    /// 2. Then the queue is topped up to cover its rate × (round trip + 0.75 s), in span order.
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
        // A slow peer only takes urgent blocks it can deliver before the rest of the swarm reaches them: a block
        // first given to a slow peer and then raced is cold on the fast peer's disk, which stalls the player.
        var swarmRate = 0.0, maxRate = 0.0
        for p in peers.values where p.isActive && !p.peerChoking && !p.snubbed {
            swarmRate += p.rate
            maxRate = max(maxRate, p.rate)
        }
        let slowPeer = rate > 0 && rate < 0.25 * maxRate
        func tooSlow(_ s: Span, _ b: Int, queued: Int) -> Bool {
            guard slowPeer, swarmRate > 0 else { return false }
            let dist = Double(s.distance + Int64(b - s.start) * Int64(blockSize))
            return eta(queued: queued) - now > dist / swarmRate + 1.0
        }
        let anyCancelled = !peer.cancelled.isEmpty
        func awaitingCancel(_ pp: PieceProgress, _ b: Int) -> Bool {
            anyCancelled && peer.cancelled[BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))] != nil
        }
        func assign(_ pp: PieceProgress, _ b: Int, priority: Int, eta e: TimeInterval) {
            let r = BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))
            if pp.owner == nil && !failedAttempts.isEmpty && failedAttempts[pp.index] != nil { pp.owner = me }
            pp.requesters[b].append(me)
            pp.requestedAt[b] = now
            pp.eta[b] = e
            peer.pending[r] = PendingRequest(at: now, eta: e, priority: priority, deliveredBefore: peer.downloadedBytes,
                                             queuedAhead: peer.pending.count)
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
        // smaller share would make a fast peer ramp up slowly while the player waits.
        let share = peer.snubbed ? 0 : max(8, Int(rate * Torrent.urgentShareSeconds / blk))
        var tookNow = 0
        var blockedByShare = false
        // Urgent blocks already queued at this peer for a lower priority (before a seek moved the window).
        var upgraded = Set<BlockRequest>()
        var i = 0
        // The block each reader is blocked on right now: raced to every peer with a short queue, one more every
        // quarter second, since a seeder's disk can take seconds for one block while it serves others from cache.
        if Double(peer.pending.count) * blk / assumedRate < 0.5 {
            for (piece, b) in readerHeadsLocked(info) {
                guard canRequest(piece), let pp = progressLocked(piece, info), b < pp.blockCount, !pp.received[b],
                      !ownedByOther(pp) else { continue }
                let reqs = pp.requesters[b]
                guard !reqs.contains(me), reqs.count < Torrent.maxHeadRacers,
                      reqs.isEmpty || now - pp.requestedAt[b] > 0.25, !awaitingCancel(pp, b) else { continue }
                assign(pp, b, priority: Span.now, eta: eta(queued: peer.pending.count))
                tookNow += 1
            }
        }
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
                if !free && reqs.count < Torrent.maxRacers {
                    if b < s.start + s.raceHead {
                        race = true
                    } else if now - pp.requestedAt[b] > Torrent.criticalRaceAfter {
                        race = now > pp.eta[b] + 0.1 || stuckLocked(reqs, pp, b)
                    }
                }
                guard free || race else { continue }
                if tooSlow(s, b, queued: nowPending + tookNow) { continue }
                if nowPending + tookNow >= share {
                    if free { blockedByShare = true }
                    break outer
                }
                assign(pp, b, priority: Span.now, eta: eta(queued: nowPending + tookNow))
                tookNow += 1
            }
        }
        while i < spans.count && spans[i].priority == Span.now { i += 1 }
        if tookNow > 0 {
            // Requests are answered in order: cancel what this peer can't deliver before the urgent blocks
            // (keeping what is likely already on the wire).
            let keep = Int(rate * 0.3 / blk)
            let others = peer.pending.filter { $0.value.priority != Span.now && !upgraded.contains($0.key) }
                .sorted { $0.value.at < $1.value.at }
            if others.count > keep {
                for (r, _) in others[keep...] {
                    peer.pending[r] = nil
                    peer.cancelled[r] = now
                    inProgress[r.piece]?.release(r.offset / blockSize, peer: me)
                    actions.cancels.append(r)
                }
                cursorsStale = true
            }
        }
        // While urgent blocks wait for a free share, don't bury this peer's queue under less urgent ones.
        if blockedByShare { return actions }

        // Phase 2: keep the pipeline full.
        // All peers share one link: what is requested beyond ~1.5 s of the total rate only queues up in front of
        // the blocks the player will wait on next (a popular swarm has a hundred peers). While the player waits,
        // read-ahead and background downloads shrink to a fraction of that and give way.
        var inFlight = 0
        for p in peersByID.values { inFlight += p.pending.count }
        let budget = max(256, Int(swarmRate * Torrent.inFlightSeconds / blk))
        let urgent = urgentMissingLocked()
        var soonRoom = (urgent ? budget / 2 : budget) - inFlight
        var laterRoom = (urgent ? budget / 4 : budget) - inFlight
        if urgent && laterRoom < 0 {
            // Requests are answered in order: drop this peer's queued read-ahead beyond what is on the wire.
            let keep = max(2, Int(rate * 0.3 / blk))
            let later = peer.pending.filter { $0.value.priority > Span.soon }.sorted { $0.value.at < $1.value.at }
            if later.count > keep {
                for (r, _) in later[keep...] {
                    peer.pending[r] = nil
                    peer.cancelled[r] = now
                    inProgress[r.piece]?.release(r.offset / blockSize, peer: me)
                    actions.cancels.append(r)
                }
                cursorsStale = true
            }
        }
        // Requests are answered in order, so a deep queue delays the next urgent block; a shallow one leaves the
        // peer idle between round trips. Half a second past the round trip keeps TCP busy.
        var target = rate <= 0 ? 24 : max(8, Int(rate * (peer.rtt + Torrent.queueSeconds) / blk) + 8)
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
                    guard reqs.isEmpty || (reqs.count < 2 && !reqs.contains(me) && now > pp.eta[b] + 1.5) else { continue }
                    if awaitingCancel(pp, b) || tooSlow(s, b, queued: peer.pending.count) { continue }
                    assign(pp, b, priority: Span.soon, eta: eta(queued: peer.pending.count))
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

    /// Lock held: the first missing block (piece, block) at each reader's position.
    func readerHeadsLocked(_ info: TorrentInfo) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        let pl = Int64(info.pieceLength)
        for r in readers.values where r.fileIndex < info.files.count {
            let f = info.files[r.fileIndex]
            let start = f.offset + r.offset
            let end = f.offset + f.length
            guard start < end else { continue }
            let pos = start + availablePrefixLocked(start, maxLength: criticalBytes)
            guard pos < min(end, start + criticalBytes) else { continue }
            let piece = Int(pos / pl)
            out.append((piece, Int((pos - Int64(piece) * pl) / Int64(blockSize))))
        }
        return out
    }

    /// Lock held: whether every peer asked for a block has since sent plenty of blocks requested after it — typical
    /// of a seeder whose disk is slow to read this one while it serves others from its cache.
    private func stuckLocked(_ requesters: [ObjectIdentifier], _ pp: PieceProgress, _ b: Int) -> Bool {
        let r = BlockRequest(piece: pp.index, offset: b * blockSize, length: pp.blockLength(b))
        for id in requesters {
            guard let p = peersByID[id], let pr = p.pending[r] else { continue }
            if (p.downloadedBytes - pr.deliveredBefore) / Int64(blockSize) <= Int64(pr.queuedAhead + 8) { return false }
        }
        return true
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
