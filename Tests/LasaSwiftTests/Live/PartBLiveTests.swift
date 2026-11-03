// Part B gates S1 and S2 (plan §5.4, §5.5) and the S3 (a) receive
// smoke, run from this Mac against a live server. These are the
// development runs the plan allows before the device repeat; a result
// here goes into §7 only once repeated on a phone. The procedure itself
// is PartBSuite, which the Probe app's Part B screen runs on the phone.
//
//   PROBE_LIVE=test.panaudia.com:443 swift test --filter PartBLiveTests
//   PROBE_CAPTURE_PATH=<file.rec> writes the S3 (a) arrival record.
//   PROBE_CAPTURE_DIR=<dir> receives the S3 (b) and (e) send records.
//   PROBE_LIVE_SECS=<n> lengthens the S3 (a) capture (default 10).
//
// S3 (c) and (d) are device runs from the Probe app's Part B tab.

import XCTest
@testable import LasaSwift
import CRings

final class PartBLiveTests: XCTestCase {
    var address: String? { ProcessInfo.processInfo.environment["PROBE_LIVE"] }

    static func ms(_ v: Double) -> String { String(format: "%.2f", v) }
    func log(_ s: String) { print("[partB] \(s)") }

    @available(macOS 26.0, *)
    func suite() throws -> PartBSuite {
        guard let address else { throw XCTSkip("set PROBE_LIVE=host:port") }
        return PartBSuite(address: address,
                          log: { print("[partB] \($0)") },
                          sessionLog: { print("[session] \($0)") })
    }

    func testS1HandshakeAndSetup() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        try await suite().s1()
    }

    func testS2StreamsAndStateRoundTrip() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        try await suite().s2()
    }

    func testS3aReceiveSmoke() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        let secs = Int(ProcessInfo.processInfo.environment["PROBE_LIVE_SECS"] ?? "") ?? 10
        let record = ProcessInfo.processInfo.environment["PROBE_CAPTURE_PATH"].map { URL(fileURLWithPath: $0) }
        _ = try await suite().s3a(seconds: secs, record: record)
    }

    func sendRecord(_ name: String) -> URL? {
        guard let dir = ProcessInfo.processInfo.environment["PROBE_CAPTURE_DIR"] else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return URL(fileURLWithPath: dir).appendingPathComponent("mac-swift-\(name)-send-\(stamp).rec")
    }

    func testS3bSendSmoke() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        _ = try await suite().s3b(seconds: 10, record: sendRecord("s3b"))
    }

    /// S4 from the Mac: the whole pump against the live server with a
    /// synthetic microphone (a 1 kHz tone written into the capture ring
    /// every 10 ms, the way a 10 ms I/O buffer would) and a wall-clock
    /// speaker draining the jitter buffer 480 frames every 10 ms. Proves
    /// the path and prints the pump's and the buffer's numbers; the
    /// phone's render blocks are the measurement (plan §1.6).
    func testS4PumpSmoke() async throws {
        guard let address else { throw XCTSkip("set PROBE_LIVE=host:port") }
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        let secs = Int(ProcessInfo.processInfo.environment["PROBE_LIVE_SECS"] ?? "") ?? 10
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        var o = S4Session.Options(address: address, clientID: "swift-s4-\(stamp)", entityID: "swift-s4-\(stamp)-ears")
        o.pump.readerFrames = 480
        o.log = { print("[session] \($0)") }
        let s = try S4Session(o)
        try await s.start()
        let pump = s.pump
        let stop = Locked(false)
        // The "microphone".
        let mic = Thread {
            var buf = [Float](repeating: 0, count: 480)
            var ph = 0.0
            while !stop.with({ $0 }) {
                for i in 0..<480 { buf[i] = Float(0.1 * sin(ph)); ph += 2 * .pi * 1000 / 48_000 }
                buf.withUnsafeBufferPointer { _ = ring_write(pump.capture, $0.baseAddress!, 480) }
                ring_signal(pump.capture)
                Thread.sleep(forTimeInterval: 0.010)
            }
        }
        mic.start()
        // The "speaker", on the wall clock.
        let reads = Locked((calls: 0, produced: 0))
        let spk = Thread {
            let out = UnsafeMutablePointer<Float>.allocate(capacity: 480 * 2)
            defer { out.deallocate() }
            let t0 = Date()
            var n = 0
            while !stop.with({ $0 }) {
                let due = t0.addingTimeInterval(Double(n) * 0.010)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let ok = pump.jitter.read(into: out, frames: 480)
                reads.with { $0.calls += 1; if ok { $0.produced += 1 } }
                n += 1
            }
        }
        spk.start()
        try await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
        stop.with { $0 = true }
        let st = s.stats()
        let p = st.pump, j = p.jitter
        let r = reads.with { $0 }
        log("S4 \(secs) s: wakes \(p.wakes) (1:\(p.wakesWith1) 2:\(p.wakesWith2) 3+:\(p.wakesWithMore) timeouts \(p.wakeTimeouts)) wake latency max \(Self.ms(p.wakeLatencyMaxMS)) ms over 1 ms \(p.wakeLatencyOver1ms); sent \(st.sent) errors \(st.sendErrors); received \(p.packetsReceived) decode errors \(p.decodeErrors); encode max \(Self.ms(p.encodeMaxMS)) ms decode max \(Self.ms(p.decodeMaxMS)) ms")
        log("S4 jitter: fill \(j.fillFrames) fr setpoint \(j.setpointFrames) fr widths \(j.widthLowFrames)/\(j.widthHighFrames) rate \(String(format: "%.2f", j.ratePerSec))/s frozen \(j.frozen) underruns \(j.underruns) laps \(j.laps) overruns \(j.overruns) trims \(j.trims) drops \(j.samplesDropped) inserts \(j.samplesInserted); speaker reads \(r.calls) produced \(r.produced)")
        s.stop()
        XCTAssertGreaterThan(st.sent, UInt64(150 * secs), "uplink at 200 per second")
        XCTAssertEqual(st.sendErrors, 0)
        XCTAssertGreaterThan(p.packetsReceived, UInt64(150 * secs), "sink at 200 per second")
        XCTAssertEqual(p.decodeErrors, 0)
        XCTAssertGreaterThan(r.produced, r.calls / 2, "the buffer produced audio for most reads")
        if let dir = ProcessInfo.processInfo.environment["PROBE_CAPTURE_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("mac-swift-s4-\(ISO8601DateFormatter().string(from: Date())).rec")
            try pump.flush(to: url)
            log("S4 record written to \(url.path)")
        }
    }

    func testS3eSendLimit() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        _ = try await suite().s3e(seconds: 5, record: sendRecord("s3e"))
    }
}
