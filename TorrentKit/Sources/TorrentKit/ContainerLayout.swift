import Foundation

/// Where a Matroska file keeps what a player reads before its first frame, found from the first kilobytes.
///
/// VLC opens an MKV by reading the head (SeekHead, Info, Tracks), the Cues and Tags the SeekHead points to (usually at
/// the end of the file), then every top-level element up to the first Cluster — including Attachments, which in
/// fansub releases are megabytes of fonts. Knowing the layout lets the engine fetch all of it at once instead of
/// one player request after another, and serve the Attachments as a Void element when they aren't there yet.
struct MatroskaLayout: Equatable {
    /// File offset of the Segment's payload (SeekHead positions are relative to it).
    var segmentStart: Int64 = 0
    /// Top-level elements the SeekHead points to, by ID.
    var seekEntries: [UInt32: Int64] = [:]
    /// The Attachments element, header included.
    var attachments: Range<Int64>?
    /// Where the first Cluster starts (or, when the walk stopped at the end of the attachments, where the element
    /// after them starts: the first cluster or a small element before it).
    var firstCluster: Int64?
    /// Segment duration in seconds, from the Info element.
    var duration: Double?
    /// Bytes before this offset hold no top-level element header the walk hasn't seen: they can be served before the
    /// walk is complete. `Int64.max` once complete.
    var frontier: Int64 = 0
    /// The walk reached a Cluster or the end of the attachments.
    var complete = false

    static let ebmlID: UInt32 = 0x1A45_DFA3
    static let segmentID: UInt32 = 0x1853_8067
    static let seekHeadID: UInt32 = 0x114D_9B74
    static let seekID: UInt32 = 0x4DBB
    static let seekIDID: UInt32 = 0x53AB
    static let seekPositionID: UInt32 = 0x53AC
    static let infoID: UInt32 = 0x1549_A966
    static let timecodeScaleID: UInt32 = 0x2A_D7B1
    static let durationID: UInt32 = 0x4489
    static let cuesID: UInt32 = 0x1C53_BB6B
    static let tagsID: UInt32 = 0x1254_C367
    static let chaptersID: UInt32 = 0x1043_A770
    static let attachmentsID: UInt32 = 0x1941_A469
    static let clusterID: UInt32 = 0x1F43_B675

    var cues: Int64? { seekEntries[MatroskaLayout.cuesID] }

