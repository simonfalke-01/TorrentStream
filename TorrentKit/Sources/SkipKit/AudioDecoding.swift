import Foundation

/// Decodes the compressed frames of one audio track to float samples.
public protocol AudioPacketDecoder: AnyObject {
    /// Rate and channel count of what `decode` returns.
    var sampleRate: Double { get }
    var channels: Int { get }
    /// Interleaved samples for one frame; empty if it couldn't be decoded. Frames are fed in order; `reset` comes
    /// before a frame that doesn't follow the previous one.
    func decode(_ packet: Data) -> [Float]
    func reset()
}

/// Makes a decoder for a track, or nil if its codec isn't supported.
public typealias AudioDecoderFactory = @Sendable (AudioTrackInfo) -> AudioPacketDecoder?

/// Uncompressed Matroska audio (`A_PCM/INT/LIT`, `A_PCM/INT/BIG`, `A_PCM/FLOAT/IEEE`).
public final class PCMDecoder: AudioPacketDecoder {
    public let sampleRate: Double
    public let channels: Int
    private let bytes: Int
    private let bigEndian: Bool
    private let float: Bool

    public init?(_ track: AudioTrackInfo) {
        switch track.codecID {
        case "A_PCM/INT/LIT": bigEndian = false; float = false
        case "A_PCM/INT/BIG": bigEndian = true; float = false
        case "A_PCM/FLOAT/IEEE": bigEndian = false; float = true
        default: return nil
        }
        let depth = track.bitDepth > 0 ? track.bitDepth : (float ? 32 : 16)
        guard depth % 8 == 0, (1...4).contains(depth / 8), !float || depth == 32 else { return nil }
        bytes = depth / 8
        sampleRate = track.sampleRate
        channels = track.channels
    }

    public static let factory: AudioDecoderFactory = { PCMDecoder($0) }

    public func decode(_ packet: Data) -> [Float] {
        let n = packet.count / bytes
        var out = [Float](repeating: 0, count: n)
        packet.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<n {
                var v: UInt32 = 0
                for k in 0..<bytes {
                    let byte = UInt32(p[i * bytes + (bigEndian ? k : bytes - 1 - k)])
                    v = v << 8 | byte
                }
                if float {
                    out[i] = Float(bitPattern: v)
                } else {
                    let shift = UInt32(32 - 8 * bytes)
                    // 8-bit PCM is unsigned.
                    let s = bytes == 1 ? Int32(v) - 128 : Int32(bitPattern: v << shift) >> shift
                    out[i] = Float(s) / Float(1 << (8 * bytes - 1))
                }
            }
        }
        return out
    }

    public func reset() {}
}
