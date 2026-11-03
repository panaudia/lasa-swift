// The S4 pump (plan §5.7): the T5 pump with Swift in Go's place, and the
// v4 jitter buffer in place of T5's fixed fill. No clock of its own.
//
// Uplink: the mic callback writes into the capture ring and signals; a
// sender blocked on that signal wakes, encodes and sends every whole
// 240-frame packet the ring holds, and blocks again. The sender is a
// dedicated thread by default (a goroutine parked on a semaphore costs
// nothing; a cooperative-pool task parked on one costs a pool thread),
// or a detached task when the cell asks, which is the §5.7 question.
//
// Downlink: a sink packet's arrival is the event. The receive loop
// decodes it and writes it to the jitter buffer; the speaker's render
// block reads the buffer at the hardware rate (AudioRings .jitter). The
// buffer owns startup, placement, splices, trims and the underrun valve.
//
// Instrumentation as T5's pump, so the two compare line for line, plus
// the jitter buffer's snapshot, and the T4-style arrival record with
// T5's event marks (underrun, wake, encode and decode stalls).

import Foundation
import Synchronization
import CRings

@available(iOS 18.0, macOS 15.0, *)
public final class SwiftPump: @unchecked Sendable {
    public static let sampleRate = 48_000
    public static let frameSize = 240
    static let ringFrames: UInt32 = 200 * 48
    static let maxPacket = 1500
    static let waitMS: UInt32 = 250
    static let stallThresholdNS: Int64 = 10_000_000

    public static let eventUnderrun: UInt32 = 20
    public static let eventWakeStall: UInt32 = 21
    public static let eventEncodeStall: UInt32 = 22
    public static let eventDecodeStall: UInt32 = 23
    public static let eventStop: UInt32 = 9

    public enum UplinkMode: String, Sendable { case thread, task }

    public struct Config: Sendable {
        /// R: the frames per render call the session asked for (480 at
        /// 10 ms, 240 at 5 ms); the buffer's reader frame.
        public var readerFrames: Int64 = 480
        public var bitrate: Int32 = 48_000
        public var uplink: UplinkMode = .thread
        public var uplinkPriority: TaskPriority = .userInitiated
        /// The jitter buffer's declared floor, κ and capacity (frames; 0
        /// = defaults, the interactive level).
        public var floorFrames: Int64 = 0
        public var robustness = 0.0
        public var capacityFrames: Int64 = 0
        public var recordMaxRecords = 200 * 60 * 15
        public init() {}
    }

    public struct Stats: Sendable {
        public var wakes: UInt64 = 0, wakeTimeouts: UInt64 = 0, packetsSent: UInt64 = 0
        public var wakesWith1: UInt64 = 0, wakesWith2: UInt64 = 0, wakesWithMore: UInt64 = 0
        public var wakeLatencyMaxMS = 0.0
        public var wakeLatencyOver1ms: UInt64 = 0
        public var encodeMaxMS = 0.0, decodeMaxMS = 0.0
        public var remainderMaxFrames: UInt64 = 0
        public var packetsReceived: UInt64 = 0, decodeErrors: UInt64 = 0
        public var captureOverruns: UInt64 = 0, captureOverrunFrames: UInt64 = 0
        public var jitter = JitterBuffer.Snapshot()
    }

    public let capture: OpaquePointer // ring_t*, mono
    public let jitter: JitterBuffer
    public let config: Config
    private let enc: OpusEncoder
    private let dec: OpusDecoder

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
    private let packetsRecv = Atomic<UInt64>(0)
    private let decodeMaxNS = Atomic<Int64>(0)
    private let decodeErrors = Atomic<UInt64>(0)
    private let stopped = Atomic<Bool>(false)

    // Receive-loop scratch: one packet's PCM, room for a 20 ms packet.
    private let pcmOut: UnsafeMutablePointer<Float>
    private static let pcmOutFrames = 240 * 4
    private let rec: RecordWriter
    private var lastUnderrun: Int64 = 0
    private var thread: Thread?
    private var task: Task<Void, Never>?

    public init(_ config: Config) throws {
        self.config = config
        guard let c = ring_new(Self.ringFrames, 1) else { throw TransportError.sessionClosed("ring allocation failed") }
        capture = c
        var jc = JitterBuffer.Config()
        jc.sampleRate = Self.sampleRate
        jc.numChannels = 2
        jc.writerFrames = Int64(Self.frameSize)
        jc.readerFrames = config.readerFrames
        jc.floorFrames = config.floorFrames
        jc.robustness = config.robustness
        jc.capacityFrames = config.capacityFrames
        jitter = JitterBuffer(jc)
        enc = try OpusEncoder(bitrate: config.bitrate)
        dec = try OpusDecoder(channels: 2)
        pcmOut = UnsafeMutablePointer<Float>.allocate(capacity: Self.pcmOutFrames * 2)
        rec = RecordWriter(maxRecords: config.recordMaxRecords)
    }

    deinit {
        pcmOut.deallocate()
        ring_free(capture)
    }

