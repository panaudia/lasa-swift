// Store rule tests: the resurrection guard, the snapshot deletion rule,
// invariant F7, termination, stall detection, cursor carry-over and
// epoch change. Port of lasa/typescript/tests/store.test.ts (itself the
// Go clientstore suite), 2026-11-03, plus the observer batches the
// Swift store adds.

import XCTest
@testable import LasaSwift

final class StoreTests: XCTestCase {
    static let epochA: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1]
    static let epochB: [UInt8] = [2, 2, 2, 2, 2, 2, 2, 2]

    func set(_ key: String, _ value: String, _ seq: UInt64) -> StateMessage { .set(key: key, value: Array(value.utf8), seq: seq) }
    func clear(_ key: String, _ seq: UInt64) -> StateMessage { .clear(key: key, seq: seq) }
    func begin(_ kind: BeginKind) -> StateMessage { .begin(kind) }
    func frontier(_ epoch: [UInt8], _ seq: UInt64) -> StateMessage { .frontier(epoch: epoch, seq: seq) }
    func text(_ v: [UInt8]?) -> String? { v.map { String(decoding: $0, as: UTF8.self) } }

    final class TestClock: @unchecked Sendable {
        private let t = Locked<Double>(1_800_000_000_000)
        func now() -> Double { t.with { $0 } }
        func advance(_ ms: Double) { t.with { $0 += ms } }
    }

    func newStore(_ clock: TestClock? = nil) throws -> Store {
        if let c = clock { return try Store(prefixes: [""], options: StoreOptions(clock: { c.now() })) }
        return try Store(prefixes: [""])
    }

    // The resurrection trap (lasa-core.md §6.5 note): a live clear during
    // the window, then a late catch-up chunk carrying the same key at an
    // older seq. The transient record must block it, including for keys
    // the client never held.
    func testResurrectionGuard() throws {
        let s = try newStore()
        try s.applyCatchUp(begin(.delta))

        // Live: key created at 980 elsewhere, cleared at 1005; never held.
        try s.applyLive(clear("app.k", 1005))
        // Late catch-up chunk carries the stale set at 980.
        try s.applyCatchUp(set("app.k", "stale", 980))
        XCTAssertNil(s.get("app.k"))
        // A genuinely newer live set still wins.
        try s.applyLive(set("app.k", "new", 1010))
        XCTAssertEqual(text(s.get("app.k")), "new")
        try s.applyCatchUp(frontier(Self.epochA, 1100))
    }

    // Snapshot rule 3: on completion, delete every in-scope local key
    // absent from the snapshot whose seq is at or below the cut H; keys
    // set live during the window (seq > H) survive.
    func testSnapshotDeletionRule() throws {
        let s = try newStore()
        // Stale local state from a previous subscription instance.
        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(set("old.a", "x", 5))
        try s.applyCatchUp(set("old.b", "y", 8))
        try s.applyCatchUp(frontier(Self.epochA, 8))
        s.terminated()

        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(set("old.a", "fresh", 20))
        // Live op lands mid-window for a key the snapshot does not carry.
        try s.applyLive(set("live.c", "live", 40))
        try s.applyCatchUp(frontier(Self.epochA, 30))

        XCTAssertNil(s.get("old.b"))
        XCTAssertEqual(text(s.get("old.a")), "fresh")
        XCTAssertNotNil(s.get("live.c"))
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(Set(s.keys), ["old.a", "live.c"])
    }

    // Invariant F7: live frontiers arriving before the catch-up frontier
    // must not earn a cursor; the store is not at a provable cut.
    func testNoCursorBeforeFirstCatchUpFrontier() throws {
        let s = try newStore()
        try s.applyCatchUp(begin(.snapshot))
        try s.applyLive(frontier(Self.epochA, 500)) // live frontier first

        XCTAssertNil(s.subscribeParams().cursor)

        try s.applyCatchUp(frontier(Self.epochA, 300))
        let cur = try XCTUnwrap(s.subscribeParams().cursor)
        XCTAssertEqual(cur.seq, 500) // max across both paths
        XCTAssertEqual(cur.epoch, Self.epochA)
    }

    // Subscription termination mid-window: transient records belong to
    // the dead instance and are discarded; eligibility resets.
    func testTerminatedDiscardsWindow() throws {
        let s = try newStore()
        try s.applyCatchUp(begin(.delta))
        try s.applyLive(clear("app.k", 100))
        s.terminated()

        // New instance: fresh window; the old transient must not block a
        // legitimate snapshot entry.
        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(set("app.k", "v", 90))
        XCTAssertEqual(text(s.get("app.k")), "v")
    }

    func testCatchUpStallDetection() throws {
        let clk = TestClock()
        let s = try newStore(clk)
        XCTAssertFalse(s.catchUpStalled(deadlineMS: 1000))
        try s.applyCatchUp(begin(.delta))
        clk.advance(2000)
        XCTAssertTrue(s.catchUpStalled(deadlineMS: 1000))
    }

    // The cursor and entries carry over a subscription instance ending: a
    // re-subscribe (StateSync's retry, or a new client handed the same
    // store) presents the earned cursor, stamped with the store's
    // set-hash, and can land on a delta. Eligibility alone resets.
    func testCursorSurvivesTerminationForNextInstance() throws {
        let s = try newStore()
        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(set("app.k", "v", 7))
        try s.applyCatchUp(frontier(Self.epochA, 10))
        s.terminated()

        XCTAssertEqual(text(s.get("app.k")), "v")
        let c = try XCTUnwrap(s.subscribeParams().cursor)
        XCTAssertEqual(c.seq, 10)
        XCTAssertEqual(c.epoch, Self.epochA)
        XCTAssertEqual(c.setHash.count, 32)
        XCTAssertEqual(c.setHash, try StateWire.setHash([""]))

        // The new instance must earn its own frontier before advancing it.
        try s.applyLive(frontier(Self.epochA, 50))
        XCTAssertEqual(s.subscribeParams().cursor?.seq, 10)
        try s.applyCatchUp(begin(.delta))
        try s.applyCatchUp(frontier(Self.epochA, 40))
        XCTAssertEqual(s.subscribeParams().cursor?.seq, 50)
    }

    // An epoch change invalidates the cursor; the new epoch's frontier
    // earns a fresh one.
    func testEpochChangeInvalidatesCursor() throws {
        let s = try newStore()
        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(frontier(Self.epochA, 10))
        XCTAssertNotNil(s.subscribeParams().cursor)

        s.terminated() // reconnect
        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(frontier(Self.epochB, 3))
        let c = try XCTUnwrap(s.subscribeParams().cursor)
        XCTAssertEqual(c.epoch, Self.epochB)
        XCTAssertEqual(c.seq, 3)
    }

    // MARK: catch-up ordering errors

    func testRejectsEntriesAndFrontiersBeforeBegin() throws {
        let s = try newStore()
        XCTAssertThrowsError(try s.applyCatchUp(set("k", "v", 1))) { XCTAssertTrue("\($0)".contains("before begin")) }
        XCTAssertThrowsError(try s.applyCatchUp(frontier(Self.epochA, 1))) { XCTAssertTrue("\($0)".contains("before begin")) }
    }

    // MARK: Swift additions

    func testLaneMisuseIsAnError() throws {
        let s = try newStore()
        XCTAssertThrowsError(try s.applyLive(begin(.delta)))
        XCTAssertThrowsError(try s.applyCatchUp(.group([])))
        XCTAssertThrowsError(try Store(prefixes: ["Bad"]))
    }

    func testSubscribeParamsAreCanonical() throws {
        let s = try Store(prefixes: ["lasa.space.", "lasa.entity.", "lasa.space."])
        XCTAssertEqual(s.subscribeParams().prefixes, ["lasa.entity.", "lasa.space."])
        XCTAssertEqual(s.prefixSetHash, try StateWire.setHash(["lasa.entity.", "lasa.space."]))
    }

    func testObserversSeeOneBatchPerMessage() throws {
        let s = try newStore()
        let batches = Locked<[[Store.Change]]>([])
        let obs = s.observe { b in batches.with { $0.append(b) } }

        try s.applyLive(.group([
            .set(SetOp(key: "a", value: [1], seq: 1)),
            .set(SetOp(key: "b", value: [2], seq: 2)),
        ]))
        try s.applyLive(set("a", "x", 0))      // deduped: no batch
        try s.applyLive(clear("zz", 9))        // never held: no batch
        try s.applyLive(clear("a", 3))
        try s.applyCatchUp(begin(.snapshot))
        try s.applyCatchUp(frontier(Self.epochA, 5)) // rule 3 removes b (seq 2 <= 5)

        let got = batches.with { $0 }
        XCTAssertEqual(got, [
            [Store.Change(key: "a", value: [1], seq: 1), Store.Change(key: "b", value: [2], seq: 2)],
            [Store.Change(key: "a", value: nil, seq: 3)],
            [Store.Change(key: "b", value: nil, seq: 5)],
        ])

        obs.cancel()
        try s.applyLive(set("c", "v", 10))
        XCTAssertEqual(batches.with { $0.count }, 3)
        XCTAssertEqual(s.entry("c"), KV(value: Array("v".utf8), seq: 10))
    }

    func testChangeStreamYieldsBatches() async throws {
        let s = try newStore()
        let stream = s.changes()
        var it = stream.makeAsyncIterator()
        try s.applyLive(set("a", "v", 1))
        let first = await it.next()
        XCTAssertEqual(first, [Store.Change(key: "a", value: Array("v".utf8), seq: 1)])
    }
}
