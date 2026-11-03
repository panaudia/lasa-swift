// The sink-track FEC reassembler, a port of the Go reference
// (panaudia-bridge bridge/reassembler.go; the TypeScript client carries
// the same port, lasa/typescript/src/audio/sink-reassembler.ts). Sits
// between MoQ receive and the jitter buffer when the entity declared
// redundancy > 0; without a declaration packets decode straight into
// the buffer, as the bridge does.
//
// Contract: pass-through while the stream is in order; on a gap hold
// successors and repair the gap from a later packet's redundant copy,
// flushing in order; give-up is id-denominated (frame g is dead once a
// packet with id ≥ g + lag + 2 has arrived while g is unresolved), and a
// dead frame is CONCEALED, released with nil audio for the caller to
// write as a zero-content frame at the frame's position (a skipped frame
// would read as drift inside the buffer); a dead run longer than the
// buffer's freeze threshold (8 packets, 40 ms) is skipped instead.
//
// SinkReassemblerReplayTests replays the Go generator's fixtures for
// event and counter equality. One instance per subscription.

import Foundation

public final class SinkReassembler {
    public static let skipThreshold: UInt64 = 8

    public struct Event {
        public var seq: UInt64
        /// nil for a concealment frame.
        public var audio: [UInt8]?
    }

    private struct Held {
        var audio: [UInt8]
        var repaired: Bool
    }

    private let lag: UInt64
    private let skip = SinkReassembler.skipThreshold
    private var started = false
    private var next: UInt64 = 0
    private var high: UInt64 = 0
    private var held: [UInt64: Held] = [:]

    public private(set) var delivered = 0
    public private(set) var repaired = 0
    public private(set) var concealed = 0
    public private(set) var skipped = 0
    public private(set) var stale = 0

    private var out: [Event] = []

    public init(lag: Int) {
        self.lag = UInt64(max(lag, 0))
        out.reserveCapacity(16)
    }

    /// Accepts the packet with MoQ group id `seq`, its primary audio and
    /// its redundant copy (offset 0 and nil when absent) and returns the
    /// frames released in order. The array is reused until the next push;
    /// the in-order fast path hands back the caller's own audio array.
    public func push(seq: UInt64, audio: [UInt8], redOffset: Int, redAudio: [UInt8]?) -> [Event] {
        out.removeAll(keepingCapacity: true)
        if !started {
            started = true
            next = seq
            high = seq
        }
        if seq < next {
            stale += 1
            return out
        }
        if seq > high { high = seq }

        if seq == next && held.isEmpty {
            next += 1
            delivered += 1
            out.append(Event(seq: seq, audio: audio))
            return out
        }

        if held[seq] == nil {
            held[seq] = Held(audio: audio, repaired: false)
        }
        if let redAudio, redOffset > 0, seq >= UInt64(redOffset) {
            let r = seq - UInt64(redOffset)
            if r >= next && held[r] == nil {
                held[r] = Held(audio: redAudio, repaired: true)
            }
        }
        drain()
        return out
    }

    private func drain() {
        while true {
            if let h = held.removeValue(forKey: next) {
                out.append(Event(seq: next, audio: h.audio))
                delivered += 1
                if h.repaired { repaired += 1 }
                next += 1
                continue
            }
            if high < next + lag + 2 {
                return
            }
            var run: UInt64 = 1
            while true {
                let s = next + run
                if held[s] != nil { break }
                if high < s + lag + 2 { break }
                run += 1
            }
            if run > skip {
                next += run
                skipped += Int(run)
                continue
            }
            out.append(Event(seq: next, audio: nil))
            concealed += 1
            next += 1
        }
    }
}
