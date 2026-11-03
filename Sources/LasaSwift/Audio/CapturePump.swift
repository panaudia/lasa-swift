// The uplink half of the pump (plan lasa-swift.md §4, rules 2 and 3):
// the capture callback writes the C ring and signals; a dedicated
// thread blocked on that signal wakes, encodes every whole 240-frame
// packet the ring holds, hands each to `publish` at once, and blocks
// again. No clock, no timer, nothing held. Split out of SwiftPump on
// 2026-11-03 so LasaClient.startCapture owns one per capture.

import Foundation
import Synchronization
import CRings

@available(iOS 18.0, macOS 15.0, *)
public final class CapturePump: @unchecked Sendable {
    public static let sampleRate = 48_000
    public static let frameSize = 240
    static let ringFrames: UInt32 = 200 * 48
    static let maxPacket = 1500
    static let waitMS: UInt32 = 250
    static let stallThresholdNS: Int64 = 10_000_000

    public enum UplinkMode: String, Sendable { case thread, task }

    public struct Config: Sendable {
        public var bitrate: Int32 = 64_000
        public var complexity: Int32 = 5
        public var uplink: UplinkMode = .thread
        public var uplinkPriority: TaskPriority = .userInitiated
        public init() {}
    }

    public struct Stats: Sendable {
        public var wakes: UInt64 = 0, wakeTimeouts: UInt64 = 0, packetsSent: UInt64 = 0
        public var wakesWith1: UInt64 = 0, wakesWith2: UInt64 = 0, wakesWithMore: UInt64 = 0
        public var wakeLatencyMaxMS = 0.0
        public var wakeLatencyOver1ms: UInt64 = 0
        public var encodeMaxMS = 0.0
        public var remainderMaxFrames: UInt64 = 0
        public var captureOverruns: UInt64 = 0, captureOverrunFrames: UInt64 = 0
    }

    public let capture: OpaquePointer // ring_t*, mono
    public let config: Config
    public let meter = StereoMeter()
    private let enc: OpusEncoder
    private let rec: RecordWriter?

    private let wakes = Atomic<UInt64>(0)
    private let wakeTimeouts = Atomic<UInt64>(0)
    private let packetsSent = Atomic<UInt64>(0)
    private let wakesWith1 = Atomic<UInt64>(0)
    private let wakesWith2 = Atomic<UInt64>(0)
    private let wakesWithMore = Atomic<UInt64>(0)
    private let wakeLatMaxNS = Atomic<Int64>(0)
    private let wakeLatOver1ms = Atomic<UInt64>(0)
    private let encodeMaxNS = Atomic<Int64>(0)
    private let remainderMax = Atomic<UInt64>(0)
    private let stopped = Atomic<Bool>(false)
    private var thread: Thread?
    private var task: Task<Void, Never>?

    /// `record`, when given, receives the wake and encode stall marks.
    public init(_ config: Config, record: RecordWriter? = nil) throws {
        self.config = config
        guard let c = ring_new(Self.ringFrames, 1) else { throw TransportError.sessionClosed("ring allocation failed") }
        capture = c
        enc = try OpusEncoder(bitrate: config.bitrate, complexity: config.complexity)
        rec = record
    }

    deinit { ring_free(capture) }

    @inline(__always) static func maxStore(_ a: borrowing Atomic<Int64>, _ v: Int64) {
        var cur = a.load(ordering: .relaxed)
        while v > cur {
            let (done, old) = a.compareExchange(expected: cur, desired: v, ordering: .relaxed)
            if done { return }
            cur = old
        }
    }

    /// Starts the sender. `publish` is called on the sender's thread or
    /// task with each encoded frame; it must not block for long.
    public func run(publish: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) {
        switch config.uplink {
        case .thread:
            let t = Thread { [self] in uplink(publish) }
            t.name = "lasa-uplink"
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
        case .task:
            task = Task.detached(priority: config.uplinkPriority) { [self] in uplink(publish) }
        }
    }

