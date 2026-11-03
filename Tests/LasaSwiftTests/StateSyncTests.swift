// StateSync without a server, 2026-11-03: the lane dispatch into the
// store, and the loop's stop against a session that cannot subscribe
// (no connection), so the backoff wait and the stopped flag are
// exercised. The subscribe path itself needs the live suite.

import XCTest
@testable import LasaSwift

final class StateSyncTests: XCTestCase {
    func makeSync(_ store: Store, log: @escaping @Sendable (String) -> Void = { _ in }) -> StateSync {
        let transport = QUICTransport(log: { _ in })
        let session = MoQSession(transport: transport)
        return StateSync(session: session, spaceID: "main", clientID: "c1", store: store,
                         options: StateSyncOptions(initialBackoffMS: 10, log: log))
    }

    func testLaneDispatch() throws {
        let store = try Store(prefixes: [""])
        let sync = makeSync(store)
        let epoch: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

        // Catch-up lane is subgroup 1; live is subgroup 0.
        sync.apply(subgroupID: 1, try StateWire.encodeStateMessage(.begin(.snapshot), .downstream))
        sync.apply(subgroupID: 1, try StateWire.encodeStateMessage(.set(key: "a", value: [1], seq: 1), .downstream))
        sync.apply(subgroupID: 0, try StateWire.encodeStateMessage(.set(key: "b", value: [2], seq: 2), .downstream))
        sync.apply(subgroupID: 1, try StateWire.encodeStateMessage(.frontier(epoch: epoch, seq: 1), .downstream))

        XCTAssertEqual(store.get("a"), [1])
        XCTAssertEqual(store.get("b"), [2])
        XCTAssertEqual(store.subscribeParams().cursor, Cursor(epoch: epoch, seq: 1, setHash: store.prefixSetHash))

        // A catch-up entry outside a window, and a malformed object, are
        // logged and dropped, not fatal.
        sync.apply(subgroupID: 1, try StateWire.encodeStateMessage(.set(key: "c", value: [3], seq: 3), .downstream))
        sync.apply(subgroupID: 0, [9, 9, 9])
        XCTAssertNil(store.get("c"))
        XCTAssertEqual(store.count, 2)
    }

    func testStopEndsTheLoopPromptly() async throws {
        let store = try Store(prefixes: [""])
        let lines = Locked<[String]>([])
        let sync = makeSync(store) { l in lines.with { $0.append(l) } }
        sync.start()
        sync.start() // idempotent
        // Let the loop fail its first subscribe and enter the backoff wait.
        try await Task.sleep(for: .milliseconds(50))
        sync.stop()
        await sync.join()
        XCTAssertNil(sync.currentInstance)
        XCTAssertTrue(lines.with { $0 }.contains { $0.contains("sync error") })
    }

    func testStartAfterStopDoesNothing() async throws {
        let store = try Store(prefixes: [""])
        let sync = makeSync(store)
        sync.stop()
        sync.start()
        await sync.join()
        XCTAssertNil(sync.currentInstance)
    }
}
