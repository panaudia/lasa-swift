// The §2 surface against a live server: options, connect, roster,
// state sync into a Store, an entity publisher sending pose-only
// packets, and a base-profile write. Skips without PROBE_LIVE
// (host:port). 2026-11-03.

import XCTest
@testable import LasaSwift

@available(iOS 26.0, macOS 26.0, *)
final class ClientSurfaceLiveTests: XCTestCase {
    func testRosterStateAndPublisher() async throws {
        guard let addr = ProcessInfo.processInfo.environment["PROBE_LIVE"] else { throw XCTSkip("PROBE_LIVE") }
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        var o = LasaClientOptions(address: addr, clientID: "swift-surface-\(stamp)")
        o.entities = [Lasa.Entity(id: "swift-surface-\(stamp)-ears", name: "surface ears", hears: ["main"]),
                      Lasa.Entity(id: "swift-surface-\(stamp)-mic", name: "surface mic", heardIn: ["swift-surface-\(stamp)-private"])]
        o.log = { print("[surface] \($0)") }
        let client = LasaClient(o)
        try await client.connect()
        defer { client.close() }
        XCTAssertNotNil(client.handshake)

        // Roster: our own entities appear within a keyframe round.
        let roster = try await client.subscribeRoster()
        var seen = false
        for _ in 0..<40 {
            if roster.entries.contains(where: { $0.id == "swift-surface-\(stamp)-ears" }) { seen = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(seen, "own entity in the roster; entries: \(roster.entries.map(\.id))")

        // State: the sync fills the store with our entity marker.
        let store = try Store(prefixes: ["lasa.entity.swift-surface-\(stamp)"])
        let sync = client.syncState(store, options: StateSyncOptions(log: { print("[surface] \($0)") }))
        sync.start()
        var marker: [UInt8]? = nil
        for _ in 0..<40 {
            marker = store.get("lasa.entity.swift-surface-\(stamp)-ears")
            if marker != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(marker, "entity marker key synced; store keys: \(store.keys)")

        // A base-profile write through the publisher, echoed into the store.
        let ears = try await client.entity("swift-surface-\(stamp)-ears")
        try await ears.setAttr("colour", "teal")
        var attr: BaseValue? = nil
        for _ in 0..<40 {
            attr = decodeValue(store.get("lasa.entity.swift-surface-\(stamp)-ears.attrs.colour"))
            if attr != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(attr, .string("teal"))

        // Pose-only packets: a silent entity sends on change, throttled.
        for i in 0..<10 {
            ears.setPose(Pose(x: 0, y: 0, z: 0, yaw: Float(i) * 0.1, pitch: 0, roll: 0))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThanOrEqual(ears.sent, 2, "pose-only packets went out")
        XCTAssertLessThanOrEqual(ears.sent, 8, "throttled to the 33 ms tick")
        XCTAssertEqual(ears.sendErrors, 0)
        sync.stop()
    }
}