    private func uplink(_ publish: @Sendable (UnsafeBufferPointer<UInt8>) -> Void) {
        let pcm = UnsafeMutablePointer<Float>.allocate(capacity: Self.frameSize)
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.maxPacket)
        defer { pcm.deallocate(); out.deallocate() }
        while !stopped.load(ordering: .relaxed) {
            if ring_wait(capture, Self.waitMS) == 0 {
                wakeTimeouts.add(1, ordering: .relaxed)
                continue
            }
            let now = Int64(ring_now_ns())
            let sig = Int64(ring_last_signal_ns(capture))
            if now > sig {
                let lat = now - sig
                Self.maxStore(wakeLatMaxNS, lat)
                if lat > 1_000_000 { wakeLatOver1ms.add(1, ordering: .relaxed) }
                if lat > Self.stallThresholdNS {
                    rec?.appendEvent(nowNS: ArrivalClock.nowNS(), code: SwiftPump.eventWakeStall, arg: UInt64(lat / 1_000_000))
                }
            }
            wakes.add(1, ordering: .relaxed)
            var sent = 0
            while ring_fill(capture) >= UInt32(Self.frameSize) {
                _ = ring_read(capture, pcm, UInt32(Self.frameSize))
                meter.write(interleaved: pcm, frames: Self.frameSize, channels: 1)
                let t0 = Int64(ring_now_ns())
                let n: Int
                do {
                    n = try enc.encode(pcm, frames: Self.frameSize, into: out, capacity: Self.maxPacket)
                } catch {
                    continue
                }
                let dt = Int64(ring_now_ns()) - t0
                Self.maxStore(encodeMaxNS, dt)
                if dt > Self.stallThresholdNS {
                    rec?.appendEvent(nowNS: ArrivalClock.nowNS(), code: SwiftPump.eventEncodeStall, arg: UInt64(dt / 1_000_000))
                }
                publish(UnsafeBufferPointer(start: out, count: n))
                sent += 1
            }
            let rem = UInt64(ring_fill(capture))
            var cur = remainderMax.load(ordering: .relaxed)
            while rem > cur {
                let (done, old) = remainderMax.compareExchange(expected: cur, desired: rem, ordering: .relaxed)
                if done { break }
                cur = old
            }
            switch sent {
            case 1: wakesWith1.add(1, ordering: .relaxed)
            case 2: wakesWith2.add(1, ordering: .relaxed)
            case 3...: wakesWithMore.add(1, ordering: .relaxed)
            default: break
            }
            packetsSent.add(UInt64(sent), ordering: .relaxed)
        }
    }

    /// Ends the sender; it exits at its next wake or wait timeout.
    public func stop() {
        stopped.store(true, ordering: .relaxed)
        ring_signal(capture)
        task?.cancel()
    }

    public func stats() -> Stats {
        var s = Stats()
        s.wakes = wakes.load(ordering: .relaxed)
        s.wakeTimeouts = wakeTimeouts.load(ordering: .relaxed)
        s.packetsSent = packetsSent.load(ordering: .relaxed)
        s.wakesWith1 = wakesWith1.load(ordering: .relaxed)
        s.wakesWith2 = wakesWith2.load(ordering: .relaxed)
        s.wakesWithMore = wakesWithMore.load(ordering: .relaxed)
        s.wakeLatencyMaxMS = Double(wakeLatMaxNS.load(ordering: .relaxed)) / 1e6
        s.wakeLatencyOver1ms = wakeLatOver1ms.load(ordering: .relaxed)
        s.encodeMaxMS = Double(encodeMaxNS.load(ordering: .relaxed)) / 1e6
        s.remainderMaxFrames = remainderMax.load(ordering: .relaxed)
        s.captureOverruns = ring_overruns(capture)
        s.captureOverrunFrames = ring_overrun_frames(capture)
        return s
    }
}
