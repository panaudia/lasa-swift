// Opus at 5 ms in Swift (plan §5.8, S5): libopus through the COpus
// module, the same library and settings the Go probe uses (VoIP, 48 kbps,
// complexity 5; a stereo decoder for the binaural sink). The wrappers are
// thin and allocation-free after construction; the per-frame times the
// S4 pump records are the S5 measurement.

import Foundation
import COpus

public enum OpusError: Error, CustomStringConvertible {
    case create(Int32)
    case encode(Int32)
    case decode(Int32)
    public var description: String {
        switch self {
        case .create(let e): return "opus create: \(String(cString: opus_strerror(e)))"
        case .encode(let e): return "opus encode: \(String(cString: opus_strerror(e)))"
        case .decode(let e): return "opus decode: \(String(cString: opus_strerror(e)))"
        }
    }
}

public final class OpusEncoder {
    private let enc: OpaquePointer
    public let channels: Int

    public init(sampleRate: Int32 = 48_000, channels: Int = 1, bitrate: Int32 = 48_000, complexity: Int32 = 5) throws {
        var err: Int32 = 0
        guard let e = opus_encoder_create(sampleRate, Int32(channels), OPUS_APPLICATION_VOIP, &err), err == OPUS_OK else {
            throw OpusError.create(err)
        }
        enc = e
        self.channels = channels
        _ = copus_set_bitrate(enc, bitrate)
        _ = copus_set_complexity(enc, complexity)
    }

    deinit { opus_encoder_destroy(enc) }

    /// Encodes `frames` frames of interleaved float PCM into `out`,
    /// returning the packet length.
    public func encode(_ pcm: UnsafePointer<Float>, frames: Int, into out: UnsafeMutablePointer<UInt8>, capacity: Int) throws -> Int {
        let n = opus_encode_float(enc, pcm, Int32(frames), out, Int32(capacity))
        if n < 0 { throw OpusError.encode(n) }
        return Int(n)
    }
}

public final class OpusDecoder {
    private let dec: OpaquePointer
    public let channels: Int

    public init(sampleRate: Int32 = 48_000, channels: Int = 2) throws {
        var err: Int32 = 0
        guard let d = opus_decoder_create(sampleRate, Int32(channels), &err), err == OPUS_OK else {
            throw OpusError.create(err)
        }
        dec = d
        self.channels = channels
    }

    deinit { opus_decoder_destroy(dec) }

    /// Decodes one packet into interleaved float PCM, returning the
    /// frames produced. `capacityFrames` bounds the output.
    public func decode(_ packet: UnsafePointer<UInt8>, count: Int, into pcm: UnsafeMutablePointer<Float>, capacityFrames: Int) throws -> Int {
        let n = opus_decode_float(dec, packet, Int32(count), pcm, Int32(capacityFrames), 0)
        if n < 0 { throw OpusError.decode(n) }
        return Int(n)
    }
}
