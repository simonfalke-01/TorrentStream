import CoreGraphics
import CoreMedia
import Foundation
import MediaKit
import TorrentKit
import UIKit
import VideoToolbox

/// Thumbnails for the seek bar, built from the torrent a keyframe at a time: the container index (Matroska Cues or
/// MP4 sample tables) says where each keyframe is, only that frame's bytes are fetched, VideoToolbox decodes it, and
/// a small copy is kept. Previews fill in coarse to fine in the background; `focus(at:)` fetches the spot under the
/// finger first while scrubbing. Does nothing for files it can't handle (other containers, no index, codecs the
/// device can't decode in hardware).
@MainActor
final class SeekPreviews: ObservableObject {
    /// Bumped whenever a preview arrives, so views showing `image(at:)` refresh.
    @Published private(set) var revision = 0
    /// False once it's known that this file gets no previews.
    @Published private(set) var isSupported = true

    private enum Tag {
        static let index = "preview.index"
        static let background = "preview.background"
        static let focus = "preview.focus"
        static let focusRead = "preview.focus.read"
        static let all = [index, background, focus, focusRead]
    }

    /// Thumbnail width in pixels.
    nonisolated static let width = 240
    nonisolated static let maxBackground = 150
    nonisolated static let maxFocus = 50
    /// Spacing the background pass refines down to.
    nonisolated static let finestSpacing = 9.0
    /// Share of the file the background pass may pull in, judged by the keyframe range estimates.
    nonisolated static let byteBudget = 0.15

    private let torrent: Torrent
    private let fileIndex: Int
    private let fileLength: Int64
    private let fileExtension: String

    private var index: (any KeyframeIndex)?
    private var decoder: PreviewDecoder?
    private var images: [Int: UIImage] = [:]
    /// (time, keyframe) of every image, by time.
    private var times: [(time: Double, key: Int)] = []
    private var focusKeys: [Int] = []
    private var backgroundKeys = Set<Int>()
    private var spacing = Double.infinity
    private var pendingFocus: Double?
    private var focusKey: Int?

    private var loadTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var stopped = false

    init(torrent: Torrent, fileIndex: Int, fileLength: Int64, fileExtension: String) {
        self.torrent = torrent
        self.fileIndex = fileIndex
        self.fileLength = fileLength
        self.fileExtension = fileExtension.lowercased()
    }

