// S5 on the Mac (plan §5.8): libopus through COpus encodes and decodes a
// 5 ms frame both ways, and how long each takes. The phone's numbers are
// the S4 pump's encode and decode maxima.

import XCTest
@testable import LasaSwift

final class OpusCodecTests: XCTestCase {
    func testFiveMillisecondFrameBothWays() throws {
        let enc = try OpusEncoder()
        let dec = try OpusDecoder(channels: 2)
        let frames = 240
        var pcm = [Float](repeating: 0, count: frames)
        var ph = 0.0
        for i in 0..<frames { pcm[i] = Float(0.1 * sin(ph)); ph += 2 * .pi * 1000 / 48_000 }
        var packet = [UInt8](repeating: 0, count: 1500)
        var out = [Float](repeating: 0, count: frames * 2 * 4)

        // Settle, then time 1,000 frames each way.
        var encNS: [Int64] = [], decNS: [Int64] = []
        var sizes: [Int] = []
        for i in 0..<1_100 {
            let t0 = ArrivalClock.nowNS()
            let n = try pcm.withUnsafeBufferPointer { p in
                try packet.withUnsafeMutableBufferPointer { o in
                    try enc.encode(p.baseAddress!, frames: frames, into: o.baseAddress!, capacity: o.count)
                }
            }
            let t1 = ArrivalClock.nowNS()
            let got = try packet.withUnsafeBufferPointer { p in
                try out.withUnsafeMutableBufferPointer { o in
                    try dec.decode(p.baseAddress!, count: n, into: o.baseAddress!, capacityFrames: frames * 4)
                }
            }
            let t2 = ArrivalClock.nowNS()
            XCTAssertEqual(got, frames, "a 5 ms packet decodes to 240 frames")
            if i >= 100 { encNS.append(t1 - t0); decNS.append(t2 - t1); sizes.append(n) }
        }
        // A mono 1 kHz tone at 48 kbps VoIP: a packet of a few dozen bytes,
        // decoded to stereo (the decoder upmixes a mono packet).
        let meanSize = Double(sizes.reduce(0, +)) / Double(sizes.count)
        XCTAssertGreaterThan(meanSize, 3)
        XCTAssertLessThan(meanSize, 200)
        func pct(_ a: [Int64], _ p: Double) -> Double { Double(a.sorted()[Int(Double(a.count - 1) * p)]) / 1000 }
        print(String(format: "[opus] encode median %.1f us p99 %.1f us max %.1f us; decode median %.1f us p99 %.1f us max %.1f us; packet mean %.0f bytes",
                     pct(encNS, 0.5), pct(encNS, 0.99), Double(encNS.max()!) / 1000,
                     pct(decNS, 0.5), pct(decNS, 0.99), Double(decNS.max()!) / 1000, meanSize))
        XCTAssertLessThan(pct(encNS, 0.5), 200, "encode median under 200 us (S5 pass)")
        XCTAssertLessThan(pct(decNS, 0.5), 200, "decode median under 200 us (S5 pass)")
    }

    func testPaddedSilenceDecodesToSilence() throws {
        let dec = try OpusDecoder(channels: 2)
        var out = [Float](repeating: 1, count: 240 * 2 * 4)
        for size in [3, 30, 120, 1150] {
            let p = Lasa.opusPadded(Lasa.opusSilenceFrame, toSize: size)
            let got = try p.withUnsafeBufferPointer { b in
                try out.withUnsafeMutableBufferPointer { o in
                    try dec.decode(b.baseAddress!, count: b.count, into: o.baseAddress!, capacityFrames: 240 * 4)
                }
            }
            XCTAssertEqual(got, 240, "size \(size)")
            let peak = out[0..<(got * 2)].map { abs($0) }.max() ?? 1
            XCTAssertLessThan(peak, 1e-3, "size \(size): decoded peak \(peak)")
        }
    }
}
