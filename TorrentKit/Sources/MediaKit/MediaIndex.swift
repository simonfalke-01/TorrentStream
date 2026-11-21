import Foundation

/// Reads `length` bytes of the file at `offset`. Returns nil when the bytes aren't available (not downloaded, or
/// the source gave up waiting). The range never extends past the end of the file.
public typealias ReadBytes = @Sendable (_ offset: Int64, _ length: Int64) async -> Data?

public enum MediaIndexError: Error, Equatable, Sendable {
    /// Neither Matroska/WebM nor MP4/MOV.
    case unsupportedContainer
    /// Bytes needed for this step aren't available; try again later.
    case dataUnavailable
    case noVideoTrack
    /// The file has no keyframe index (Matroska without Cues, fragmented MP4, ...).
    case noKeyframeIndex
    /// Encrypted or compressed (other than header stripping) frames, or laced video blocks.
    case unsupportedEncoding
    case malformed(String)
}

public enum VideoCodec: String, Sendable {
    case h264, hevc, av1, vp9, other
}

public struct VideoTrack: Sendable, Equatable {
    public let codec: VideoCodec
    /// Matroska CodecID ("V_MPEG4/ISO/AVC") or MP4 sample entry type ("avc1").
    public let codecID: String
    /// Decoder configuration record: avcC, hvcC or av1C box payload (Matroska CodecPrivate).
    public let configuration: Data
    public let width: Int
    public let height: Int

    public init(codec: VideoCodec, codecID: String, configuration: Data, width: Int, height: Int) {
        self.codec = codec
        self.codecID = codecID
        self.configuration = configuration
        self.width = width
        self.height = height
    }

    /// Sample description extension atom key for `configuration` ("avcC", "hvcC", "av1C"), as used by
    /// `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`.
    public var configurationAtom: String? {
        switch codec {
        case .h264: return "avcC"
        case .hevc: return "hvcC"
        case .av1: return "av1C"
        case .vp9: return "vpcC"
        case .other: return nil
        }
    }

    /// H.264 profile_idc / HEVC general_profile_idc / AV1 seq_profile from the configuration record.
    public var profile: Int? {
        let c = [UInt8](configuration)
        switch codec {
        case .h264: return c.count > 1 ? Int(c[1]) : nil
        case .hevc: return c.count > 1 ? Int(c[1] & 0x1F) : nil
        case .av1: return c.count > 1 ? Int(c[1] >> 5) : nil
        default: return nil
        }
    }

    /// Luma bit depth when the configuration record states it (H.264 only by profile: High 10 and up are > 8).
    public var bitDepth: Int? {
        let c = [UInt8](configuration)
        switch codec {
        case .h264:
            guard let p = profile else { return nil }
            return [110, 122, 244].contains(p) ? 10 : 8
        case .hevc: return c.count > 17 ? Int(c[17] & 0x07) + 8 : nil
        case .av1:
            guard c.count > 2 else { return nil }
            let high = c[2] & 0x40 != 0, twelve = c[2] & 0x20 != 0
            return high ? (twelve ? 12 : 10) : 8
        default: return nil
        }
    }

    /// Chroma format idc where known: 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4.
    public var chromaFormat: Int? {
        let c = [UInt8](configuration)
        switch codec {
        case .h264:
            guard let p = profile else { return nil }
            return p == 122 ? 2 : p == 244 ? 3 : 1
        case .hevc: return c.count > 16 ? Int(c[16] & 0x03) : nil
        default: return nil
        }
    }
}

/// A random access point of the video track, as listed by the container index.
public struct Keyframe: Sendable, Equatable {
    /// Seconds, from the index (CueTime, or MP4 presentation time).
    public let time: Double
    /// Matroska: offset of the Cluster element holding the frame. MP4: offset of the sample itself.
    public let clusterOffset: Int64
    /// Matroska CueRelativePosition: the block's position relative to the cluster payload start, when the Cues
    /// carry it. MP4: nil.
    public let relativeOffset: Int64?
    /// MP4 sample size; nil for Matroska.
    public let size: Int64?

    public init(time: Double, clusterOffset: Int64, relativeOffset: Int64?, size: Int64? = nil) {
        self.time = time
        self.clusterOffset = clusterOffset
        self.relativeOffset = relativeOffset
        self.size = size
    }
}