    /// Loads the index and starts filling in previews. `duration` is the playback duration in seconds (0 if not
    /// known yet; the container's is used then). Calling it again does nothing.
    func start(duration: Double) {
        guard loadTask == nil, !stopped else { return }
        guard ["mkv", "webm", "mk3d", "mp4", "m4v", "mov"].contains(fileExtension), fileLength > 0 else {
            isSupported = false
            return
        }
        let torrent = self.torrent, fileIndex = self.fileIndex, length = fileLength
        loadTask = Task.detached(priority: .utility) { [weak self] in
            let read = Self.reader(torrent: torrent, fileIndex: fileIndex, urgency: .soon, tag: Tag.index, timeout: 60)
            var loaded: (any KeyframeIndex)?
            for attempt in 0..<6 {
                do {
                    loaded = try await MediaIndex.load(fileLength: length, read: read)
                    break
                } catch MediaIndexError.dataUnavailable {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: UInt64(5 + attempt * 5) * 1_000_000_000)
                } catch {
                    break
                }
            }
            torrent.clearWants(tag: Tag.index)
            let decoder = loaded.flatMap { PreviewDecoder(track: $0.video, width: Self.width) }
            await self?.loaded(loaded, decoder: decoder, duration: duration)
        }
    }

    /// The bytes playing from `seconds` reads first: from the keyframe at or before it, two keyframes on (at least
    /// 4 MB). Nil until the index is loaded.
    func playbackRange(at seconds: Double) -> Range<Int64>? {
        guard let k = index?.keyframes, !k.isEmpty else { return nil }
        var lo = 0, hi = k.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if k[mid].time <= seconds { lo = mid + 1 } else { hi = mid }
        }
        let i = max(0, lo - 1)
        let start = min(k[i].clusterOffset, fileLength)
        let next = i + 2 < k.count ? k[i + 2].clusterOffset : fileLength
        return start..<min(fileLength, max(next, start + 4 << 20))
    }

    /// The preview nearest `seconds`, if one is close enough to stand for that spot.
    func image(at seconds: Double) -> UIImage? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid].time < seconds { lo = mid + 1 } else { hi = mid }
        }
        var best = min(lo, times.count - 1)
        if lo > 0, lo == times.count || seconds - times[lo - 1].time <= times[lo].time - seconds { best = lo - 1 }
        let tolerance = max(15, (spacing.isFinite ? spacing : 0) / 2)
        guard abs(times[best].time - seconds) <= tolerance else { return nil }
        return images[times[best].key]
    }

    /// While scrubbing: fetches the keyframe nearest `seconds` ahead of the background pass. Cheap to call on every
    /// drag update; the latest call wins.
    func focus(at seconds: Double) {
        guard isSupported, !stopped else { return }
        guard let index, let decoder else {
            pendingFocus = seconds
            return
        }
        guard let key = index.nearestKeyframe(to: seconds), images[key] == nil, key != focusKey else { return }
        focusKey = key
        focusTask?.cancel()
        let torrent = self.torrent, fileIndex = self.fileIndex
        focusTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            torrent.clearWants(tag: Tag.focusRead)
            torrent.want(fileIndex: fileIndex, ranges: [index.estimatedRange(ofKeyframe: key)], urgency: .now, tag: Tag.focus)
            let read = Self.reader(torrent: torrent, fileIndex: fileIndex, urgency: .now, tag: Tag.focusRead, timeout: 30)
            let result = await Self.preview(key, index: index, decoder: decoder, read: read)
            if case .image(let time, let image) = result {
                await self?.deliver(key: key, time: time, image: image, focused: true)
            }
            await self?.focusFinished(key)
        }
    }

    /// Scrubbing is over: the spot under the finger stops competing with the seek that follows.
    func endFocus() {
        focusTask?.cancel()
        focusKey = nil
        pendingFocus = nil
        torrent.clearWants(tag: Tag.focus)
        torrent.clearWants(tag: Tag.focusRead)
    }

    /// Cancels all fetching, drops the downloader requests and the images.
    func stop() {
        stopped = true
        loadTask?.cancel()
        backgroundTask?.cancel()
        focusTask?.cancel()
        for tag in Tag.all { torrent.clearWants(tag: tag) }
        images = [:]
        times = []
        index = nil
        decoder = nil
    }

    // MARK: main actor state

    private func loaded(_ index: (any KeyframeIndex)?, decoder: PreviewDecoder?, duration: Double) {
        guard !stopped else { return }
        guard let index, let decoder else {
            isSupported = false
            return
        }
        self.index = index
        self.decoder = decoder
        let total = duration > 0 ? duration : (index.duration ?? index.keyframes.last?.time ?? 0)
        runBackground(index: index, decoder: decoder, duration: total)
        if let t = pendingFocus {
            pendingFocus = nil
            focus(at: t)
        }
    }

    private func deliver(key: Int, time: Double, image: CGImage, focused: Bool) {
        guard !stopped, images[key] == nil else { return }
        images[key] = UIImage(cgImage: image)
        let at = times.firstIndex { $0.time > time } ?? times.count
        times.insert((time, key), at: at)
        if focused && !backgroundKeys.contains(key) {
            focusKeys.append(key)
            if focusKeys.count > Self.maxFocus { remove(focusKeys.removeFirst()) }
        } else {
            backgroundKeys.insert(key)
            focusKeys.removeAll { $0 == key }
        }
        revision &+= 1
    }

    private func remove(_ key: Int) {
        images[key] = nil
        times.removeAll { $0.key == key }
    }

    private func focusFinished(_ key: Int) {
        if focusKey == key {
            focusKey = nil
            torrent.clearWants(tag: Tag.focus)
            torrent.clearWants(tag: Tag.focusRead)
        }
    }

    /// Keys of `keys` the background pass still has to fetch; focused previews among them are kept for good.
    private func missing(_ keys: [Int]) -> [Int] {
        keys.filter { key in
            guard images[key] != nil else { return true }
            backgroundKeys.insert(key)
            focusKeys.removeAll { $0 == key }
            return false
        }
    }

    private func levelDone(spacing: Double) { self.spacing = spacing }

    private func unsupported() {
        isSupported = false
        backgroundTask?.cancel()
        focusTask?.cancel()
        for tag in Tag.all { torrent.clearWants(tag: tag) }
    }

    // MARK: background pass

    private func runBackground(index: any KeyframeIndex, decoder: PreviewDecoder, duration: Double) {
        guard duration > 0 else { return }
        let levels = Self.schedule(index: index, duration: duration, fileLength: fileLength)
        guard let first = levels.first else { return }
        spacing = first.spacing
        let torrent = self.torrent, fileIndex = self.fileIndex
        backgroundTask = Task.detached(priority: .utility) { [weak self] in
            // Let playback get going first.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let misses = MissLog()
            let available = Self.reader(torrent: torrent, fileIndex: fileIndex, urgency: nil, tag: "", timeout: 0, misses: misses)
            var decoded = 0, failed = 0
            var timeouts: [Int: Int] = [:]
            defer { torrent.clearWants(tag: Tag.background) }
            for level in levels {
                guard !Task.isCancelled, var pending = await self?.missing(level.keys) else { return }
                while !pending.isEmpty {
                    if Task.isCancelled || self == nil { return }
                    // Decode whatever is complete. Every other keyframe stops at the first range it lacks (its
                    // cluster head, then the frame itself); all of those are requested together.
                    var progressed = false
                    var still: [(key: Int, need: Range<Int64>)] = []
                    for key in pending {
                        misses.reset()
                        switch await Self.preview(key, index: index, decoder: decoder, read: available) {
                        case .image(let time, let image):
                            decoded += 1
                            progressed = true
                            await self?.deliver(key: key, time: time, image: image, focused: false)
                        case .unavailable:
                            if let need = misses.first { still.append((key, need)) }
                        case .failed:
                            failed += 1
                        }
                    }
                    if decoded == 0 && failed >= 3 {
                        await self?.unsupported()
                        return
                    }
                    pending = still.map { $0.key }
                    guard let next = still.first, !Task.isCancelled else { continue }
                    torrent.want(fileIndex: fileIndex, ranges: still.map { $0.need }, urgency: .background, tag: Tag.background)
                    if !progressed {
                        let got = await torrent.waitForBlocks(fileIndex: fileIndex, offset: next.need.lowerBound,
                                                              length: Int64(next.need.count), timeout: 90)
                        if got == nil {
                            timeouts[next.key, default: 0] += 1
                            if timeouts[next.key, default: 0] >= 2 { pending.removeAll { $0 == next.key } }
                        }
                    }
                }
                await self?.levelDone(spacing: level.spacing)
            }
        }
    }

    /// Keyframes to fetch, level by level: every duration/8, then halving the spacing down to `finestSpacing`,
    /// within `maxBackground` previews and the byte budget. Each level holds only keyframes new to it.
    nonisolated static func schedule(index: any KeyframeIndex, duration: Double, fileLength: Int64) -> [(spacing: Double, keys: [Int])] {
        let count = index.keyframes.count
        guard count > 0, duration > 0 else { return [] }
        let sample = stride(from: 0, to: count, by: max(1, count / 16)).map { Int64(index.estimatedRange(ofKeyframe: $0).count) }
        let averageCost = sample.isEmpty ? 0 : sample.reduce(0, +) / Int64(sample.count)
        let budget = averageCost > 0 ? Int(Double(fileLength) * byteBudget / Double(averageCost)) : maxBackground
        let cap = max(8, min(maxBackground, budget))
        var levels: [(spacing: Double, keys: [Int])] = []
        var seen = Set<Int>()
        var total = 0
        var s = duration / 8
        while true {
            var keys: [Int] = []
            for t in stride(from: 0, to: duration, by: s) {
                if let k = index.nearestKeyframe(to: t), !seen.contains(k) {
                    seen.insert(k)
                    keys.append(k)
                }
            }
            if !levels.isEmpty && total + keys.count > cap { break }
            levels.append((s, keys))
            total += keys.count
            s /= 2
            if s < finestSpacing || total >= count { break }
        }
        return levels
    }

    // MARK: fetching and decoding

    enum Outcome {
        case image(time: Double, image: CGImage)
        case unavailable
        case failed
    }

    nonisolated static func preview(_ key: Int, index: any KeyframeIndex, decoder: PreviewDecoder, read: @escaping ReadBytes) async -> Outcome {
        do {
            let frame = try await index.keyframeData(at: key, read: read)
            guard let image = decoder.decode(frame.data) else { return .failed }
            return .image(time: frame.time, image: image)
        } catch MediaIndexError.dataUnavailable {
            return .unavailable
        } catch {
            return .failed
        }
    }

    /// Reads downloaded bytes; with an `urgency`, missing ranges are requested under `tag` and waited for.
    /// Without an `urgency`, the first missing range is noted in `misses` instead.
    nonisolated static func reader(torrent: Torrent, fileIndex: Int, urgency: Torrent.RangeUrgency?, tag: String,
                                   timeout: TimeInterval, misses: MissLog? = nil) -> ReadBytes {
        return { offset, length in
            // Blocks count once they've arrived; pieces needn't be complete (or verified).
            if let data = await torrent.waitForBlocks(fileIndex: fileIndex, offset: offset, length: length, timeout: 0) {
                return data
            }
            guard let urgency = urgency, !Task.isCancelled else {
                misses?.add(offset..<(offset + length))
                return nil
            }
            torrent.want(fileIndex: fileIndex, ranges: [offset..<(offset + length)], urgency: urgency, tag: tag)
            return await torrent.waitForBlocks(fileIndex: fileIndex, offset: offset, length: length, timeout: timeout)
        }
    }
}

