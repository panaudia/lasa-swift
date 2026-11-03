// Payloads for the Part B send tests (plan §5.6, S3 (b) to (e)).
//
// The product's uplink is a mono-object packet per 5 ms carrying one
// Opus frame. The send tests have no encoder yet (S5), so they carry a
// genuine 5 ms Opus frame of digital silence, encoded once by
// go/cmd/opus-silence with probe5's settings, and stretch it to the
// size under test with Opus's own padding (RFC 6716 §3.2.5), which the
// server's decoder discards. So the server renders silence, not noise,
// whatever size is sent. The load and size tests send a packet the
// server drops before any decoding instead: the reserved flag bit set,
// which lasa-core.md §5.1 says to discard silently. The server-side
// arrival record stamps both kinds before the handler sees them.

import Foundation

extension Lasa {
    /// One 5 ms mono frame of digital silence, VoIP mode, 48 kbps,
    /// complexity 5 (probe5's encoder): go/cmd/opus-silence.
    // 3 bytes, TOC 0xe8 (config 29, mono, code 0)
    public static let opusSilenceFrame: [UInt8] = [0xe8, 0xff, 0xfe]

    /// `frame` (a code 0, single-frame Opus packet) rewritten as a code 3
    /// packet with padding so the whole packet is `size` bytes. Sizes
    /// under the minimum (frame + 2) return the frame unchanged.
    public static func opusPadded(_ frame: [UInt8], toSize size: Int) -> [UInt8] {
        precondition(!frame.isEmpty && frame[0] & 0x03 == 0, "a code 0 frame")
        let data = frame.dropFirst()
        // [TOC code 3][v=0 p=1 M=1][length bytes][data][zero padding]
        // Each 255 length byte stands for 254 padding bytes and one more
        // length byte follows; the final byte f stands for f bytes.
        let fixed = 2 + data.count + 1 // headers, data, the final length byte
        guard size >= fixed else { return frame }
        let rem = size - fixed
        let k = rem / 255
        let f = rem - 255 * k
        var out = [UInt8]()
        out.reserveCapacity(size)
        out.append(frame[0] | 0x03)
        out.append(0x40 | 0x01)
        for _ in 0..<k { out.append(255) }
        out.append(UInt8(f))
        out.append(contentsOf: data)
        out.append(contentsOf: repeatElement(0, count: 254 * k + f))
        assert(out.count == size)
        return out
    }

    /// A mono-object packet carrying `audio` and nothing else.
    public static func encodeMonoObject(audio: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(audio.count + 1)
        out.append(flagAudio)
        out.append(contentsOf: audio)
        return out
    }

    /// A mono-object packet of `size` bytes carrying silence: the
    /// padded Opus frame behind the audio flag.
    public static func silencePacket(size: Int) -> [UInt8] {
        encodeMonoObject(audio: opusPadded(opusSilenceFrame, toSize: max(size - 1, 0)))
    }

    /// A `size`-byte packet the server discards on sight (reserved
    /// flag bit set, §5.1), for load and size tests. The body is a
    /// fixed pattern so a truncated arrival would be visible.
    public static func discardPacket(size: Int) -> [UInt8] {
        precondition(size >= 1)
        var out = [UInt8](repeating: 0, count: size)
        out[0] = flagReserved
        for i in 1..<size { out[i] = UInt8(truncatingIfNeeded: i) }
        return out
    }
}
