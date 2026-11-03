// Port of lasa/typescript/tests/roster.test.ts (every case), which
// mirrors lasa/client/roster_test.go: generation discard, per-index
// latest-wins by group id, tracking reset on generation change,
// chunked-keyframe assembly, and the no-rewind property for late
// keyframe chunks. 2026-11-03.

import XCTest
@testable import LasaSwift

final class PresenceRosterTests: XCTestCase {
    func pose(_ x: Float) -> Pose { Pose(x: x, y: 0, z: 0, yaw: 0, pitch: 0, roll: 0) }

    func krec(_ id: String, _ x: Float, headFrame: Bool = false) -> KeyframeRecord {
        KeyframeRecord(headFrame: headFrame, id: id, pose: pose(x), loudness: 0)
    }

    func kf(_ gen: UInt8, _ first: UInt16, _ records: [KeyframeRecord]) -> PresencePacket {
        .keyframe(PresenceKeyframe(gen: gen, first: first, records: records))
    }

    func drec(_ index: UInt16, _ x: Float) -> DeltaRecord {
        DeltaRecord(index: index, pose: pose(x), loudness: 0)
    }

    func delta(_ gen: UInt8, _ records: [DeltaRecord]) -> PresencePacket {
        .delta(PresenceDelta(gen: gen, records: records))
    }

