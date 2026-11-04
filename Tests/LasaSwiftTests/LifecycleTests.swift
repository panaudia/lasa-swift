// §4's background rule on the client, without a server: a lifecycle
// object the test drives. With no engine attached, entering the
// background closes the session (backgrounded, then closed); becoming
// active again on a closed session emits nothing.

import XCTest
@testable import LasaSwift

final class FakeLifecycle: AppLifecycle, @unchecked Sendable {
    let transitions: AsyncStream<AppTransition>
    let cont: AsyncStream<AppTransition>.Continuation
    let holds = OSAllocatedUnfairLockBox<[String]>([])
    init() {
        (transitions, cont) = AsyncStream<AppTransition>.makeStream()
    }
    @MainActor func hold(for name: String) -> BackgroundHold? {
        holds.set(holds.get() + [name])
        return Hold()
    }
    final class Hold: BackgroundHold { func end() {} }
}

final class LifecycleTests: XCTestCase {
    func testBackgroundWithoutEngineClosesTheSession() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        let lc = FakeLifecycle()
        var o = LasaClientOptions(address: "127.0.0.1:1", clientID: "c")
        o.lifecycle = lc
        let c = LasaClient(o)
        c.watch(lc)
        lc.cont.yield(.didEnterBackground)
        var got: [String] = []
        for await e in c.events {
            switch e {
            case .backgrounded: got.append("backgrounded")
            case .closed(let code, _): got.append("closed(\(code.map(String.init) ?? "-"))")
            default: got.append("other")
            }
            if got.count == 2 { break }
        }
        XCTAssertEqual(got, ["backgrounded", "closed(-)"])
        XCTAssertEqual(lc.holds.get(), ["lasa background close"])
        XCTAssertNotNil(c.session.closedError)
    }

    func testBackgroundWithEngineRunningDoesNothing() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        let lc = FakeLifecycle()
        var o = LasaClientOptions(address: "127.0.0.1:1", clientID: "c")
        o.lifecycle = lc
        let c = LasaClient(o)
        c.setEngineHooks(.init(isRunning: { true }, isInterrupted: { false }, resume: {}))
        c.watch(lc)
        lc.cont.yield(.didEnterBackground)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(c.session.closedError)
        XCTAssertEqual(lc.holds.get(), [])
    }

    func testForegroundWhileInterruptedResumesTheEngine() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 required") }
        let lc = FakeLifecycle()
        var o = LasaClientOptions(address: "127.0.0.1:1", clientID: "c")
        o.lifecycle = lc
        let c = LasaClient(o)
        let resumed = OSAllocatedUnfairLockBox<Int>(0)
        c.setEngineHooks(.init(isRunning: { false }, isInterrupted: { true }, resume: { resumed.set(resumed.get() + 1) }))
        c.watch(lc)
        lc.cont.yield(.didBecomeActive)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(resumed.get(), 1)
    }
}
