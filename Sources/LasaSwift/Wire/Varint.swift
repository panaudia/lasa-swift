// QUIC variable-length integers (RFC 9000 §16), the encoding MoQ and
// the LASA wire use throughout. Pure Swift, tested on macOS.

import Foundation

public enum Varint {
    public static let max: UInt64 = (1 << 62) - 1

    /// Appends the encoding of `value` to `out`.
    public static func encode(_ value: UInt64, into out: inout [UInt8]) {
        precondition(value <= max, "varint out of range")
        switch value {
        case 0..<(1 << 6):
            out.append(UInt8(value))
        case (1 << 6)..<(1 << 14):
            out.append(UInt8(0x40 | (value >> 8)))
            out.append(UInt8(value & 0xff))
        case (1 << 14)..<(1 << 30):
            out.append(UInt8(0x80 | (value >> 24)))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(value & 0xff))
        default:
            out.append(UInt8(0xC0 | (value >> 56)))
            for shift in stride(from: 48, through: 0, by: -8) {
                out.append(UInt8((value >> UInt64(shift)) & 0xff))
            }
        }
    }

    /// Decodes one varint at `offset`, advancing it. Nil if truncated.
    public static func decode(_ bytes: UnsafeRawBufferPointer, offset: inout Int) -> UInt64? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        let length = 1 << Int(first >> 6)
        guard offset + length <= bytes.count else { return nil }
        var value = UInt64(first & 0x3f)
        for i in 1..<length {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        offset += length
        return value
    }

    public static func decode(_ bytes: [UInt8], offset: inout Int) -> UInt64? {
        bytes.withUnsafeBytes { decode($0, offset: &offset) }
    }
}