    /// Whether `head` (the first bytes of a file) starts like a Matroska/WebM file.
    static func isMatroska(_ head: Data) -> Bool {
        head.count >= 4 && head.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3])
    }

    /// Walks the top-level elements present in `head` (the first `head.count` bytes of the file). Nil if the file isn't
    /// Matroska or is malformed; an incomplete layout (`frontier` = the first header not in `head`) when more of the
    /// head is needed.
    static func parse(_ head: Data) -> MatroskaLayout? {
        let bytes = [UInt8](head)
        var layout = MatroskaLayout()
        if bytes.count < 4 { return layout }
        guard isMatroska(head) else { return nil }
        let ebml: Header
        switch element(bytes, 0) {
        case .invalid: return nil
        case .incomplete: return layout
        case let .header(h): ebml = h
        }
        guard ebml.id == ebmlID, let ebmlSize = ebml.size else { return nil }
        var pos = ebml.dataStart + ebmlSize
        let seg: Header
        switch element(bytes, pos) {
        case .invalid: return nil
        case .incomplete: layout.frontier = Int64(pos); return layout
        case let .header(h): seg = h
        }
        guard seg.id == segmentID else { return nil }
        layout.segmentStart = Int64(seg.dataStart)
        pos = seg.dataStart
        while true {
            let el: Header
            switch element(bytes, pos) {
            case .invalid: return nil
            case .incomplete: layout.frontier = Int64(pos); return layout
            case let .header(h): el = h
            }
            let start = Int64(pos)
            switch el.id {
            case clusterID:
                layout.firstCluster = start
                layout.frontier = .max
                layout.complete = true
                return layout
            case attachmentsID:
                guard let size = el.size else { return nil }
                let end = Int64(el.dataStart) + Int64(size)
                layout.attachments = start..<end
                layout.firstCluster = end
                layout.frontier = .max
                layout.complete = true
                return layout
            case seekHeadID, infoID:
                guard let size = el.size else { return nil }
                guard el.dataStart + size <= bytes.count else { layout.frontier = start; return layout }
                if el.id == seekHeadID {
                    parseSeekHead(bytes, el.dataStart, el.dataStart + size, into: &layout)
                } else {
                    parseInfo(bytes, el.dataStart, el.dataStart + size, into: &layout)
                }
                pos = el.dataStart + size
            default:
                // Unknown size (a live stream) ends the walk.
                guard let size = el.size else { layout.frontier = .max; layout.complete = true; return layout }
                pos = el.dataStart + size
            }
        }
    }

    /// Calls `body` with each child element entirely inside `from..<to`.
    private static func children(_ b: [UInt8], _ from: Int, _ to: Int, _ body: (Header) -> Void) {
        var pos = from
        while pos < to, case let .header(h) = element(b, pos), let size = h.size, h.dataStart + size <= min(to, b.count) {
            body(h)
            pos = h.dataStart + size
        }
    }

    private static func parseSeekHead(_ b: [UInt8], _ from: Int, _ to: Int, into layout: inout MatroskaLayout) {
        children(b, from, to) { seek in
            guard seek.id == seekID, let size = seek.size else { return }
            var id: UInt32?
            var position: Int64?
            children(b, seek.dataStart, seek.dataStart + size) { child in
                let cs = child.size ?? 0
                if child.id == seekIDID { id = UInt32(truncatingIfNeeded: uint(b, child.dataStart, cs)) }
                if child.id == seekPositionID { position = Int64(truncatingIfNeeded: uint(b, child.dataStart, cs)) }
            }
            if let id, let position, position >= 0 { layout.seekEntries[id] = layout.segmentStart + position }
        }
    }

    private static func parseInfo(_ b: [UInt8], _ from: Int, _ to: Int, into layout: inout MatroskaLayout) {
        var scale: UInt64 = 1_000_000
        var duration: Double?
        children(b, from, to) { child in
            let cs = child.size ?? 0
            if child.id == timecodeScaleID, cs > 0 { scale = uint(b, child.dataStart, cs) }
            if child.id == durationID {
                let raw = uint(b, child.dataStart, cs)
                if cs == 4 { duration = Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) }
                if cs == 8 { duration = Double(bitPattern: raw) }
            }
        }
        if let d = duration, d.isFinite, d > 0 {
            let seconds = d * Double(scale) / 1e9
            if seconds > 1 { layout.duration = seconds }
        }
    }

    private static func uint(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(n, 8) where at + i < b.count { v = v << 8 | UInt64(b[at + i]) }
        return v
    }

    struct Header { let id: UInt32; let size: Int?; let dataStart: Int }
    enum ElementRead { case header(Header), incomplete, invalid }

    /// The element header at `pos`. `size` is nil for unknown sizes.
    static func element(_ b: [UInt8], _ pos: Int) -> ElementRead {
        guard pos < b.count else { return .incomplete }
        let first = b[pos]
        guard first != 0 else { return .invalid }
        let idLen = first.leadingZeroBitCount + 1
        guard idLen <= 4 else { return .invalid }
        guard pos + idLen < b.count else { return .incomplete }
        var id: UInt32 = 0
        for i in 0..<idLen { id = id << 8 | UInt32(b[pos + i]) }
        let sp = pos + idLen
        let s0 = b[sp]
        guard s0 != 0 else { return .invalid }
        let sizeLen = s0.leadingZeroBitCount + 1
        guard sp + sizeLen <= b.count else { return .incomplete }
        var size = UInt64(s0 & (0xFF >> sizeLen))
        var allOnes = size == UInt64(0xFF >> sizeLen)
        for i in 1..<sizeLen {
            size = size << 8 | UInt64(b[sp + i])
            if b[sp + i] != 0xFF { allOnes = false }
        }
        let dataStart = sp + sizeLen
        if allOnes { return .header(Header(id: id, size: nil, dataStart: dataStart)) }
        guard size < UInt64(Int64.max / 2) else { return .invalid }
        return .header(Header(id: id, size: Int(size), dataStart: dataStart))
    }

    /// The header of an EBML Void element spanning `length` bytes (at least 9): an ID byte and an 8-byte size.
    static func voidHeader(length: Int64) -> Data {
        precondition(length >= 9)
        let v = UInt64(length - 9)
        var d = Data([0xEC, 0x01])
        for shift in stride(from: 48, through: 0, by: -8) { d.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
        return d
    }

    /// Bytes from `offset` (`count` of them) of the file with the attachments element replaced by a Void element of
    /// the same length: its header, then zeros.
    func voided(offset: Int64, count: Int) -> Data {
        var d = Data(count: count)
        guard let a = attachments else { return d }
        let header = MatroskaLayout.voidHeader(length: Int64(a.count))
        for (i, byte) in header.enumerated() {
            let p = a.lowerBound + Int64(i)
            if p >= offset && p < offset + Int64(count) { d[Int(p - offset)] = byte }
        }
        return d
    }
}

