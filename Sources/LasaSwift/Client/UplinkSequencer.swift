// The per-entity source-track sequencer: the two things every packet
// an entity sends must agree on, in one value (lasa-swift.md rule 4).
//
// 1. One gapless seq counter (lasa-core.md C-5.1-1): the datagram
//    group id increments by exactly one per packet, pose-only packets
//    included. The TypeScript client once kept two counters for one
//    entity and the server saw the second's packets as late replays.
//
// 2. The §5.1 repeat emitter at the entity's declared offset (§4.2):
//    with offset n, every audio-bearing packet also carries a full
//    copy of the audio n packets earlier, so a burst of up to n lost
//    packets is repaired exactly at the server's ingest. Policy is
//    always-on at the offset, the sink writer's mirror image; the
//    declaration is both the request and the bound.
//
// A pose-only packet advances seq without audio. The referenced packet
// MUST be audio-bearing (C-5.1-13), so the ring remembers which seqs
// carried audio and omits the record when seq minus offset was
// pose-only, never substituting another offset: the offset is what
// locates the copy.
//
// Port of lasa/typescript/src/lasa/uplink.ts checked against
// lasa/client/redundancy.go, which is the truth where the two differ.
// 2026-11-03.
//
// Divergences: this is a value type with no timers, queues or held
// packets (rules 2 and 3); `next` is a pure function of the history it
// keeps. It takes the audio and the pose rather than a caller-built
// packet, so there is no caller-supplied redundancy record to pass
// through or replace: the sequencer alone writes the record. The
// declared offset is held as the ceiling and `setRedundancy` clamps to
// it (the TypeScript clamps to the wire maximum and leaves the
// declaration to its caller). The ring records every packet whatever
// the offset in force, so raising the offset live works at once. An
// empty audio array is a pose-only packet. Go's stale-slot case (a seq
// jump) cannot arise: the counter is this value's own.

import Foundation

public struct UplinkSequencer: Sendable {
    /// Ring depth: slot (seq - 7) % 8 is never the slot written at seq.
    public static let history = 8

    private struct Slot: Sendable {
        var seq: UInt64 = 0
        var valid = false
        /// Empty: the packet at seq was pose-only.
        var audio: [UInt8] = []
    }

    /// The declared maximum offset (§4.2), the ceiling for `redundancy`.
    public let declared: Int

    /// The offset in force, 0 for none.
    public private(set) var redundancy: Int

    /// The seq the next packet will get.
    public private(set) var nextSeq: UInt64 = 0

    private var hist: [Slot]

    /// A sequencer at the declared offset (0 for none; above 7, the
    /// wire maximum, clamps to 7).
    public init(declared: Int) {
        let d = max(0, min(7, declared))
        self.declared = d
        self.redundancy = d
        self.hist = Array(repeating: Slot(), count: UplinkSequencer.history)
    }

    /// Changes the offset in force, clamped to 0...declared.
    public mutating func setRedundancy(_ offset: Int) {
        redundancy = max(0, min(declared, offset))
    }

    /// One stamped packet: its seq (the datagram group id), the packet
    /// and its encoding.
    public struct Stamped: Sendable, Equatable {
        public let seq: UInt64
        public let packet: MonoObjectPacket
        public let bytes: [UInt8]
    }

    /// Stamps the next packet: takes the next seq, records the audio
    /// (a copy, by value) and, when this packet and the one `redundancy`
    /// packets ago are both audio-bearing, attaches a repeat of that
    /// one's audio at the offset.
    public mutating func next(audio: [UInt8]?, pose: Pose?) -> Stamped {
        let seq = nextSeq
        nextSeq += 1
        let audio = audio.flatMap { $0.isEmpty ? nil : $0 }

        hist[Int(seq % UInt64(UplinkSequencer.history))] = Slot(seq: seq, valid: true, audio: audio ?? [])

        var red: Redundancy?
        if redundancy > 0, let a = audio, !a.isEmpty, seq >= UInt64(redundancy) {
            let refSeq = seq - UInt64(redundancy)
            let ref = hist[Int(refSeq % UInt64(UplinkSequencer.history))]
            if ref.valid, ref.seq == refSeq, !ref.audio.isEmpty {
                red = Redundancy(offset: redundancy, audio: ref.audio)
            }
        }

        let packet = MonoObjectPacket(pose: pose, audio: audio, redundancy: red)
        var bytes = [UInt8]()
        bytes.reserveCapacity(packet.encodedSizeHint)
        packet.writeUnchecked(into: &bytes)
        return Stamped(seq: seq, packet: packet, bytes: bytes)
    }
}
