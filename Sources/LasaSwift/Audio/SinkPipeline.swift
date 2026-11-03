// The downlink half of the pump (plan lasa-swift.md §4): a sink packet's
// arrival is the event. On the receive loop: the FEC reassembler when
// the entity declared redundancy, the Opus decode, the write into the
// v4 jitter buffer, the ingress counters, the meter, and the arrival
// record with its marks. The render block reads the buffer. The quality
// level maps to the buffer's floor, robustness and capacity exactly as
// Go's QualityLevel (jitter-buffer-core.ts), and a declared redundancy
// composes its FEC floor by max. Split out of SwiftPump on 2026-11-03
// so LasaClient.playSink owns one per sink.

import Foundation
import Synchronization
import CRings

@available(iOS 18.0, macOS 15.0, *)
public final class SinkPipeline: @unchecked Sendable {
    public static let sampleRate = 48_000
    public static let writerFrames: Int64 = 240
    static let stallThresholdNS: Int64 = 10_000_000

    public struct Config: Sendable {
        /// R: the frames per render call (480 at 10 ms, 240 at 5 ms).
        public var readerFrames: Int64 = 480
        /// LASA quality level 0 to 2, the latency-tolerance intent.
        public var quality = 0
        /// The entity's declared redundancy offset; > 0 puts the
        /// reassembler in the path and composes the FEC floor.
        public var redundancy = 0
        /// Explicit overrides, frames; 0 = from the quality level.
        public var floorFrames: Int64 = 0
        public var robustness = 0.0
        public var capacityFrames: Int64 = 0
        public var channels = 2
        public init() {}
    }

    /// Ingress health, as the TypeScript SinkIngress plus the FEC and
    /// buffer counters.
    public struct Ingress: Sendable {
        public var received: UInt64 = 0
        public var gapEvents: UInt64 = 0
        public var lostFrames: UInt64 = 0
        public var reordered: UInt64 = 0
        public var decodeErrors: UInt64 = 0
        public var fecRepaired = 0
        public var fecConcealed = 0
        public var fecSkipped = 0
        public var decodeMaxMS = 0.0
        public var jitter = JitterBuffer.Snapshot()
    }

    public let jitter: JitterBuffer
    public let config: Config
    public let meter = StereoMeter()
    private let dec: OpusDecoder
    private let reassembler: SinkReassembler?
    private let rec: RecordWriter?
    private let pcmOut: UnsafeMutablePointer<Float>
    private static let pcmOutFrames = 240 * 4
    private let received = Atomic<UInt64>(0)
    private let gapEvents = Atomic<UInt64>(0)
    private let lostFrames = Atomic<UInt64>(0)
    private let reordered = Atomic<UInt64>(0)
    private let decodeErrors = Atomic<UInt64>(0)
    private let decodeMaxNS = Atomic<Int64>(0)
    private var lastSeq: UInt64? = nil
    private var lastUnderrun: Int64 = 0

    /// The quality level's defaults (Go QualityLevel): floor, robustness,
    /// capacity in frames.
    public static func qualityDefaults(_ level: Int) -> (floor: Int64, robustness: Double, capacity: Int64) {
        let f = { (ms: Int64) in ms * Int64(sampleRate) / 1000 }
        switch level {
        case 1: return (f(50), 4, f(500))
        case 2...: return (f(150), 8, f(400))
        default: return (0, 1, 0)
        }
    }

    /// The FEC floor: with a maximum offset n the buffer must hold the
    /// frames a repair can still arrive for.
    public static func fecFloor(maxOffset: Int, writerFrames: Int64) -> Int64 {
        maxOffset <= 0 ? 0 : 2 * Int64(maxOffset + 2) * writerFrames
    }

