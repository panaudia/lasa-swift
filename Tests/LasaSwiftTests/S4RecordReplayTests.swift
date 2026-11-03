// Replays an S4 arrival record (s4-io<n>-<stamp>.rec) through the v4
// jitter buffer on an ideal reader clock, so a phone run's underruns,
// inserts and drops can be attributed: if the buffer alone, fed the
// recorded arrivals, produces the same ledger, the pump and the engine
// added nothing (T5 §7.1a's attribution, exact instead of modelled).
//
// Skips unless S4_REPLAY_REC names a record. Optional:
//   S4_REPLAY_READER        reader frames per call (480 = 10 ms, 240 = 5 ms)
//   S4_REPLAY_PPM           the audio clock against the wall clock (the
//                           summary's "audio clock vs wall")
//   S4_REPLAY_READ_SECONDS  stop reading this long after the first packet
//                           (the summary's audio clock span)
// The reader's phase against the arrivals is unknown, so every phase
// from 0 to the read period in 1 ms steps is replayed and reported.
//
// Added 2026-11-03 to read the first phone S4 records.

import XCTest
@testable import LasaSwift

@available(macOS 15.0, iOS 18.0, *)
final class S4RecordReplayTests: XCTestCase {
    struct Replay {
        var phaseMS: Double
        var underruns: Int64
        var underrunTimes: [Double]
        var inserted: Int64
        var dropped: Int64
        var trims: Int64
        var setpoint: Int64
        var reads: Int
    }

    func testReplayRecord() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["S4_REPLAY_REC"] else { throw XCTSkip("set S4_REPLAY_REC to a record file") }
        let readerFrames = Int64(env["S4_REPLAY_READER"] ?? "480")!
        let ppm = Double(env["S4_REPLAY_PPM"] ?? "0")!
        let readSeconds = Double(env["S4_REPLAY_READ_SECONDS"] ?? "1e9")!

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThanOrEqual(data.count, 16)
        var arrivals: [Int64] = []
        var recordedUnderruns: [(t: Double, count: UInt64)] = []
        var t0: Int64 = 0
        data.withUnsafeBytes { raw in
            var off = 16
            while off + 32 <= raw.count {
                let seq = raw.loadUnaligned(fromByteOffset: off, as: UInt64.self)
                let t = raw.loadUnaligned(fromByteOffset: off + 8, as: Int64.self)
                let code = raw.loadUnaligned(fromByteOffset: off + 24, as: UInt32.self)
                let flags = raw.loadUnaligned(fromByteOffset: off + 28, as: UInt32.self)
                off += 32
                if flags & 2 != 0 {
                    if code == 20, t0 != 0 { // SwiftPump.eventUnderrun
                        recordedUnderruns.append((Double(t - t0) / 1e9, seq))
                    }
                    continue
                }
                if t0 == 0 { t0 = t }
                arrivals.append(t - t0)
            }
        }
        XCTAssertFalse(arrivals.isEmpty)
        let readPeriodNS = Double(readerFrames) / 48_000 * 1e9 / (1 + ppm * 1e-6)
        let readEndNS = min(Int64(readSeconds * 1e9), arrivals.last!)

        print("record \(path)")
        print("packets \(arrivals.count) span \(Double(arrivals.last!) / 1e9) s, reader \(readerFrames) fr, \(ppm) ppm, reads until \(Double(readEndNS) / 1e9) s")
        print("recorded underruns (time s, running count): \(recordedUnderruns.map { "\(String(format: "%.1f", $0.t))->\($0.count)" }.joined(separator: " "))")

        // Packet content: a slow sine, so the splice cut has real
        // differences to compare. Any content gives the same counts.
        var frame = [Float](repeating: 0, count: 240 * 2)
        for i in 0..<240 { let v = Float(sin(Double(i) * 0.05)); frame[i * 2] = v; frame[i * 2 + 1] = v }
        let rbuf = UnsafeMutablePointer<Float>.allocate(capacity: Int(readerFrames) * 2)
        defer { rbuf.deallocate() }

        var results: [Replay] = []
        var phase = 0.0
        while phase < readPeriodNS / 1e6 {
            var cfg = JitterBuffer.Config()
            cfg.sampleRate = 48_000
            cfg.numChannels = 2
            cfg.writerFrames = 240
            cfg.readerFrames = readerFrames
            let jb = JitterBuffer(cfg)
            var pi = 0
            var k = 0
            var lastU: Int64 = 0
            var times: [Double] = []
            var reads = 0
            while true {
                let tRead = Int64(phase * 1e6 + Double(k) * readPeriodNS)
                if tRead > readEndNS { break }
                while pi < arrivals.count && arrivals[pi] <= tRead {
                    frame.withUnsafeBufferPointer { jb.write($0) }
                    pi += 1
                }
                jb.read(into: rbuf, frames: readerFrames)
                reads += 1
                let u = jb.snapshot().underruns
                if u != lastU { times.append(Double(tRead) / 1e9); lastU = u }
                k += 1
            }
            let s = jb.snapshot()
            results.append(Replay(phaseMS: phase, underruns: s.underruns, underrunTimes: times,
                                  inserted: s.samplesInserted, dropped: s.samplesDropped, trims: s.trims,
                                  setpoint: Int64(s.setpointFrames), reads: reads))
            phase += 1
        }
        for r in results {
            let t = r.underrunTimes.map { String(format: "%.1f", $0) }.joined(separator: " ")
            print(String(format: "phase %2.0f ms: reads %d  underruns %lld  inserts %lld  drops %lld  trims %lld  setpoint %lld fr  at: %@",
                         r.phaseMS, r.reads, r.underruns, r.inserted, r.dropped, r.trims, r.setpoint, t))
        }
    }
}