/// The first range a non-waiting read found missing.
final class MissLog: @unchecked Sendable {
    private let lock = NSLock()
    private var range: Range<Int64>?

    func reset() {
        lock.lock(); range = nil; lock.unlock()
    }

    func add(_ missing: Range<Int64>) {
        lock.lock(); if range == nil { range = missing }; lock.unlock()
    }

    var first: Range<Int64>? {
        lock.lock(); defer { lock.unlock() }
        return range
    }
}

/// One VideoToolbox session turning single keyframes into small CGImages. Thread-safe; decodes one frame at a time.
final class PreviewDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let format: CMVideoFormatDescription
    private let outputWidth: Int
    private let outputHeight: Int
    private var session: VTDecompressionSession?

    /// Nil when the device can't decode this track in hardware or the track lacks a decoder configuration.
    init?(track: VideoTrack, width: Int) {
        let codecType: CMVideoCodecType
        switch track.codec {
        case .h264:
            // 10-bit, 4:2:2 and 4:4:4 H.264 (Hi10P is common in older anime releases) isn't hardware decodable.
            guard track.bitDepth == 8, track.chromaFormat == 1 else { return nil }
            codecType = kCMVideoCodecType_H264
        case .hevc:
            guard (track.bitDepth ?? 8) <= 10, (track.chromaFormat ?? 1) == 1 else { return nil }
            codecType = kCMVideoCodecType_HEVC
        case .av1:
            codecType = kCMVideoCodecType_AV1
        default:
            return nil
        }
        guard VTIsHardwareDecodeSupported(codecType), let atom = track.configurationAtom, !track.configuration.isEmpty else { return nil }
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.configuration] as CFDictionary,
        ]
        var fd: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codecType,
                                                    width: Int32(max(1, track.width)), height: Int32(max(1, track.height)),
                                                    extensions: extensions as CFDictionary, formatDescriptionOut: &fd)
        guard status == noErr, let format = fd else { return nil }
        self.format = format
        let w = track.width > 0 ? track.width : 1920, h = track.height > 0 ? track.height : 1080
        outputWidth = min(width, w)
        outputHeight = max(2, Int((Double(outputWidth) * Double(h) / Double(w)).rounded()) & ~1)
    }

    deinit {
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }

    func decode(_ data: Data) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let sample = makeSample(data) else { return nil }
        for _ in 0..<2 {
            guard let session = currentSession() else { return nil }
            let box = OutputBox()
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                box.set(status, image)
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if status == noErr, box.status == noErr, let buffer = box.image {
                return scaled(buffer)
            }
            // Sessions die when the app goes to the background; rebuild once and retry.
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            if status != OSStatus(kVTInvalidSessionErr) && box.status != OSStatus(kVTInvalidSessionErr) { return nil }
        }
        return nil
    }

    private func currentSession() -> VTDecompressionSession? {
        if let s = session { return s }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: outputWidth,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let created = s else { return nil }
        session = created
        return created
    }

    private func makeSample(_ data: Data) -> CMSampleBuffer? {
        let n = data.count
        guard n > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = n
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// A copy of the decoded picture at the output size, independent of the decoder's buffer pool.
    private func scaled(_ buffer: CVImageBuffer) -> CGImage? {
        var full: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full) == noErr, let image = full,
              let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage()
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: OSStatus = -1
    private var _image: CVImageBuffer?

    func set(_ status: OSStatus, _ image: CVImageBuffer?) {
        lock.lock()
        _status = status
        _image = image
        lock.unlock()
    }

    var status: OSStatus { lock.lock(); defer { lock.unlock() }; return _status }
    var image: CVImageBuffer? { lock.lock(); defer { lock.unlock() }; return _image }
}
