// A LASA rejection code reaches the client through the framework's
// applicationError (measured 2026-11-03: presenting a ticket to the
// unticketed test space fails the connection with 0x1A5A08, the mode
// mismatch of lasa-core.md §4.6). This test keeps that true. The
// reason string came back empty, so the code alone is relied on, as
// the spec requires.
import XCTest
@testable import LasaSwift

@available(iOS 26.0, macOS 26.0, *)
final class RejectionProbeLiveTests: XCTestCase {
    func testModeMismatchCode() async throws {
        guard let addr = ProcessInfo.processInfo.environment["PROBE_LIVE"] else { throw XCTSkip("PROBE_LIVE") }
        let transport = QUICTransport(log: { print("[probe] \($0)") })
        let session = MoQSession(transport: transport, log: { print("[probe] \($0)") })
        var cfg = Lasa.ConnectionConfig(clientID: "swift-rej-\(Int(Date().timeIntervalSince1970) % 100000)",
                                        entities: [Lasa.Entity(id: "swift-rej-e", name: "rej")])
        cfg.ticket = "eyJhbGciOiJFZERTQSJ9.eyJhdWQiOiJtYWluIn0.c2ln"
        do {
            _ = try await session.establish(try TransportConfig(address: addr), extra: [try cfg.setupParam()], deadlineSeconds: 10)
            XCTFail("expected a rejection")
        } catch {
            print("[probe] establish threw: \(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        let ae = transport.applicationError
        print("[probe] applicationError = \(String(describing: ae))")
        XCTAssertEqual(ae?.code, 0x1A5A08, "the mode-mismatch rejection code reaches the client")
    }
}