/// What the engine knows of a Matroska file being streamed (`Torrent.containers`).
struct ContainerState {
    var layout = MatroskaLayout()
    /// How many bytes of the head the last walk read.
    var parsedThrough: Int64 = 0
    /// Served as is: not Matroska, malformed, or no first cluster found in the first `layoutScanBytes`.
    var passthrough = false
    /// Whether the attachments are served as a Void element; decided when the player first reads their header.
    var voidAttachments: Bool?
    /// When a player last read the file (the void decision holds for a playback session).
    var lastServed: TimeInterval = 0
    /// Ranges sent before the layout was known, past its frontier: if one holds the attachments header, the player
    /// saw the real one.
    var servedUnchecked: [Range<Int64>] = []
}

extension Torrent {
    /// How much of a Matroska file's head is walked looking for the first cluster.
    static let layoutScanBytes: Int64 = 4 << 20
    /// Smaller attachments are always served as they are.
    static let minVoidBytes: Int64 = 256 * 1024
    /// A void decision is kept while the file is read at least this often (one playback session).
    static let voidSessionGap: TimeInterval = 30
    /// MKV cues and the tags or chapters stored next to them: the part fetched with the head.
    static let cuesUrgentBytes: Int64 = 256 * 1024
    static let smallElementBytes: Int64 = 64 * 1024

    static func isMatroskaName(_ f: TorrentFile) -> Bool { ["mkv", "mka", "mk3d", "webm"].contains(f.fileExtension) }

    /// Lock held: the first-cluster window: about a second of video, so the player's first buffer is there with it.
    func firstClusterWindowLocked(_ layout: MatroskaLayout, fileLength: Int64) -> Int64 {
        guard let d = layout.duration, d > 0 else { return 2 << 20 }
        return min(4 << 20, max(1 << 20, Int64(Double(fileLength) / d)))
    }

    /// A player this many seconds of video ahead of playback isn't waiting on data.
    static let settledSeconds: TimeInterval = 4
    /// Bitrate peaks over the file's average, assumed in that estimate.
    static let bitrateMargin = 1.5

    /// Lock held: until when the player reading through `r` is estimated to have over `settledSeconds` of video
    /// buffered, or 0 if it may be waiting on data (or the file's bitrate isn't known). Players read ahead greedily,
    /// so a reader at the edge of the downloaded data is no sign of a starving player: what it read since it started
    /// (skipped attachments aside) is compared with what playback consumed since, at the average bitrate with a margin.
    /// A settled reader's window isn't raced between peers, which otherwise downloads much of it twice.
    func settledUntilLocked(_ r: Reader, _ info: TorrentInfo, now: TimeInterval) -> TimeInterval {
        guard r.fileIndex < info.files.count, let layout = containers[r.fileIndex]?.layout, let d = layout.duration, d > 0 else { return 0 }
        let rate = Double(info.files[r.fileIndex].length) / d * Torrent.bitrateMargin
        var read = r.offset - r.start
        if let a = layout.attachments { read -= max(0, min(r.offset, a.upperBound) - max(r.start, a.lowerBound)) }
        let until = r.startedAt + Double(read) / rate - Torrent.settledSeconds
        return until > now ? until : 0
    }

