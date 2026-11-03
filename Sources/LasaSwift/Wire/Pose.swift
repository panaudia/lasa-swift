// The 18-byte pose of lasa-core.md §5.1 (C-5.1-10): x, y, z as f32
// little-endian metres (x forward, y left, z up), then yaw, pitch, roll
// as int16 little-endian radians scaled by π/32767.
//
// Port of lasa/typescript/src/lasa/wire.ts (Pose, encodePoseInto,
// parsePose) checked against lasa/wire/pose.go, which is the truth
// where the two differ. 2026-11-03.
//
// The quantiser rounds half away from zero, as Go's math.Round does
// (the TypeScript carries a roundHalfAway for the same reason), in
// Double and in Go's operand order, so the three agree bit for bit.
// Angles outside [-π, π] clamp rather than wrap: normalise first. One
// hardening Go leaves implementation-defined: a NaN angle encodes as 0
// instead of trapping in the Int16 conversion.

import Foundation

public struct Pose: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var yaw: Float
    public var pitch: Float
    public var roll: Float

    public init(x: Float, y: Float, z: Float, yaw: Float, pitch: Float, roll: Float) {
        self.x = x; self.y = y; self.z = z
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }

    /// The origin, facing forward.
    public static let home = Pose(x: 0, y: 0, z: 0, yaw: 0, pitch: 0, roll: 0)

    /// The encoded size in bytes.
    public static let size = 18

    /// The wire resolution of an angle, in radians.
    public static let angleQuantum: Double = .pi / 32767

    // MARK: Encode

    /// Appends the 18-byte encoding to `out`.
    public func encode(into out: inout [UInt8]) {
        out.appendLE(x.bitPattern)
        out.appendLE(y.bitPattern)
        out.appendLE(z.bitPattern)
        out.appendLE(UInt16(bitPattern: Pose.quantize(yaw)))
        out.appendLE(UInt16(bitPattern: Pose.quantize(pitch)))
        out.appendLE(UInt16(bitPattern: Pose.quantize(roll)))
    }

    /// Appends the 18-byte encoding to `w`.
    public func encode(into w: inout ByteWriter) {
        var b = [UInt8]()
        b.reserveCapacity(Pose.size)
        encode(into: &b)
        w.raw(b)
    }

    /// The 18-byte encoding.
    public var encoded: [UInt8] {
        var b = [UInt8]()
        b.reserveCapacity(Pose.size)
        encode(into: &b)
        return b
    }

    // MARK: Parse

    /// Reads the 18-byte pose at `offset`. Throws `.malformed` when the
    /// bytes run out.
    public static func parse(_ data: [UInt8], at offset: Int = 0) throws -> Pose {
        guard offset >= 0, data.count - offset >= size else {
            throw LasaPacketError.malformed("truncated pose")
        }
        return Pose(
            x: Float(bitPattern: data.readU32LE(at: offset)),
            y: Float(bitPattern: data.readU32LE(at: offset + 4)),
            z: Float(bitPattern: data.readU32LE(at: offset + 8)),
            yaw: angle(Int16(bitPattern: data.readU16LE(at: offset + 12))),
            pitch: angle(Int16(bitPattern: data.readU16LE(at: offset + 14))),
            roll: angle(Int16(bitPattern: data.readU16LE(at: offset + 16)))
        )
    }

    // MARK: Quantisation

    /// Go's quantizeAngle: math.Round(float64(a) * 32767 / math.Pi),
    /// clamped to ±32767.
    static func quantize(_ a: Float) -> Int16 {
        let q = (Double(a) * 32767 / Double.pi).rounded(.toNearestOrAwayFromZero)
        if q.isNaN { return 0 }
        if q > 32767 { return 32767 }
        if q < -32767 { return -32767 }
        return Int16(q)
    }

    /// Go's angleFromWire: float32(float64(q) * math.Pi / 32767).
    static func angle(_ q: Int16) -> Float {
        Float(Double(q) * Double.pi / 32767)
    }
}

// MARK: - Little-endian helpers

// The LASA payloads are fixed-width little-endian (lasa-core.md
// C-5.1-4); ByteWriter and ByteReader speak varints and big-endian MoQ
// control fields, so the little-endian appends and reads live here.

extension Array where Element == UInt8 {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }

    mutating func appendLE(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    /// The caller has checked the bounds.
    func readU16LE(at i: Int) -> UInt16 {
        UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    /// The caller has checked the bounds.
    func readU32LE(at i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(self[i + k]) << UInt32(8 * k) }
        return v
    }

    /// The caller has checked the bounds.
    func readU64LE(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(self[i + k]) << UInt64(8 * k) }
        return v
    }
}
