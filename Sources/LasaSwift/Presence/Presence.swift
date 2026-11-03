// The presence packets of lasa-core.md §7: the keyframe (one roster
// chunk from index `first`, each record with the head-frame kflag) and
// the delta (changed records by index), both under a generation byte.
//
// Port of lasa/typescript/src/lasa/wire.ts (parsePresence and the
// presence record types) checked against lasa/wire/presence.go, which
// is the truth where the two differ. 2026-11-03.
//
// No divergence in what parses: both reject unknown flag bits on the
// packet and on a krecord (the §5.1 discard rule), a partial trailing
// record, and a krecord id outside the §2 identifier grammar. The
// encoders are Go's, so a test can round-trip the vectors.

import Foundation

/// One entity in a keyframe chunk.
public struct KeyframeRecord: Sendable, Equatable {
    /// The pose, and every later delta pose at this index, is relative
    /// to each listener's head rather than the space (C-7-4).
    public var headFrame: Bool
    public var id: String
    public var pose: Pose
    /// The loudness byte; convert with `Lasa.loudnessToDBFS`.
    public var loudness: UInt8

    public init(headFrame: Bool = false, id: String, pose: Pose, loudness: UInt8) {
        self.headFrame = headFrame
        self.id = id
        self.pose = pose
        self.loudness = loudness
    }
}

/// One changed entity in a delta, by keyframe index.
public struct DeltaRecord: Sendable, Equatable {
    public var index: UInt16
    public var pose: Pose
    public var loudness: UInt8

    public init(index: UInt16, pose: Pose, loudness: UInt8) {
        self.index = index
        self.pose = pose
        self.loudness = loudness
    }
}

/// One self-contained keyframe chunk: the records from index `first`,
/// each later record one index higher, for generation `gen`.
public struct PresenceKeyframe: Sendable, Equatable {
    public var gen: UInt8
    public var first: UInt16
    public var records: [KeyframeRecord]

    public init(gen: UInt8, first: UInt16, records: [KeyframeRecord]) {
        self.gen = gen
        self.first = first
        self.records = records
    }
}

/// The changed records for generation `gen`.
public struct PresenceDelta: Sendable, Equatable {
    public var gen: UInt8
    public var records: [DeltaRecord]

    public init(gen: UInt8, records: [DeltaRecord]) {
        self.gen = gen
        self.records = records
    }
}

/// One presence datagram.
public enum PresencePacket: Sendable, Equatable {
    case keyframe(PresenceKeyframe)
    case delta(PresenceDelta)

    static let flagKeyframe: UInt8 = 1 << 0
    static let krecordFlagHeadFrame: UInt8 = 1 << 0

    /// The generation byte either kind carries.
    public var gen: UInt8 {
        switch self {
        case .keyframe(let k): return k.gen
        case .delta(let d): return d.gen
        }
    }

    // MARK: Parse

    /// Decodes a presence datagram. Records run to the end of the
    /// datagram. `.unknownFlags` means the bytes are not this format.
    public static func parse(_ data: [UInt8]) throws -> PresencePacket {
        guard data.count >= 2 else { throw LasaPacketError.malformed("presence packet too short") }
        let flags = data[0]
        if flags & ~flagKeyframe != 0 { throw LasaPacketError.unknownFlags("presence") }
        let gen = data[1]
        var o = 2

        if flags & flagKeyframe == 0 {
            let recordSize = 2 + Pose.size + 1
            guard (data.count - o) % recordSize == 0 else {
                throw LasaPacketError.malformed("presence delta length \(data.count - o) not a whole number of records")
            }
            var records: [DeltaRecord] = []
            records.reserveCapacity((data.count - o) / recordSize)
            while o < data.count {
                let index = data.readU16LE(at: o)
                let pose = try Pose.parse(data, at: o + 2)
                let loudness = data[o + 2 + Pose.size]
                records.append(DeltaRecord(index: index, pose: pose, loudness: loudness))
                o += recordSize
            }
            return .delta(PresenceDelta(gen: gen, records: records))
        }

        guard data.count - o >= 2 else { throw LasaPacketError.malformed("truncated keyframe first index") }
        let first = data.readU16LE(at: o)
        o += 2
        var records: [KeyframeRecord] = []
        while o < data.count {
            guard data.count - o >= 2 else { throw LasaPacketError.malformed("truncated krecord header") }
            let kflags = data[o]
            if kflags & ~krecordFlagHeadFrame != 0 { throw LasaPacketError.unknownFlags("krecord") }
            let idLen = Int(data[o + 1])
            o += 2
            guard data.count - o >= idLen + Pose.size + 1 else {
                throw LasaPacketError.malformed("truncated krecord")
            }
            let idBytes = data[o..<o + idLen]
            guard validIdentifier(idBytes) else {
                throw LasaPacketError.malformed("invalid krecord id")
            }
            let id = String(decoding: idBytes, as: UTF8.self)
            o += idLen
            let pose = try Pose.parse(data, at: o)
            o += Pose.size
            let loudness = data[o]
            o += 1
            records.append(KeyframeRecord(headFrame: kflags & krecordFlagHeadFrame != 0,
                                          id: id, pose: pose, loudness: loudness))
        }
        return .keyframe(PresenceKeyframe(gen: gen, first: first, records: records))
    }

    // MARK: Encode

    /// The encoding (Go's AppendPresenceKeyframe and AppendPresenceDelta).
    /// A keyframe record id outside the identifier grammar throws.
    public func encoded() throws -> [UInt8] {
        var out = [UInt8]()
        switch self {
        case .delta(let d):
            out.reserveCapacity(2 + d.records.count * (2 + Pose.size + 1))
            out.append(0)
            out.append(d.gen)
            for r in d.records {
                out.appendLE(r.index)
                r.pose.encode(into: &out)
                out.append(r.loudness)
            }
        case .keyframe(let k):
            out.append(PresencePacket.flagKeyframe)
            out.append(k.gen)
            out.appendLE(k.first)
            for r in k.records {
                let id = Array(r.id.utf8)
                guard validIdentifier(id[...]) else {
                    throw LasaPacketError.malformed("invalid entity id \(r.id)")
                }
                out.append(r.headFrame ? PresencePacket.krecordFlagHeadFrame : 0)
                out.append(UInt8(id.count))
                out.append(contentsOf: id)
                r.pose.encode(into: &out)
                out.append(r.loudness)
            }
        }
        return out
    }
}

/// The identifier grammar of lasa-core.md §2: [a-z0-9-]{1,128}, checked
/// on the bytes as Go's ident.ValidIdentifier does.
private func validIdentifier(_ b: ArraySlice<UInt8>) -> Bool {
    guard !b.isEmpty, b.count <= 128 else { return false }
    for c in b {
        let ok = (0x61...0x7a).contains(c) || (0x30...0x39).contains(c) || c == 0x2d
        if !ok { return false }
    }
    return true
}
