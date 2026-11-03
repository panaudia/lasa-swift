// The client half of the presence contract (lasa-core.md §7) applied
// once: the index-to-entity mapping keyframes define (C-7-6), the
// generation discard rule for deltas (C-7-8), per-index latest-wins by
// datagram group id (C-7-11), the full tracking reset on generation
// change (C-7-10), unknown indexes ignored (C-7-13), and departure as
// absence from the new generation's keyframes (C-7-12).
//
// Port of lasa/typescript/src/lasa/roster.ts checked against
// lasa/client/roster.go, which is the truth where the two differ.
// 2026-11-03.
//
// Divergences: the update signal is both an AsyncStream (the plan's
// §2.4 surface) and an optional callback (the TypeScript's onUpdate);
// Go has neither. Both fire after a packet that changed the roster,
// outside the lock. The AsyncStream coalesces (one pending signal at
// most) and has one consumer. Chunk indexes wrap at 65535 as Go's
// uint16 arithmetic does.
//
// Thread-safe: apply runs on the receive loop and must not block, so
// the lock covers a handful of dictionary writes and nothing else.

import Foundation

/// One live entity as presence last reported it.
public struct RosterEntry: Sendable, Equatable {
    public var id: String
    /// Head-framed: poses are relative to each listener's head (§3).
    public var headFrame: Bool
    public var pose: Pose
    /// The loudness byte; convert with `Lasa.loudnessToDBFS`.
    public var loudness: UInt8

    public init(id: String, headFrame: Bool, pose: Pose, loudness: UInt8) {
        self.id = id
        self.headFrame = headFrame
        self.pose = pose
        self.loudness = loudness
    }
}

/// The live roster of a space, maintained from the presence track.
/// Feed every presence packet through `apply`; read with `entries`.
public final class PresenceRoster: Sendable {
    private struct Slot {
        var entry: RosterEntry
        /// Group id of the last applied record (latest-wins).
        var lastGroup: UInt64
    }

    private struct State {
        var gen: UInt8 = 0
        /// A keyframe has established a generation.
        var seen = false
        var slots: [UInt16: Slot] = [:]
        var onUpdate: (@Sendable () -> Void)?
    }

    private let state = Locked(State())

    /// Signals after any packet that changed the roster. Coalescing,
    /// single consumer: read `entries` on each signal.
    public let updates: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.updates = stream
        self.continuation = continuation
    }

    deinit { continuation.finish() }

    /// Called after any packet that changed the roster, on the receive
    /// loop, outside the roster's lock; it must not block.
    public func onUpdate(_ handler: (@Sendable () -> Void)?) {
        state.with { $0.onUpdate = handler }
    }

    /// The current roster, in unspecified order.
    public var entries: [RosterEntry] {
        state.with { $0.slots.values.map(\.entry) }
    }

    /// The generation the last keyframe established, if any.
    public var generation: UInt8? {
        state.with { $0.seen ? $0.gen : nil }
    }

    /// Applies one presence packet, with its datagram group id, under
    /// the §7 rules.
    public func apply(group: UInt64, packet: PresencePacket) {
        let (changed, handler) = state.with { s -> (Bool, (@Sendable () -> Void)?) in
            (PresenceRoster.apply(group: group, packet: packet, to: &s), s.onUpdate)
        }
        guard changed else { return }
        continuation.yield()
        handler?()
    }

    private static func apply(group: UInt64, packet: PresencePacket, to s: inout State) -> Bool {
        var changed = false
        switch packet {
        case .keyframe(let k):
            if !s.seen || k.gen != s.gen {
                // New generation: membership changed, so every per-index
                // tracking state resets with it, which is also how a
                // departure lands (absence from the new roster).
                s.seen = true
                s.gen = k.gen
                s.slots.removeAll()
                changed = true
            }
            for (i, rec) in k.records.enumerated() {
                let idx = UInt16(truncatingIfNeeded: Int(k.first) + i)
                if var slot = s.slots[idx] {
                    // The mapping is constant within a generation; only
                    // the sampled pose and loudness are gated by
                    // latest-wins, so a keyframe chunk arriving behind a
                    // newer delta cannot rewind the pose.
                    if group > slot.lastGroup {
                        slot.entry.pose = rec.pose
                        slot.entry.loudness = rec.loudness
                        slot.lastGroup = group
                        s.slots[idx] = slot
                        changed = true
                    }
                } else {
                    s.slots[idx] = Slot(
                        entry: RosterEntry(id: rec.id, headFrame: rec.headFrame, pose: rec.pose, loudness: rec.loudness),
                        lastGroup: group)
                    changed = true
                }
            }
        case .delta(let d):
            // A stale or pre-keyframe generation: discard the packet.
            guard s.seen, d.gen == s.gen else { return false }
            for rec in d.records {
                // An index the last keyframe did not define: its chunk
                // was lost; the next round covers it.
                guard var slot = s.slots[rec.index] else { continue }
                if group > slot.lastGroup {
                    slot.entry.pose = rec.pose
                    slot.entry.loudness = rec.loudness
                    slot.lastGroup = group
                    s.slots[rec.index] = slot
                    changed = true
                }
            }
        }
        return changed
    }
}