    public init(_ config: Config, record: RecordWriter? = nil) throws {
        self.config = config
        let q = Self.qualityDefaults(config.quality)
        var jc = JitterBuffer.Config()
        jc.sampleRate = Self.sampleRate
        jc.numChannels = config.channels
        jc.writerFrames = Self.writerFrames
        jc.readerFrames = config.readerFrames
        jc.floorFrames = max(config.floorFrames, q.floor, Self.fecFloor(maxOffset: config.redundancy, writerFrames: Self.writerFrames))
        jc.robustness = config.robustness > 0 ? config.robustness : q.robustness
        jc.capacityFrames = config.capacityFrames > 0 ? config.capacityFrames : q.capacity
        jitter = JitterBuffer(jc)
        dec = try OpusDecoder(channels: config.channels)
        reassembler = config.redundancy > 0 ? SinkReassembler(lag: config.redundancy) : nil
        rec = record
        pcmOut = UnsafeMutablePointer<Float>.allocate(capacity: Self.pcmOutFrames * config.channels)
    }

    deinit { pcmOut.deallocate() }

    /// The sink's datagram handler: runs on the receive loop.
    public func onSink(arrivalNS: Int64, seq: UInt64, payload: UnsafeRawBufferPointer) {
        guard let s = Lasa.splitSink(payload) else { return }
        rec?.append(seq: seq, arrivalNS: arrivalNS, serverUS: s.timestamp, payloadLen: UInt32(payload.count))
        received.add(1, ordering: .relaxed)
        if let last = lastSeq {
            if seq > last + 1 { gapEvents.add(1, ordering: .relaxed); lostFrames.add(seq - last - 1, ordering: .relaxed) }
            else if seq <= last { reordered.add(1, ordering: .relaxed) }
        }
        if lastSeq == nil || seq > lastSeq! { lastSeq = seq }
        let audio = Array(UnsafeRawBufferPointer(rebasing: payload[s.audio]))
        if let r = reassembler {
            var red: [UInt8]? = nil
            var off = 0
            if let p = try? SinkPacket.parse(Array(payload)), let rd = p.redundancy { red = rd.audio; off = rd.offset }
            for e in r.push(seq: seq, audio: audio, redOffset: off, redAudio: red) {
                if let a = e.audio { decode(a) } else { conceal() }
            }
        } else {
            decode(audio)
        }
        let u = jitter.snapshot().underruns
        if u != lastUnderrun {
            lastUnderrun = u
            rec?.appendEvent(nowNS: ArrivalClock.nowNS(), code: SwiftPump.eventUnderrun, arg: UInt64(u))
        }
    }

    private func decode(_ audio: [UInt8]) {
        let t0 = Int64(ring_now_ns())
        let n: Int
        do {
            n = try audio.withUnsafeBufferPointer { try dec.decode($0.baseAddress!, count: $0.count, into: pcmOut, capacityFrames: Self.pcmOutFrames) }
        } catch {
            decodeErrors.add(1, ordering: .relaxed)
            return
        }
        meter.write(interleaved: pcmOut, frames: n, channels: config.channels)
        jitter.write(UnsafeBufferPointer(start: pcmOut, count: n * config.channels))
        let dt = Int64(ring_now_ns()) - t0
        CapturePump.maxStore(decodeMaxNS, dt)
        if dt > Self.stallThresholdNS {
            rec?.appendEvent(nowNS: ArrivalClock.nowNS(), code: SwiftPump.eventDecodeStall, arg: UInt64(dt / 1_000_000))
        }
    }

    /// A dead frame at its position: zero content, so the buffer sees
    /// no drift (the reassembler's contract).
    private func conceal() {
        let n = Int(Self.writerFrames) * config.channels
        pcmOut.update(repeating: 0, count: n)
        jitter.write(UnsafeBufferPointer(start: pcmOut, count: n))
    }

    public func ingress() -> Ingress {
        var i = Ingress()
        i.received = received.load(ordering: .relaxed)
        i.gapEvents = gapEvents.load(ordering: .relaxed)
        i.lostFrames = lostFrames.load(ordering: .relaxed)
        i.reordered = reordered.load(ordering: .relaxed)
        i.decodeErrors = decodeErrors.load(ordering: .relaxed)
        i.decodeMaxMS = Double(decodeMaxNS.load(ordering: .relaxed)) / 1e6
        if let r = reassembler { i.fecRepaired = r.repaired; i.fecConcealed = r.concealed; i.fecSkipped = r.skipped }
        i.jitter = jitter.snapshot()
        return i
    }
}
