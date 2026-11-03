// The quality-level mapping and the FEC floor (Go QualityLevel,
// jitter-buffer-core.ts), the meter, and a pipeline fed synthetic
// packets on macOS. 2026-11-03.

import XCTest
@testable import LasaSwift

@available(macOS 15.0, *)
final class SinkPipelineTests: XCTestCase {
    func testQualityDefaults() {
        let q0 = SinkPipeline.qualityDefaults(0)
        XCTAssertEqual(q0.floor, 0); XCTAssertEqual(q0.robustness, 1); XCTAssertEqual(q0.capacity, 0)
        let q1 = SinkPipeline.qualityDefaults(1)
        XCTAssertEqual(q1.floor, 2400); XCTAssertEqual(q1.robustness, 4); XCTAssertEqual(q1.capacity, 24000)
        let q2 = SinkPipeline.qualityDefaults(2)
        XCTAssertEqual(q2.floor, 7200); XCTAssertEqual(q2.robustness, 8); XCTAssertEqual(q2.capacity, 19200)
        XCTAssertEqual(SinkPipeline.qualityDefaults(5).floor, 7200)
    }

    func testFecFloor() {
        XCTAssertEqual(SinkPipeline.fecFloor(maxOffset: 0, writerFrames: 240), 0)
        XCTAssertEqual(SinkPipeline.fecFloor(maxOffset: 1, writerFrames: 240), 1440)
        XCTAssertEqual(SinkPipeline.fecFloor(maxOffset: 3, writerFrames: 240), 2400)
    }

    func testMeter() {
        let m = StereoMeter()
        var pcm = [Float](repeating: 0, count: 480 * 2)
        for i in 0..<480 { pcm[i * 2] = 0.5; pcm[i * 2 + 1] = -0.5 }   // pure side
        pcm.withUnsafeBufferPointer { m.write(interleaved: $0.baseAddress!, frames: 480, channels: 2) }
        let r = m.snapshotAndReset()
        XCTAssertEqual(r.frames, 480)
        XCTAssertEqual(r.rmsL, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.midRms, 0, accuracy: 1e-9)
        XCTAssertEqual(r.sideRms, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.correlation, -1, accuracy: 1e-9)
        XCTAssertEqual(m.snapshotAndReset().frames, 0)
        var mono = [Float](repeating: 0.25, count: 100)
        mono.withUnsafeBufferPointer { m.write(interleaved: $0.baseAddress!, frames: 100, channels: 1) }
        let r2 = m.snapshotAndReset()
        XCTAssertEqual(r2.sideRms, 0, accuracy: 1e-9)
        XCTAssertEqual(r2.correlation, 1, accuracy: 1e-9)
    }

    func testPipelineCountsLossAndReorder() throws {
        var c = SinkPipeline.Config()
        c.readerFrames = 480
        let p = try SinkPipeline(c)
        // A real Opus silence frame from the probe's payload helper.
        let frame = Lasa.opusSilenceFrame
        func packet(_ seq: UInt64) -> [UInt8] { [0] + frame }   // flags 0: audio only
        let seqs: [UInt64] = [1, 2, 3, 5, 6, 4, 7]
        for s in seqs { packet(s).withUnsafeBytes { p.onSink(arrivalNS: 0, seq: s, payload: $0) } }
        let i = p.ingress()
        XCTAssertEqual(i.received, 7)
        XCTAssertEqual(i.gapEvents, 1)
        XCTAssertEqual(i.lostFrames, 1)
        XCTAssertEqual(i.reordered, 1)
        XCTAssertEqual(i.decodeErrors, 0)
        XCTAssertEqual(i.jitter.fillFrames, 7 * 240)
    }
}