    func find(_ r: PresenceRoster, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> RosterEntry {
        try XCTUnwrap(r.entries.first { $0.id == id }, "entity \(id) in roster", file: file, line: line)
    }

    func testBuildsFromAKeyframeAndAppliesSameGenDeltas() throws {
        let r = PresenceRoster()
        XCTAssertNil(r.generation)
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1), krec("b", 2)]))
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.generation, 1)
        r.apply(group: 11, packet: delta(1, [drec(0, 5)]))
        XCTAssertEqual(try find(r, "a").pose.x, 5)
        XCTAssertEqual(try find(r, "b").pose.x, 2)
    }

    func testDiscardsDeltasWithAStaleOrPreKeyframeGeneration() throws {
        let r = PresenceRoster()
        r.apply(group: 5, packet: delta(1, [drec(0, 9)]))
        XCTAssertEqual(r.entries.count, 0)
        r.apply(group: 10, packet: kf(2, 0, [krec("a", 1)]))
        r.apply(group: 11, packet: delta(1, [drec(0, 9)]))
        XCTAssertEqual(try find(r, "a").pose.x, 1)
    }

    func testAppliesRecordsLatestWinsByGroupID() throws {
        let r = PresenceRoster()
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1)]))
        r.apply(group: 12, packet: delta(1, [drec(0, 12)]))
        r.apply(group: 11, packet: delta(1, [drec(0, 11)])) // reordered older delta
        XCTAssertEqual(try find(r, "a").pose.x, 12)
        r.apply(group: 12, packet: delta(1, [drec(0, 99)])) // equal group id
        XCTAssertEqual(try find(r, "a").pose.x, 12)
    }

    func testResetsAllTrackingOnGenerationChangeDepartureIncluded() throws {
        let r = PresenceRoster()
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1), krec("b", 2)]))
        r.apply(group: 20, packet: kf(2, 0, [krec("a", 3), krec("c", 4)]))
        let snap = r.entries
        XCTAssertEqual(snap.count, 2)
        XCTAssertNil(snap.first { $0.id == "b" })
        XCTAssertEqual(try find(r, "a").pose.x, 3)
        r.apply(group: 21, packet: delta(2, [drec(1, 7)]))
        XCTAssertEqual(try find(r, "c").pose.x, 7)
        // An empty keyframe of a new generation empties the roster.
        r.apply(group: 30, packet: kf(3, 0, []))
        XCTAssertEqual(r.entries.count, 0)
        XCTAssertEqual(r.generation, 3)
    }

    func testAssemblesChunkedKeyframesWithoutResettingWithinAGen() throws {
        let r = PresenceRoster()
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1), krec("b", 2)]))
        r.apply(group: 11, packet: kf(1, 2, [krec("c", 3)]))
        XCTAssertEqual(r.entries.count, 3)
        r.apply(group: 12, packet: delta(1, [drec(2, 9)]))
        XCTAssertEqual(try find(r, "c").pose.x, 9)
    }

    func testIgnoresDeltasForUnknownIndexes() throws {
        let r = PresenceRoster()
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1)]))
        r.apply(group: 11, packet: delta(1, [drec(5, 9)]))
        XCTAssertEqual(r.entries.count, 1)
    }

    func testDoesNotLetALateKeyframeChunkRewindANewerDeltaPose() throws {
        let r = PresenceRoster()
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1)]))
        r.apply(group: 12, packet: delta(1, [drec(0, 12)]))
        r.apply(group: 11, packet: kf(1, 0, [krec("a", 1)])) // periodic re-list, reordered
        XCTAssertEqual(try find(r, "a").pose.x, 12)
        r.apply(group: 13, packet: kf(1, 0, [krec("a", 13)])) // newer keyframe applies
        XCTAssertEqual(try find(r, "a").pose.x, 13)
    }

    func testCarriesTheHeadFrameFlagAndFiresOnUpdateOnChangeOnly() throws {
        let r = PresenceRoster()
        let updates = Locked(0)
        r.onUpdate { updates.with { $0 += 1 } }
        r.apply(group: 10, packet: kf(1, 0, [krec("hud", 1, headFrame: true)]))
        XCTAssertTrue(try find(r, "hud").headFrame)
        XCTAssertEqual(updates.with { $0 }, 1)
        r.apply(group: 9, packet: delta(1, [drec(0, 5)])) // older: no change, no update
        XCTAssertEqual(updates.with { $0 }, 1)
        r.apply(group: 9, packet: delta(2, [drec(0, 5)])) // wrong generation: no update
        XCTAssertEqual(updates.with { $0 }, 1)
        r.apply(group: 11, packet: delta(1, [drec(0, 5)]))
        XCTAssertEqual(updates.with { $0 }, 2)
        XCTAssertEqual(try find(r, "hud").pose.x, 5)
        XCTAssertTrue(try find(r, "hud").headFrame) // a delta never changes frame-ness
    }

    func testUpdatesStreamSignalsAfterAChange() async throws {
        let r = PresenceRoster()
        r.apply(group: 10, packet: kf(1, 0, [krec("a", 1)]))
        r.apply(group: 11, packet: delta(1, [drec(0, 2)])) // coalesces with the first
        var it = r.updates.makeAsyncIterator()
        let first = await it.next()
        XCTAssertNotNil(first)
        XCTAssertEqual(try find(r, "a").pose.x, 2)
        r.apply(group: 12, packet: delta(1, [drec(0, 3)]))
        let second = await it.next()
        XCTAssertNotNil(second)
        XCTAssertEqual(try find(r, "a").pose.x, 3)
    }

    func testAppliesParsedPacketsFromTheWire() throws {
        // The keyframe and delta vectors, through the parser.
        let kfBytes = PoseAndPacketTests.bytes("010702000005616c6963650000c03f000010c00000003ebe28a1ebff7f2e0107616e67656c2d31000000000000003f00000000000000000000ff")
        let dBytes = PoseAndPacketTests.bytes("000702000000c03f000010c00000003ebe28a1ebff7f2e0300000000000000003f00000000000000000000ff")
        let r = PresenceRoster()
        r.apply(group: 1, packet: try PresencePacket.parse(kfBytes))
        XCTAssertEqual(Set(r.entries.map(\.id)), ["alice", "angel-1"])
        XCTAssertEqual(try find(r, "alice").loudness, 46)
        XCTAssertTrue(try find(r, "angel-1").headFrame)
        r.apply(group: 2, packet: try PresencePacket.parse(dBytes))
        XCTAssertEqual(try find(r, "alice").pose.x, 1.5, accuracy: 1e-6)
        XCTAssertEqual(try find(r, "angel-1").loudness, Lasa.loudnessSilent)
    }
}