    /// Lock held: the attachments the scheduler leaves out of a reader's window, since they are (or will be) served as
    /// a Void element.
    func skippedAttachmentsLocked(_ fi: Int, _ info: TorrentInfo) -> Range<Int64>? {
        guard let st = containers[fi], !st.passthrough, st.layout.complete, let a = st.layout.attachments,
              Int64(a.count) >= Torrent.minVoidBytes else { return nil }
        if let v = st.voidAttachments { return v ? a : nil }
        guard client?.skipsUndownloadedAttachments ?? false else { return nil }
        let f = info.files[fi]
        return rangeAvailableLocked(f.offset + a.lowerBound, f.offset + a.upperBound) ? nil : a
    }

    /// Lock held: a Matroska file's head hasn't been walked yet.
    func layoutPendingLocked(_ fi: Int, _ info: TorrentInfo) -> Bool {
        guard fi >= 0, fi < info.files.count, Torrent.isMatroskaName(info.files[fi]) else { return false }
        guard let st = containers[fi] else { return true }
        return !st.passthrough && !st.layout.complete
    }

    /// Lock held: what a player reads right after the head of a Matroska file, wherever it is: cues, tags and chapters
    /// (by the SeekHead) and the start of the first cluster.
    func containerRangesLocked(_ fi: Int, _ info: TorrentInfo) -> [Range<Int64>] {
        guard let st = containers[fi], !st.passthrough, st.layout.complete else { return [] }
        let len = info.files[fi].length
        var out: [Range<Int64>] = []
        func add(_ s: Int64, _ n: Int64) { if s >= 0 && s < len { out.append(s..<min(len, s + n)) } }
        if let c = st.layout.cues { add(c, Torrent.cuesUrgentBytes) }
        for id in [MatroskaLayout.tagsID, MatroskaLayout.chaptersID] {
            if let p = st.layout.seekEntries[id], p > (st.layout.firstCluster ?? 0) { add(p, Torrent.smallElementBytes) }
        }
        if let fc = st.layout.firstCluster { add(fc, firstClusterWindowLocked(st.layout, fileLength: len)) }
        return out
    }

