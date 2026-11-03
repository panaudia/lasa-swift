// The §4.6 rejection codes and LasaRejection. Ports the LASA parts of
// lasa/typescript/tests/worker-transport.test.ts ("LASA rejection
// surfacing") on 2026-11-03. transport-errors.test.ts covers the MoQ
// session and subscribe error tables, which have no counterpart in
// LasaRejection.swift; it is not ported here.
import XCTest
@testable import LasaSwift

final class RejectionTests: XCTestCase {
    func testCodesAreTheSpecTable() {
        XCTAssertEqual(LasaRejectionCode.malformedConfig.rawValue, 0x1A5A00)
        XCTAssertEqual(LasaRejectionCode.invalidTicket.rawValue, 0x1A5A01)
        XCTAssertEqual(LasaRejectionCode.clientIDMismatch.rawValue, 0x1A5A02)
        XCTAssertEqual(LasaRejectionCode.idCollisionRetired.rawValue, 0x1A5A03)
        XCTAssertEqual(LasaRejectionCode.entityCollision.rawValue, 0x1A5A04)
        XCTAssertEqual(LasaRejectionCode.adHocNotPermitted.rawValue, 0x1A5A05)
        XCTAssertEqual(LasaRejectionCode.blocked.rawValue, 0x1A5A06)
        XCTAssertEqual(LasaRejectionCode.atCapacity.rawValue, 0x1A5A07)
        XCTAssertEqual(LasaRejectionCode.modeMismatch.rawValue, 0x1A5A08)
        XCTAssertEqual(LasaRejectionCode.shuttingDown.rawValue, 0x1A5A09)
        XCTAssertEqual(LasaRejectionCode.superseded.rawValue, 0x1A5A0A)
        XCTAssertEqual(LasaRejectionCode.allCases.count, 11)
    }

    func testNamesMatchTheTypeScriptTable() {
        XCTAssertEqual(lasaErrorName(0x1A5A00), "malformed connection config")
        XCTAssertEqual(lasaErrorName(0x1A5A01), "invalid or missing ticket")
        XCTAssertEqual(lasaErrorName(0x1A5A02), "client_id does not match the ticket claim")
        XCTAssertEqual(lasaErrorName(0x1A5A03), "id collision (retired code)")
        XCTAssertEqual(lasaErrorName(0x1A5A04), "entity id collides with another client's live entity")
        XCTAssertEqual(lasaErrorName(0x1A5A05), "ad-hoc entities not permitted for this ticket")
        XCTAssertEqual(lasaErrorName(0x1A5A06), "blocked")
        XCTAssertEqual(lasaErrorName(0x1A5A07), "space at capacity")
        XCTAssertEqual(lasaErrorName(0x1A5A08), "ticket presented to an unticketed space")
        XCTAssertEqual(lasaErrorName(0x1A5A09), "space shutting down")
        XCTAssertEqual(lasaErrorName(0x1A5A0A), "superseded by a newer connection")
        XCTAssertNil(lasaErrorName(0x1A5A0B))
        XCTAssertNil(lasaErrorName(0))
        XCTAssertNil(lasaErrorName(0x1A59FF))
    }

    func testIsLasaRejectionCodeIsTheRangeMinusTheRetiredCode() {
        for code in LasaRejectionCode.allCases where code != .idCollisionRetired {
            XCTAssertTrue(isLasaRejectionCode(code.rawValue), "0x\(String(code.rawValue, radix: 16))")
        }
        XCTAssertFalse(isLasaRejectionCode(0x1A5A03), "the retired code never appears on the wire")
        XCTAssertFalse(isLasaRejectionCode(0x1A59FF))
        XCTAssertFalse(isLasaRejectionCode(0x1A5A0B))
        XCTAssertFalse(isLasaRejectionCode(0))
        XCTAssertFalse(isLasaRejectionCode(0x02), "a MoQ session terminate code is not a rejection")
        XCTAssertFalse(isLasaRejectionCode(UInt32.max))
    }

    func testRejectionCarriesCodeAndAdvisoryReason() {
        let r = LasaRejection(code: 0x1A5A08, reason: "this space is unticketed; do not present a ticket")
        XCTAssertEqual(r.code, 0x1A5A08)
        XCTAssertEqual(r.reason, "this space is unticketed; do not present a ticket")
        XCTAssertEqual(r.rejectionCode, .modeMismatch)
        XCTAssertEqual(r.name, "ticket presented to an unticketed space")
        XCTAssertEqual(r.description, "LASA rejection 0x1a5a08 (ticket presented to an unticketed space): this space is unticketed; do not present a ticket")

        // The reason may be dropped; the code stands alone.
        let bare = LasaRejection(.blocked)
        XCTAssertEqual(bare.reason, "")
        XCTAssertEqual(bare.description, "LASA rejection 0x1a5a06 (blocked)")
        XCTAssertEqual(bare, LasaRejection(code: 0x1A5A06, reason: ""))

        // An unknown code still carries, named unknown.
        let odd = LasaRejection(code: 0x1A5A0B, reason: "later")
        XCTAssertNil(odd.rejectionCode)
        XCTAssertEqual(odd.description, "LASA rejection 0x1a5a0b (unknown): later")
    }

    // worker-transport.test.ts: a fail carrying a §4.6 close code becomes
    // a typed rejection; any other close code falls back to a plain error.
    func testFromCloseSurfacesOnlyLasaCodes() {
        let rej = LasaRejection.fromClose(code: 0x1A5A08, reason: "this space is unticketed; do not present a ticket")
        XCTAssertEqual(rej, LasaRejection(code: 0x1A5A08, reason: "this space is unticketed; do not present a ticket"))
        XCTAssertNil(LasaRejection.fromClose(code: 0, reason: "network sadness"))
        XCTAssertNil(LasaRejection.fromClose(code: 0x1A5A03, reason: "retired"))
        // The reason string came back empty on the probe (RejectionProbeLiveTests).
        XCTAssertEqual(LasaRejection.fromClose(code: 0x1A5A06, reason: nil), LasaRejection(.blocked))
    }

    func testRejectionIsAnError() {
        func fails() throws { throw LasaRejection(.superseded, reason: "newer connection") }
        XCTAssertThrowsError(try fails()) { e in
            XCTAssertEqual((e as? LasaRejection)?.code, 0x1A5A0A)
        }
    }
}
