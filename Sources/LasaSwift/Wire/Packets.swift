// The audio-plane packets of lasa-core.md §5.1: the mono-object uplink
// packet (pose, audio, redundancy record) and the sink packet
// (timestamp, audio, redundancy record), plus the presence loudness
// scale of §7.
//
// Port of lasa/typescript/src/lasa/wire.ts (MonoObjectPacket,
// encodeMonoObjectInto, parseMonoObject, parseSink, loudnessToDBFS)
// checked against lasa/wire/audio.go and audio_into.go, which are the
// truth where the two differ. 2026-11-03.
//
// Divergences from the TypeScript, all towards Go: a redundancy bit
// with a zero offset is malformed (C-5.1-9; the TypeScript lets offset
// 0 through), a zero primary length under redundancy is malformed, and
// the sink parser builds on Lasa.splitSink (LasaWire.swift) so the cut
// is the one the sink receive path already makes, adding only what the
// split leaves out: the timestamp's presence, the redundancy record and
// the §5.1 consistency checks.
//
// This encoder supersedes Lasa.encodeMonoObject in OpusPacket.swift,
// which writes audio only.
//
// The sink timestamp is parsed because it is on the wire; it is
// informational (C-5.1-17) and nothing here or downstream may schedule
// playout by it (lasa-swift.md rule 1).

import Foundation

/// A packet that fails to parse. The two cases carry the two outcomes
/// of lasa-core.md §5.1: unknown flag bits mean the bytes are not this
/// format and the receiver discards them silently; malformed means
/// this format, but self-contradictory, and the receiver discards too.
public enum LasaPacketError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownFlags(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unknownFlags(let s): return "unknown flag bits (not this format): \(s)"
        case .malformed(let s): return "malformed: \(s)"
        }
    }
}

/// A full copy of the audio `offset` packets ago (offset 1 to 7). The
/// referenced packet must be audio-bearing (C-5.1-13).
public struct Redundancy: Sendable, Equatable {
    public var offset: Int
    public var audio: [UInt8]

    public init(offset: Int, audio: [UInt8]) {
        self.offset = offset
        self.audio = audio
    }
}

// MARK: - Mono-object (uplink)

/// One mono-object datagram: any of a pose, an audio frame and a
/// redundancy record. A nil section is absent; a pose-only packet is
/// silence, an audio-only packet is pose decimation.
public struct MonoObjectPacket: Sendable, Equatable {
    public var pose: Pose?
    public var audio: [UInt8]?
    public var redundancy: Redundancy?

    public init(pose: Pose? = nil, audio: [UInt8]? = nil, redundancy: Redundancy? = nil) {
        self.pose = pose
        self.audio = audio
        self.redundancy = redundancy
    }

    /// The flags byte this packet encodes with.
    public var flags: UInt8 {
        var f: UInt8 = 0
        if pose != nil { f |= Lasa.flagPose }
        if audio != nil { f |= Lasa.flagAudio }
        if let r = redundancy {
            f |= Lasa.flagRedundancy | UInt8(truncatingIfNeeded: r.offset & 0x7) << 3
        }
        return f
    }

    /// The encoder's checks (Go's AppendMonoObject).
    public func validate() throws {
        if let a = audio, a.isEmpty {
            throw LasaPacketError.malformed("empty audio payload")
        }
        if let r = redundancy {
            guard audio != nil else {
                throw LasaPacketError.malformed("redundancy requires an audio-bearing packet")
            }
            guard (1...7).contains(r.offset) else {
                throw LasaPacketError.malformed("redundancy offset \(r.offset) outside 1-7")
            }
            guard !r.audio.isEmpty else {
                throw LasaPacketError.malformed("empty redundancy payload")
            }
        }
    }

    /// Appends the encoding to `out`.
    public func encode(into out: inout [UInt8]) throws {
        try validate()
        writeUnchecked(into: &out)
    }

    /// Appends the encoding to `w`.
    public func encode(into w: inout ByteWriter) throws {
        try validate()
        var b = [UInt8]()
        b.reserveCapacity(encodedSizeHint)
        writeUnchecked(into: &b)
        w.raw(b)
    }

    /// The encoding.
    public func encoded() throws -> [UInt8] {
        try validate()
        var b = [UInt8]()
        b.reserveCapacity(encodedSizeHint)
        writeUnchecked(into: &b)
        return b
    }

    var encodedSizeHint: Int {
        1 + Pose.size + 2 + (audio?.count ?? 0) + (redundancy?.audio.count ?? 0)
    }

    /// The layout, for a packet `validate` has passed.
    func writeUnchecked(into out: inout [UInt8]) {
        out.append(flags)
        if let p = pose { p.encode(into: &out) }
        if let a = audio {
            if let r = redundancy {
                out.appendLE(UInt16(truncatingIfNeeded: a.count))
                out.append(contentsOf: a)
                out.append(contentsOf: r.audio)
            } else {
                out.append(contentsOf: a)
            }
        }
    }