    /// Walks as much of a Matroska file's head as has arrived (a no-op once its layout is known, or for other files).
    /// Lock not held: reads from disk.
    func refreshContainerLayout(fileIndex fi: Int) {
        lock.lock()
        guard let info = info, let storage = storage, fi >= 0, fi < info.files.count,
              Torrent.isMatroskaName(info.files[fi]) else { lock.unlock(); return }
        let st = containers[fi] ?? ContainerState()
        if st.passthrough || st.layout.complete { lock.unlock(); return }
        let f = info.files[fi]
        let avail = availablePrefixLocked(f.offset, maxLength: min(f.length, Torrent.layoutScanBytes))
        // Elements before the frontier are skipped, so only the next few hundred kilobytes matter.
        let readLen = min(avail, st.layout.frontier + 256 * 1024)
        guard readLen > st.parsedThrough else { lock.unlock(); return }
        if containers[fi] == nil { containers[fi] = st }
        lock.unlock()

        guard let head = try? storage.read(offset: f.offset, length: Int(readLen)) else { return }
        let parsed = MatroskaLayout.parse(head)

        lock.lock()
        defer { lock.unlock() }
        guard var s = containers[fi], !s.passthrough, !s.layout.complete, readLen > s.parsedThrough else { return }
        s.parsedThrough = readLen
        if let p = parsed {
            s.layout = p
            // Stuck with plenty of data past the frontier, or no cluster within the scan: not worth waiting for.
            if !p.complete && (readLen - p.frontier >= 128 * 1024 || p.frontier >= Torrent.layoutScanBytes || readLen >= f.length) {
                s.passthrough = true
            }
        } else {
            s.passthrough = true
        }
        if s.layout.complete || s.passthrough {
            if let a = s.layout.attachments, s.servedUnchecked.contains(where: { $0.overlaps(a.lowerBound..<(a.lowerBound + 9)) }) {
                s.voidAttachments = false
            }
            s.servedUnchecked = []
            orderDirty = true
            requestRescheduleLocked()
            let l = s.layout
            log(String(format: "mkv layout of file %d after %.2fs: ", fi, Date.timeIntervalSinceReferenceDate - createdAt)
                + (s.passthrough ? "none (served as is)" : "attachments \(l.attachments.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none"), "
                    + "first cluster \(l.firstCluster ?? -1), cues \(l.cues ?? -1), duration \(Int(l.duration ?? 0))s"))
        }
        containers[fi] = s
    }

    enum ServePlan {
        /// Send up to this many bytes of the file as they arrive.
        case real(Int64)
        case synthetic(Data)
        /// The layout walk needs more of the head before anything at this offset can be sent; `have` bytes from the
        /// offset have arrived.
        case needMore(have: Int64)
    }

    /// Lock held: how to serve a player reading `offset` of a file.
    func servePlanLocked(_ fi: Int, _ info: TorrentInfo, offset: Int64, maxLength: Int64) -> ServePlan {
        let f = info.files[fi]
        guard Torrent.isMatroskaName(f) else { return .real(maxLength) }
        var st = containers[fi] ?? ContainerState()
        let now = Date.timeIntervalSinceReferenceDate
        let sessionGap = now - st.lastServed
        st.lastServed = now
        defer { containers[fi] = st }
        if st.passthrough { return .real(maxLength) }
        let l = st.layout
        if !l.complete {
            if offset < l.frontier { return .real(min(maxLength, l.frontier - offset)) }
            if offset < l.frontier + 64 * 1024 {
                return .needMore(have: availablePrefixLocked(f.offset + offset, maxLength: 1 << 20))
            }
            st.servedUnchecked.append(offset..<(offset + maxLength))
            return .real(maxLength)
        }
        guard let a = l.attachments, Int64(a.count) >= Torrent.minVoidBytes else { return .real(maxLength) }
        let attachmentsHere = rangeAvailableLocked(f.offset + a.lowerBound, f.offset + a.upperBound)
        // A new playback session gets the real fonts once they have arrived.
        if st.voidAttachments == true && sessionGap > Torrent.voidSessionGap && attachmentsHere {
            st.voidAttachments = nil
        }
        if offset >= a.upperBound { return .real(maxLength) }
        if offset < a.lowerBound { return .real(min(maxLength, a.lowerBound - offset)) }
        if st.voidAttachments == nil {
            let skip = (client?.skipsUndownloadedAttachments ?? false) && offset < a.lowerBound + 9 && !attachmentsHere
            st.voidAttachments = skip
            orderDirty = true
            requestRescheduleLocked()
            if skip { log("serving the attachments of file \(fi) (\(a.count) bytes, not downloaded) as a Void element") }
        }
        guard st.voidAttachments == true else { return .real(maxLength) }
        return .synthetic(l.voided(offset: offset, count: Int(min(maxLength, a.upperBound - offset))))
    }

    /// The next bytes of a file for a player reading at `offset`: what has arrived there (as soon as any has, at most
    /// `maxLength`), with a Matroska file's attachments replaced by a Void element when they hadn't arrived when the
    /// player got to them (see `TorrentClient.skipsUndownloadedAttachments`). Nil on timeout. Registers the reader.
    func nextChunk(fileIndex fi: Int, offset: Int64, maxLength: Int64, readerID: UUID, timeout: TimeInterval) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            refreshContainerLayout(fileIndex: fi)
            lock.lock()
            guard let info = info, fi >= 0, fi < info.files.count else { lock.unlock(); throw TorrentError.io("no such file") }
            let plan = servePlanLocked(fi, info, offset: offset, maxLength: maxLength)
            if case .synthetic = plan { updateReaderLocked(readerID, fileIndex: fi, offset: offset) }
            lock.unlock()
            let remaining = max(0, deadline.timeIntervalSinceNow)
            switch plan {
            case let .synthetic(d):
                return d
            case let .real(limit):
                let n = try waitForAvailable(fileIndex: fi, offset: offset, maxLength: limit, readerID: readerID, timeout: remaining)
                if n == 0 { return nil }
                return try readData(fileIndex: fi, offset: offset, length: Int(n))
            case let .needMore(have):
                if remaining <= 0 { return nil }
                _ = try waitForData(fileIndex: fi, offset: offset, length: Int(have) + 1, readerID: readerID, timeout: remaining)
            }
        }
    }
}