/// The video keyframes of a media file and a way to fetch one keyframe's compressed bytes.
public protocol KeyframeIndex: Sendable {
    var video: VideoTrack { get }
    /// Seconds, when the container states it.
    var duration: Double? { get }
    /// Sorted by time.
    var keyframes: [Keyframe] { get }
    /// Byte range of the file that most likely holds keyframe `index` (exact for MP4, an estimate for Matroska),
    /// for registering it with the downloader before reading.
    func estimatedRange(ofKeyframe index: Int) -> Range<Int64>
    /// The compressed frame of keyframe `index` (length-prefixed NAL units for H.264/HEVC, OBUs for AV1, i.e. an MP4
    /// sample), with its exact presentation time. `read` overrides the index's read closure for this call.
    func keyframeData(at index: Int, read: ReadBytes?) async throws -> (time: Double, data: Data)
}

extension KeyframeIndex {
    /// Index of the keyframe closest to `time`.
    public func nearestKeyframe(to time: Double) -> Int? {
        let k = keyframes
        guard !k.isEmpty else { return nil }
        var lo = 0, hi = k.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if k[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        if lo == k.count { return k.count - 1 }
        if lo > 0, time - k[lo - 1].time <= k[lo].time - time { return lo - 1 }
        return lo
    }

    public func keyframeData(at index: Int) async throws -> (time: Double, data: Data) {
        try await keyframeData(at: index, read: nil)
    }

    /// The compressed keyframe closest to `time`.
    public func keyframeData(near time: Double, read: ReadBytes? = nil) async throws -> (time: Double, data: Data) {
        guard let i = nearestKeyframe(to: time) else { throw MediaIndexError.noKeyframeIndex }
        return try await keyframeData(at: i, read: read)
    }
}

public enum MediaIndex {
    /// Loads the keyframe index of a Matroska/WebM or MP4/MOV file, recognized by its first bytes.
    public static func load(fileLength: Int64, read: @escaping ReadBytes) async throws -> any KeyframeIndex {
        let source = ByteReader(fileLength: fileLength, read: read)
        let head = try await source.bytes(at: 0, count: 12)
        if head.count >= 4, head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 {
            return try await MatroskaIndex.load(fileLength: fileLength, read: read)
        }
        if head.count >= 8 {
            let type = String(decoding: head[4..<8], as: UTF8.self)
            if ["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"].contains(type) {
                return try await MP4Index.load(fileLength: fileLength, read: read)
            }
        }
        throw MediaIndexError.unsupportedContainer
    }
}

/// Reads through a `ReadBytes` closure, keeping the last few blocks it fetched so nearby small reads (element
/// headers) don't each go back to the source. Not shared between tasks.
final class ByteReader {
    let fileLength: Int64
    private let read: ReadBytes
    private var buffers: [(offset: Int64, bytes: [UInt8])] = []

    init(fileLength: Int64, read: @escaping ReadBytes) {
        self.fileLength = fileLength
        self.read = read
    }

    /// `count` bytes at `offset` (fewer only at the end of the file). When `window` is larger than `count`, that
    /// much is fetched (up to `limit`) and kept for the reads that follow. Throws `dataUnavailable`.
    func bytes(at offset: Int64, count: Int, window: Int = 0, limit: Int64? = nil) async throws -> [UInt8] {
        guard offset >= 0, offset < fileLength, count > 0 else { return [] }
        let count = Int(min(Int64(count), fileLength - offset))
        for b in buffers.reversed() where offset >= b.offset && offset + Int64(count) <= b.offset + Int64(b.bytes.count) {
            let lo = Int(offset - b.offset)
            return Array(b.bytes[lo..<(lo + count)])
        }
        let end = min(fileLength, limit ?? fileLength)
        let fetch = Int(max(Int64(count), min(Int64(window), end - offset)))
        var got = await read(offset, Int64(fetch))
        if (got?.count ?? 0) < count, fetch > count { got = await read(offset, Int64(count)) }
        guard let data = got, data.count >= count else {
            throw MediaIndexError.dataUnavailable
        }
        let bytes = [UInt8](data)
        buffers.append((offset, bytes))
        if buffers.count > 4 { buffers.removeFirst() }
        return Array(bytes[0..<count])
    }

    /// The element header at `offset`, or nil if the bytes there aren't one.
    func header(at offset: Int64, window: Int = 0, limit: Int64? = nil) async throws -> ElementHeader? {
        let b = try await bytes(at: offset, count: 12, window: window, limit: limit)
        return ElementHeader.parse(b, at: 0, base: offset)
    }

    func payload(_ h: ElementHeader, limit: Int64) async throws -> [UInt8]? {
        guard let size = h.size, size <= limit else { return nil }
        return try await bytes(at: h.dataStart, count: Int(size))
    }
}