    /// Decodes a mono-object packet. `.unknownFlags` means the bytes
    /// are not this format; `.malformed` means they contradict it.
    public static func parse(_ data: [UInt8]) throws -> MonoObjectPacket {
        guard !data.isEmpty else { throw LasaPacketError.malformed("empty packet") }
        let flags = data[0]
        if flags & (Lasa.flagTS | Lasa.flagReserved) != 0 {
            throw LasaPacketError.unknownFlags("mono-object")
        }
        if flags & Lasa.flagRedundancy == 0 && flags & Lasa.offsetBits != 0 {
            throw LasaPacketError.unknownFlags("mono-object offset bits")
        }
        var o = 1
        var p = MonoObjectPacket()
        if flags & Lasa.flagPose != 0 {
            p.pose = try Pose.parse(data, at: o)
            o += Pose.size
        }
        let hasAudio = flags & Lasa.flagAudio != 0
        if flags & Lasa.flagRedundancy != 0 && !hasAudio {
            throw LasaPacketError.malformed("redundancy on a packet with no audio")
        }
        (p.audio, p.redundancy) = try parseAudioSection(data, from: o, hasAudio: hasAudio, flags: flags)
        return p
    }
}

/// Go's parseAudioSectionInto: [len u16?][audio][copy?] from `o` to the
/// end. The length prefix is present exactly when the redundancy bit
/// is (C-5.1-12).
func parseAudioSection(_ data: [UInt8], from o: Int, hasAudio: Bool, flags: UInt8) throws -> ([UInt8]?, Redundancy?) {
    if flags & Lasa.flagRedundancy != 0 {
        let offset = Int((flags & Lasa.offsetBits) >> 3)
        guard offset != 0 else {
            throw LasaPacketError.malformed("redundancy offset 0 outside 1-7")
        }
        guard data.count - o >= 2 else {
            throw LasaPacketError.malformed("truncated length prefix")
        }
        let n = Int(data.readU16LE(at: o))
        let start = o + 2
        let rest = data.count - start
        guard n != 0, rest > n else {
            throw LasaPacketError.malformed("bad primary payload length \(n) of \(rest)")
        }
        let audio = Array(data[start..<start + n])
        let copy = Array(data[(start + n)...])
        return (audio, Redundancy(offset: offset, audio: copy))
    }
    guard hasAudio else {
        guard data.count == o else {
            throw LasaPacketError.malformed("\(data.count - o) trailing bytes")
        }
        return (nil, nil)
    }
    guard data.count > o else { throw LasaPacketError.malformed("empty audio payload") }
    return (Array(data[o...]), nil)
}

// MARK: - Sink (downlink: binaural, ambi2, ambi3 share the layout)

/// One sink datagram: a rendered frame with an optional timestamp
/// anchor and an optional redundancy record. Sink tracks are
/// continuous, so the audio is always present.
public struct SinkPacket: Sendable, Equatable {
    /// Unix-epoch microseconds of the frame's first sample, when the
    /// packet carries an anchor. Informational only (C-5.1-17).
    public var timestamp: UInt64?
    public var audio: [UInt8]
    public var redundancy: Redundancy?

    public init(timestamp: UInt64? = nil, audio: [UInt8], redundancy: Redundancy? = nil) {
        self.timestamp = timestamp
        self.audio = audio
        self.redundancy = redundancy
    }

    /// Decodes a sink packet. The header cut is Lasa.splitSink's; this
    /// adds the timestamp's presence, the redundancy record and the
    /// consistency checks the split does not make.
    public static func parse(_ data: [UInt8]) throws -> SinkPacket {
        guard !data.isEmpty else { throw LasaPacketError.malformed("empty packet") }
        let flags = data[0]
        if flags & (Lasa.flagPose | Lasa.flagAudio | Lasa.flagReserved) != 0 {
            throw LasaPacketError.unknownFlags("sink")
        }
        if flags & Lasa.flagRedundancy == 0 && flags & Lasa.offsetBits != 0 {
            throw LasaPacketError.unknownFlags("sink offset bits")
        }
        guard let split = data.withUnsafeBytes({ Lasa.splitSink($0) }) else {
            throw LasaPacketError.malformed(flags & Lasa.flagTS != 0 && data.count < 9
                                            ? "truncated timestamp" : "truncated audio section")
        }
        let ts: UInt64? = flags & Lasa.flagTS != 0 ? split.timestamp : nil
        guard !split.audio.isEmpty else {
            throw LasaPacketError.malformed("sink packets always carry audio")
        }
        let audio = Array(data[split.audio])
        guard flags & Lasa.flagRedundancy != 0 else {
            return SinkPacket(timestamp: ts, audio: audio)
        }
        let offset = Int((flags & Lasa.offsetBits) >> 3)
        guard offset != 0 else {
            throw LasaPacketError.malformed("redundancy offset 0 outside 1-7")
        }
        let copy = Array(data[split.audio.upperBound...])
        guard !copy.isEmpty else {
            throw LasaPacketError.malformed("empty redundancy payload")
        }
        return SinkPacket(timestamp: ts, audio: audio, redundancy: Redundancy(offset: offset, audio: copy))
    }
}

// MARK: - Presence loudness (§7, C-7-5)

extension Lasa {
    /// The silence sentinel: below -127 dBFS.
    public static let loudnessSilent: UInt8 = 255

    /// The dBFS value of a presence loudness byte: 0 is full scale,
    /// each step is -0.5 dB, and `loudnessSilent` is -infinity.
    public static func loudnessToDBFS(_ l: UInt8) -> Double {
        l == loudnessSilent ? -.infinity : Double(l) * -0.5
    }
}