    @inline(__always) private static func maxStore(_ a: borrowing Atomic<Int64>, _ v: Int64) {
        var cur = a.load(ordering: .relaxed)
        while v > cur {
            let (done, old) = a.compareExchange(expected: cur, desired: v, ordering: .relaxed)
            if done { return }
            cur = old
        }
    }

    // MARK: Downlink

    /// The sink's datagram handler: runs on the receive loop. Splits the
    /// packet, records the arrival, decodes straight into the jitter
    /// buffer.
    public func onSink(arrivalNS: Int64, seq: UInt64, payload: UnsafeRawBufferPointer) {
        guard let s = Lasa.splitSink(payload) else { return }
        rec.append(seq: seq, arrivalNS: arrivalNS, serverUS: s.timestamp, payloadLen: UInt32(payload.count))
        let t0 = Int64(ring_now_ns())
        let audio = payload.baseAddress!.advanced(by: s.audio.lowerBound).assumingMemoryBound(to: UInt8.self)
        let n: Int
        do {
            n = try dec.decode(audio, count: s.audio.count, into: pcmOut, capacityFrames: Self.pcmOutFrames)
        } catch {
            decodeErrors.add(1, ordering: .relaxed)
            return
        }
        jitter.write(UnsafeBufferPointer(start: pcmOut, count: n * 2))
        let dt = Int64(ring_now_ns()) - t0
        Self.maxStore(decodeMaxNS, dt)
        if dt > Self.stallThresholdNS {
            rec.appendEvent(nowNS: ArrivalClock.nowNS(), code: Self.eventDecodeStall, arg: UInt64(dt / 1_000_000))
        }
        let u = jitter.snapshot().underruns
        if u != lastUnderrun {
            lastUnderrun = u
            rec.appendEvent(nowNS: ArrivalClock.nowNS(), code: Self.eventUnderrun, arg: UInt64(u))
        }
        packetsRecv.add(1, ordering: .relaxed)
    }

    // MARK: Uplink

    /// Starts the sender. `publish` is called on the sender's thread or
    /// task with each encoded frame and its sequence; it must not block
    /// for long (S4Session hands the bytes to an ordered send task).
    public func run(publish: @escaping @Sendable (UInt64, UnsafeBufferPointer<UInt8>) -> Void) {
        switch config.uplink {
        case .thread:
            let t = Thread { [self] in uplink(publish) }
            t.name = "s4-uplink"
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
        case .task:
            task = Task.detached(priority: config.uplinkPriority) { [self] in uplink(publish) }
        }
    }

    private func uplink(_ publish: @Sendable (UInt64, UnsafeBufferPointer<UInt8>) -> Void) {
        let pcm = UnsafeMutablePointer<Float>.allocate(capacity: Self.frameSize)
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.maxPacket)
        defer { pcm.deallocate(); out.deallocate() }
        var seq: UInt64 = 0
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
                    rec.appendEvent(nowNS: ArrivalClock.nowNS(), code: Self.eventWakeStall, arg: UInt64(lat / 1_000_000))
                }
            }
            wakes.add(1, ordering: .relaxed)
            var sent = 0
            while ring_fill(capture) >= UInt32(Self.frameSize) {
                _ = ring_read(capture, pcm, UInt32(Self.frameSize))
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
                    rec.appendEvent(nowNS: ArrivalClock.nowNS(), code: Self.eventEncodeStall, arg: UInt64(dt / 1_000_000))
                }
                publish(seq, UnsafeBufferPointer(start: out, count: n))
                seq += 1
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

    /// Stamps a lifecycle or engine transition into the record (the T4
    /// vocabulary: 1 foreground, 2 background, 3 inactive; LasaAudio's
    /// 30 to 35), so a background episode is a fact in the file.
    public func mark(_ code: UInt32, arg: UInt64 = 0) {
        rec.appendEvent(nowNS: ArrivalClock.nowNS(), code: code, arg: arg)
    }

    public static let markForeground: UInt32 = 1
    public static let markBackground: UInt32 = 2
    public static let markInactive: UInt32 = 3

    /// Writes the arrival record with a stop mark.
    public func flush(to url: URL) throws {
        rec.appendEvent(nowNS: ArrivalClock.nowNS(), code: Self.eventStop)
        try rec.flush(to: url)
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
        s.decodeMaxMS = Double(decodeMaxNS.load(ordering: .relaxed)) / 1e6
        s.remainderMaxFrames = remainderMax.load(ordering: .relaxed)
        s.packetsReceived = packetsRecv.load(ordering: .relaxed)
        s.decodeErrors = decodeErrors.load(ordering: .relaxed)
        s.captureOverruns = ring_overruns(capture)
        s.captureOverrunFrames = ring_overrun_frames(capture)
        s.jitter = jitter.snapshot()
        return s
    }
}

#if os(iOS)
@available(iOS 18.0, *)
extension JitterBuffer: PlaybackReader {
    public func readPlayback(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        read(into: dst, frames: Int64(frames))
    }
    public var playbackFillFrames: Int64 { fillFrames }
}
#endif
