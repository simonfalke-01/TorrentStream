import Foundation
import CatalogKit

/// Fingerprints the audio of one Matroska file as its bytes become available — a torrent downloading in any order.
/// Call `update()` whenever more may have arrived; each call decodes the clusters that have become readable since.
public actor EpisodeListener {
    public enum State: Sendable, Equatable {
        /// Waiting for the file header.
        case waiting
        case listening
        /// Not Matroska, no audio track, or a codec the decoder factory can't handle.
        case unsupported
    }

    public nonisolated let id: String
    public private(set) var state: State = .waiting
    public private(set) var print = AudioPrint()
    public private(set) var layout: MatroskaAudioLayout?

    private let fileSize: Int64
    private let read: ByteReader
    private let makeDecoder: AudioDecoderFactory
    private var decoder: AudioPacketDecoder?
    /// Cluster starts known so far, ascending, and the end of each whose header has been read.
    private var starts: [Int64] = []
    private var ends: [Int64: Int64] = [:]
    private var done = Set<Int64>()
    /// End of the last decoded cluster, to tell whether the next one continues it.
    private var lastEnd: Int64?
    /// Mono samples decoded but not yet fingerprinted, and the time of the first.
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var busy = false

    public init(id: String, fileSize: Int64, read: @escaping ByteReader, decoder: @escaping AudioDecoderFactory) {
        self.id = id
        self.fileSize = fileSize
        self.read = read
        self.makeDecoder = decoder
    }

    /// Length of the file's media in seconds, once its header has been read (0 if it doesn't say).
    public var duration: Double { layout?.duration ?? 0 }

    /// Share of the file's clusters decoded, 0...1.
    public var progress: Double {
        guard let layout, layout.duration > 0 else { return 0 }
        return min(1, print.decodedSeconds / layout.duration)
    }

    public func audio(themes: [SkipSegment] = []) -> EpisodeAudio? {
        guard let layout, layout.duration > 0 else { return nil }
        return EpisodeAudio(id: id, duration: layout.duration, print: print, themes: themes)
    }

    /// Decodes every cluster that has become readable. Returns whether the print changed.
    @discardableResult
    public func update() async -> Bool {
        guard !busy, state != .unsupported else { return false }
        busy = true
        defer { busy = false }
        if layout == nil {
            guard await readHeader() else { return false }
        }
        guard let layout, let decoder else { return false }
        let before = print.decodedSeconds
        var k = 0
        while k < starts.count {
            let offset = starts[k]
            k += 1
            if ends[offset] == nil, let end = await MatroskaAudio.clusterEnd(at: offset, read: read, fileSize: fileSize) {
                ends[offset] = end
                insert(end)
            }
            guard !done.contains(offset),
                  let cluster = await MatroskaAudio.cluster(at: offset, layout: layout, read: read, fileSize: fileSize) else { continue }
            done.insert(offset)
            if let end = cluster.end, ends[offset] == nil {
                ends[offset] = end
                insert(end)
            }
            if lastEnd != offset {
                flush(keepTail: false)
                decoder.reset()
            }
            lastEnd = cluster.end
            for packet in cluster.packets {
                let samples = Fingerprinter.mono(decoder.decode(packet.data), channels: decoder.channels)
                guard !samples.isEmpty else { continue }
                let expected = pendingStart + Double(pending.count) / decoder.sampleRate
                if pending.isEmpty || (packet.isTimed && abs(packet.time - expected) > 0.1) {
                    flush(keepTail: false)
                    pendingStart = packet.time
                }
                pending += samples
            }
            if Double(pending.count) / decoder.sampleRate > 30 { flush(keepTail: true) }
            // Give other work a turn between clusters.
            await Task.yield()
        }
        flush(keepTail: true)
        return print.decodedSeconds != before
    }

    /// Byte ranges of the file holding the audio between the given times, as far as the cue index tells; used to
    /// fetch just the parts of a reference episode where its songs are expected. Empty without an index.
    public func byteRanges(for times: [ClosedRange<Double>]) -> [Range<Int64>] {
        guard let layout, !layout.cues.isEmpty else { return [] }
        let cues = layout.cues.sorted { $0.time < $1.time }
        return times.compactMap { span in
            let first = cues.last { $0.time <= span.lowerBound }?.offset ?? cues[0].offset
            let after = cues.first { $0.time > span.upperBound }?.offset ?? fileSize
            return first < after ? first..<after : nil
        }
    }

    private func readHeader() async -> Bool {
        if let magic = await read(0, 4), magic.count == 4, [UInt8](magic) != [0x1A, 0x45, 0xDF, 0xA3] {
            state = .unsupported
            return false
        }
        guard let found = await MatroskaAudio.layout(read: read, fileSize: fileSize) else { return false }
        guard let made = makeDecoder(found.audio), made.sampleRate > 0, made.channels > 0 else {
            state = .unsupported
            return false
        }
        layout = found
        decoder = made
        state = .listening
        for c in found.cues { insert(c.offset) }
        insert(found.firstCluster)
        return true
    }

    private func insert(_ offset: Int64) {
        guard offset < fileSize else { return }
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < offset { lo = mid + 1 } else { hi = mid }
        }
        if lo == starts.count || starts[lo] != offset { starts.insert(offset, at: lo) }
    }

    /// Fingerprints the pending samples. Keeps the last half second (when `keepTail`) so the frames straddling the
    /// boundary are completed once the samples after it arrive.
    private func flush(keepTail: Bool) {
        guard let decoder, !pending.isEmpty else { return }
        Fingerprinter.add(pending, sampleRate: decoder.sampleRate, startTime: pendingStart, to: &print)
        let keep = keepTail ? min(pending.count, Int(decoder.sampleRate / 2)) : 0
        pendingStart += Double(pending.count - keep) / decoder.sampleRate
        pending = keep > 0 ? Array(pending.suffix(keep)) : []
    }
}
