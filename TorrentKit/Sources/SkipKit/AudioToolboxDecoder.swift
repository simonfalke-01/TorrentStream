#if canImport(AudioToolbox)
import AudioToolbox
import Foundation

/// Decodes AAC, AC-3, E-AC-3, MP3 and (mono or stereo) Opus tracks with the system's audio converter (Apple
/// platforms only).
public final class AudioToolboxDecoder: AudioPacketDecoder {
    public let sampleRate: Double
    public let channels: Int
    private var converter: AudioConverterRef?
    private let input: AudioStreamBasicDescription
    private var buffer: [Float]

    /// PCM tracks are decoded directly; the rest by the audio converter, when it handles their codec.
    public static let factory: AudioDecoderFactory = { track in
        PCMDecoder(track) ?? AudioToolboxDecoder(track)
    }

    public init?(_ track: AudioTrackInfo) {
        var input = AudioStreamBasicDescription()
        input.mSampleRate = track.sampleRate
        input.mChannelsPerFrame = UInt32(track.channels)
        var cookie: Data?
        switch track.codecID {
        case let id where id == "A_AAC" || id.hasPrefix("A_AAC/"):
            input.mFormatID = kAudioFormatMPEG4AAC
            input.mFramesPerPacket = 1024
            guard let config = track.codecPrivate.isEmpty ? Self.audioSpecificConfig(track) : track.codecPrivate else { return nil }
            cookie = Self.esds(config)
        case "A_AC3":
            input.mFormatID = kAudioFormatAC3
            input.mFramesPerPacket = 1536
        case "A_EAC3":
            input.mFormatID = kAudioFormatEnhancedAC3
            input.mFramesPerPacket = 1536
        case "A_MPEG/L3":
            input.mFormatID = kAudioFormatMPEGLayer3
            input.mFramesPerPacket = 1152
        case "A_OPUS":
            // Opus always decodes at 48 kHz; mono and stereo streams need no setup beyond that.
            guard track.channels <= 2 else { return nil }
            input.mFormatID = kAudioFormatOpus
            input.mSampleRate = 48000
            input.mFramesPerPacket = 960
        default:
            return nil
        }
        if let cookie {
            // Let the system read rate, channels and profile (HE-AAC doubles the rate) from the configuration.
            var described = input
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = cookie.withUnsafeBytes { p in
                AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(p.count), p.baseAddress, &size, &described)
            }
            if status == noErr && described.mSampleRate > 0 && described.mChannelsPerFrame > 0 { input = described }
        }
        let outChannels = max(1, Int(input.mChannelsPerFrame))
        var output = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * outChannels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * outChannels),
            mChannelsPerFrame: UInt32(outChannels), mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &made) == noErr, let made else { return nil }
        if let cookie {
            let status = cookie.withUnsafeBytes { p in
                AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie, UInt32(p.count), p.baseAddress!)
            }
            guard status == noErr else {
                AudioConverterDispose(made)
                return nil
            }
        }
        converter = made
        self.input = input
        sampleRate = input.mSampleRate
        channels = outChannels
        buffer = [Float](repeating: 0, count: 4096 * outChannels)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    public func reset() {
        if let converter { AudioConverterReset(converter) }
    }

    public func decode(_ packet: Data) -> [Float] {
        guard let converter, !packet.isEmpty else { return [] }
        let source = PacketSource(packet, channels: input.mChannelsPerFrame)
        let user = Unmanaged.passUnretained(source).toOpaque()
        var out: [Float] = []
        let capacity = UInt32(buffer.count / channels)
        while true {
            var frames = capacity
            let status: OSStatus = buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, AudioToolboxDecoder.supplyPacket, user, &frames, &list, nil)
            }
            if frames > 0 { out += buffer[0..<(Int(frames) * channels)] }
            if status != noErr || frames == 0 || source.consumed { break }
        }
        withExtendedLifetime(source) {}
        return out
    }

    /// Hands the converter one packet, then reports there is no more for now.
    private static let noMoreData: OSStatus = 0x6E_6D_64_74   // 'nmdt'

    private static let supplyPacket: AudioConverterComplexInputDataProc = { _, count, data, descriptions, user in
        guard let user else { count.pointee = 0; return AudioToolboxDecoder.noMoreData }
        let source = Unmanaged<PacketSource>.fromOpaque(user).takeUnretainedValue()
        guard !source.consumed else {
            count.pointee = 0
            return AudioToolboxDecoder.noMoreData
        }
        source.consumed = true
        count.pointee = 1
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = source.bytes
        data.pointee.mBuffers.mDataByteSize = UInt32(source.size)
        data.pointee.mBuffers.mNumberChannels = source.channels
        if let descriptions {
            source.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                      mDataByteSize: UInt32(source.size))
            descriptions.pointee = source.description
        }
        return noErr
    }

    /// One packet's bytes at a stable address for the duration of a conversion.
    private final class PacketSource {
        let bytes: UnsafeMutableRawPointer
        let size: Int
        let channels: UInt32
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        var consumed = false

        init(_ data: Data, channels: UInt32) {
            size = data.count
            bytes = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 16)
            data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
            self.channels = channels
        }

        deinit {
            bytes.deallocate()
            description.deallocate()
        }
    }

    /// The MPEG-4 elementary stream descriptor the converter expects as an AAC magic cookie, wrapping the
    /// AudioSpecificConfig (laid out as FFmpeg's AudioToolbox decoder does).
    static func esds(_ config: Data) -> Data {
        var out = Data()
        func descriptor(_ tag: UInt8, _ size: Int) {
            out.append(tag)
            for shift in [21, 14, 7] { out.append(UInt8((size >> shift) & 0x7F) | 0x80) }
            out.append(UInt8(size & 0x7F))
        }
        descriptor(0x03, 3 + 5 + 13 + 5 + config.count)
        out.append(contentsOf: [0, 0, 0])                      // ES_ID, flags
        descriptor(0x04, 13 + 5 + config.count)
        out.append(contentsOf: [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])   // AAC, audio stream, no bitrates
        descriptor(0x05, config.count)
        out.append(config)
        return out
    }

    /// AudioSpecificConfig for old-style AAC codec IDs (`A_AAC/MPEG4/LC`, `.../SBR`), which carry no private data.
    static func audioSpecificConfig(_ track: AudioTrackInfo) -> Data? {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let sbr = track.codecID.hasSuffix("/SBR")
        let coreRate = sbr ? track.sampleRate / 2 : track.sampleRate
        guard let index = rates.firstIndex(where: { abs($0 - coreRate) < 1 }) else { return nil }
        let profile: UInt16 = track.codecID.contains("/MAIN") ? 1 : track.codecID.contains("/SSR") ? 3 : 2
        let bits = profile << 11 | UInt16(index) << 7 | UInt16(min(7, track.channels)) << 3
        return Data([UInt8(bits >> 8), UInt8(bits & 0xFF)])
    }
}
#endif
