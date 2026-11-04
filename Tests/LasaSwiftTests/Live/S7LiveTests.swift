// S7, keep-alive and NAT (tests plan §5.10), from this Mac against a
// live server: a session with no track traffic at all (no sink, no
// presence; the entity's source is silent) held idle past both sides'
// 30 s idle timeout, once with the framework's QUIC keep-alive at 5 s
// and once without. The first must still answer a probe; the second's
// death is observed and timed. The device repeat is the example app's
// "sink: none" mode with the keep-alive stepper.
//
//   PROBE_LIVE=test.panaudia.com:443 S7_LIVE=1 swift test --filter S7LiveTests
//   S7_LIVE_SECS=<n> sets the idle hold (default 50; the plan's run is 600).

import XCTest
@testable import LasaSwift

final class S7LiveTests: XCTestCase {
    var address: String? { ProcessInfo.processInfo.environment["PROBE_LIVE"] }
    var holdSeconds: Int { Int(ProcessInfo.processInfo.environment["S7_LIVE_SECS"] ?? "") ?? 50 }

    @available(macOS 26.0, *)
    private func client(keepAlive: Int) -> LasaClient {
        var o = LasaClientOptions(address: address!, spaceID: "main", clientID: "s7-" + String(UUID().uuidString.prefix(8)).lowercased())
        o.entities = [Lasa.Entity(id: o.clientID + "-me", name: "s7", hears: ["main"], heardIn: ["main"])]
        o.keepAliveSeconds = keepAlive
        o.log = { print("[s7 ka=\(keepAlive)] \($0)") }
        return LasaClient(o)
    }

    /// A SUBSCRIBE the server must refuse: a round trip with no side
    /// effect, the client's own resume probe.
    @available(macOS 26.0, *)
    private func probe(_ c: LasaClient) async -> String {
        do {
            _ = try await c.session.subscribe(namespace: Lasa.presenceNamespace(space: "main"), track: "lasa-probe")
            return "alive (accepted?)"
        } catch is MoQ.SubscribeError {
            return "alive"
        } catch {
            return "dead: \(error)"
        }
    }

    @available(macOS 26.0, *)
    private func hold(keepAlive: Int) async throws -> (verdict: String, closedAfterS: Double?) {
        let c = client(keepAlive: keepAlive)
        try await c.connect()
        let t0 = Date()
        let closedAt = OSAllocatedUnfairLockBox<Double?>(nil)
        let watcher = Task {
            for await e in c.events {
                if case .closed(let code, let reason) = e {
                    closedAt.set(Date().timeIntervalSince(t0))
                    print("[s7 ka=\(keepAlive)] closed after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s code=\(code.map { String($0, radix: 16) } ?? "-") \(reason ?? "")")
                }
            }
        }
        print("[s7 ka=\(keepAlive)] connected, holding \(holdSeconds) s with no track traffic (remote idle \(c.handshake?.remoteIdleTimeoutMS ?? 0) ms)")
        try await Task.sleep(nanoseconds: UInt64(holdSeconds) * 1_000_000_000)
        let v = c.session.closedError == nil ? await probe(c) : "dead: \(c.session.closedError!)"
        print("[s7 ka=\(keepAlive)] after \(holdSeconds) s: \(v)")
        watcher.cancel()
        c.close()
        return (v, closedAt.get())
    }

    func testKeepAliveFiveSecondsSurvivesIdle() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        guard address != nil, ProcessInfo.processInfo.environment["S7_LIVE"] == "1" else { throw XCTSkip("set PROBE_LIVE and S7_LIVE=1") }
        let r = try await hold(keepAlive: 5)
        XCTAssertEqual(r.verdict, "alive", "with keep-alive 5 s the idle session must survive \(holdSeconds) s")
        XCTAssertNil(r.closedAfterS)
    }

    func testNoKeepAliveDiesAtIdleTimeout() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        guard address != nil, ProcessInfo.processInfo.environment["S7_LIVE"] == "1" else { throw XCTSkip("set PROBE_LIVE and S7_LIVE=1") }
        let r = try await hold(keepAlive: 0)
        // Observed and timed, not asserted dead: the plan wants the fact.
        print("[s7 ka=0] verdict \(r.verdict), closed after \(r.closedAfterS.map { String(format: "%.1f s", $0) } ?? "never")")
    }
}

/// A boxed value for the watcher task.
final class OSAllocatedUnfairLockBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
}
