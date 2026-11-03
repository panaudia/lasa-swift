// Lockstep replay of the Go generator's reassembler fixtures
// (lasa/typescript/tests/fixtures/reassembler): the same packets in, the
// same released events out, event for event and payload for payload,
// plus counter equality. The TypeScript port passes the same test.

import XCTest
@testable import LasaSwift

final class SinkReassemblerReplayTests: XCTestCase {
    struct Fixture: Decodable {
        struct Counters: Decodable, Equatable { let delivered, repaired, concealed, skipped, stale: Int }
        let name: String
        let lag: Int
        let skipThreshold: Int
        let packets: [[Int]]   // [seq, redOffset] in arrival order
        let events: [[Int]]    // [seq, kind]: 0 = audio, 1 = conceal
        let counters: Counters
    }

    /// The synthetic payload rule shared with the Go generator: seq as u32
    /// little-endian.
    static func canonPayload(_ seq: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: seq)
        return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
    }

    func testFixtureReplayLockstepWithGo() throws {
        guard let dir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/reassembler") else {
            return XCTFail("fixtures not in the bundle")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertGreaterThanOrEqual(files.count, 8)
        for file in files {
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
            XCTAssertEqual(UInt64(fx.skipThreshold), SinkReassembler.skipThreshold)
            let ra = SinkReassembler(lag: fx.lag)
            var got: [[Int]] = []
            for p in fx.packets {
                let (seq, red) = (p[0], p[1])
                let events = ra.push(seq: UInt64(seq), audio: Self.canonPayload(seq), redOffset: red,
                                     redAudio: red > 0 ? Self.canonPayload(seq - red) : nil)
                for e in events {
                    let s = Int(e.seq)
                    if let a = e.audio {
                        XCTAssertEqual(a, Self.canonPayload(s), "\(fx.name): payload of seq \(s)")
                        got.append([s, 0])
                    } else {
                        got.append([s, 1])
                    }
                }
            }
            XCTAssertEqual(got, fx.events, "\(fx.name): events")
            let counters = Fixture.Counters(delivered: ra.delivered, repaired: ra.repaired, concealed: ra.concealed,
                                            skipped: ra.skipped, stale: ra.stale)
            XCTAssertEqual(counters, fx.counters, "\(fx.name): counters")
            print("[reasm] \(fx.name): \(fx.packets.count) packets, \(fx.events.count) events, counters match: \(counters == fx.counters)")
        }
    }
}
