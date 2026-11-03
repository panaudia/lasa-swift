// Ticket decoding and the local checks before dialling (lasa-swift.md
// §2.1). Written 2026-11-03. The sample ticket carries the claims of
// lasa/tickets' create_ticket samples (the README's fixed-value
// example) with iat 1700000000, nbf iat - 60, exp iat + 86400, signed
// with a throwaway Ed25519 key (public key, base64 of the raw bytes:
// 6zFOUQeg4VBho6vUbnyJ49vW3lzJTnWBxmajRjyL3wM=). The client never
// verifies the signature, so the key does not matter here.
import XCTest
@testable import LasaSwift

final class TicketTests: XCTestCase {
    static let sampleSpace = "df8c7a85-0702-45e9-a626-a1c147eafce9"
    static let sampleClient = "6f1c2d3e-8a4b-4c5d-9e0f-1a2b3c4d5e6f"
    static let sampleIat: Int64 = 1_700_000_000
    static let sampleTicket = "eyJhbGciOiJFZERTQSIsImNydiI6IkVkMjU1MTkiLCJ0eXAiOiJKV1QifQ.eyJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMDA4NjQwMCwibmJmIjoxNjk5OTk5OTQwLCJpc3MiOiJteS1hcHAiLCJhdWQiOiJkZjhjN2E4NS0wNzAyLTQ1ZTktYTYyNi1hMWMxNDdlYWZjZTkiLCJwYW5hdWRpYSI6eyJjbGllbnRfaWQiOiI2ZjFjMmQzZS04YTRiLTRjNWQtOWUwZi0xYTJiM2M0ZDVlNmYiLCJyb2xlcyI6WyJwcmVzZW50ZXIiXSwicGVybWlzc2lvbnMiOnsic2V0IjpbIm15YXBwLiJdLCJjbGVhciI6WyJteWFwcC4iXSwicmVhZCI6WyJteWFwcC4iXX0sImVudGl0aWVzIjpbeyJpZCI6ImExYjJjM2Q0LTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMSIsIm5hbWUiOiJQYXVsIiwicHJpb3JpdHkiOnRydWUsImhlYXJkLWluIjpbIm1haW4iXSwiaGVhcnMiOlsibWFpbiJdLCJhdHRycyI6eyJjb2xvdXIiOiIwMGFhZmYifSwicmVuZGVyIjp7ImdhaW4iOjEuNSwiYXR0ZW51YXRpb24iOjIuMH19XX19.bOvlkUESvEfcmGOshRGYUbT5dg5yAl8TeMkNkc2o16bGANz1ZWUH4Ds0yhPsIH9Nibvy-MOrsXolfnOnAKg1Dg"

    /// A moment inside the sample's validity window.
    static let inWindow = Date(timeIntervalSince1970: TimeInterval(sampleIat + 3600))

    /// An unsigned compact JWT over `payload` (a dummy signature; the
    /// client never checks it).
    static func token(_ payload: String) -> String {
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFZERTQSJ9.\(b64).c2ln"
    }

    func testSampleTicketDecodesToItsClaims() throws {
        let c = try TicketClaims.decode(Self.sampleTicket)
        let expected = TicketClaims(
            iss: "my-app", aud: Self.sampleSpace,
            exp: Self.sampleIat + 86_400, nbf: Self.sampleIat - 60, iat: Self.sampleIat,
            panaudia: .init(
                clientID: Self.sampleClient,
                roles: ["presenter"],
                permissions: .init(set: ["myapp."], clear: ["myapp."], read: ["myapp."]),
                entities: [Lasa.Entity(
                    id: "a1b2c3d4-0000-0000-0000-000000000001", name: "Paul",
                    hears: ["main"], heardIn: ["main"], attrs: ["colour": .string("00aaff")],
                    priority: true, render: .init(gain: 1.5, attenuation: 2.0))]))
        XCTAssertEqual(c, expected)
    }

    func testDecodeToleratesOptionalClaimsAbsent() throws {
        let c = try TicketClaims.decode(Self.token(#"{"iss":"x","aud":"s","panaudia":{"client_id":"c"}}"#))
        XCTAssertEqual(c, TicketClaims(iss: "x", aud: "s", panaudia: .init(clientID: "c")))
        XCTAssertNil(c.exp); XCTAssertNil(c.nbf); XCTAssertNil(c.iat)
        XCTAssertNil(c.panaudia.roles); XCTAssertNil(c.panaudia.permissions); XCTAssertNil(c.panaudia.entities)
    }

    func testDecodeRefusesNonTickets() {
        XCTAssertThrowsError(try TicketClaims.decode("")) { XCTAssertEqual($0 as? TicketDecodeError, .notAJWT) }
        XCTAssertThrowsError(try TicketClaims.decode("a.b")) { XCTAssertEqual($0 as? TicketDecodeError, .notAJWT) }
        XCTAssertThrowsError(try TicketClaims.decode("a.b.c.d")) { XCTAssertEqual($0 as? TicketDecodeError, .notAJWT) }
        XCTAssertThrowsError(try TicketClaims.decode("a.!!!!!.c")) { XCTAssertEqual($0 as? TicketDecodeError, .badBase64) }
        // Required claims missing: aud, then panaudia, then client_id, then an array aud.
        XCTAssertThrowsError(try TicketClaims.decode(Self.token(#"{"iss":"x","panaudia":{"client_id":"c"}}"#)))
        XCTAssertThrowsError(try TicketClaims.decode(Self.token(#"{"iss":"x","aud":"s"}"#)))
        XCTAssertThrowsError(try TicketClaims.decode(Self.token(#"{"iss":"x","aud":"s","panaudia":{}}"#)))
        XCTAssertThrowsError(try TicketClaims.decode(Self.token(#"{"iss":"x","aud":["s"],"panaudia":{"client_id":"c"}}"#)))
    }

    func testBase64URLDecoding() {
        XCTAssertEqual(TicketClaims.base64URLDecode("YQ"), Data("a".utf8))
        XCTAssertEqual(TicketClaims.base64URLDecode("YWI"), Data("ab".utf8))
        XCTAssertEqual(TicketClaims.base64URLDecode("YWJj"), Data("abc".utf8))
        XCTAssertEqual(TicketClaims.base64URLDecode("YQ=="), Data("a".utf8), "padding tolerated")
        XCTAssertEqual(TicketClaims.base64URLDecode("-_8"), Data([0xFB, 0xFF]), "url alphabet")
        XCTAssertNil(TicketClaims.base64URLDecode("YQdd?"))
        XCTAssertNil(TicketClaims.base64URLDecode("Y"), "one trailing sextet is not a byte")
    }

    // MARK: The local checks

    func testLocalChecksPassForTheSample() {
        XCTAssertNil(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace, now: Self.inWindow))
        // The window edges, as golang-jwt judges them: from nbf and iat
        // inclusive, to exp exclusive.
        XCTAssertNil(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace,
                                 now: Date(timeIntervalSince1970: TimeInterval(Self.sampleIat))))
        XCTAssertNil(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace,
                                 now: Date(timeIntervalSince1970: TimeInterval(Self.sampleIat + 86_400 - 1))))
    }

    func testClientIDMismatchIs1A5A02() {
        let r = checkTicket(Self.sampleTicket, clientID: "someone-else", spaceID: Self.sampleSpace, now: Self.inWindow)
        XCTAssertEqual(r?.code, 0x1A5A02)
        XCTAssertEqual(r?.rejectionCode, .clientIDMismatch)
    }

    func testWrongAudienceIs1A5A01() {
        let r = checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: "another-space", now: Self.inWindow)
        XCTAssertEqual(r?.code, 0x1A5A01)
        XCTAssertEqual(r?.rejectionCode, .invalidTicket)
    }

    func testExpiredIs1A5A01() {
        let atExp = Date(timeIntervalSince1970: TimeInterval(Self.sampleIat + 86_400))
        XCTAssertEqual(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace, now: atExp)?.code, 0x1A5A01)
        let later = Date(timeIntervalSince1970: TimeInterval(Self.sampleIat + 10 * 86_400))
        XCTAssertEqual(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace, now: later)?.code, 0x1A5A01)
    }

    func testNotYetValidIs1A5A01() {
        let beforeNbf = Date(timeIntervalSince1970: TimeInterval(Self.sampleIat - 61))
        XCTAssertEqual(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace, now: beforeNbf)?.code, 0x1A5A01)
        // Between nbf and iat: iat is enforced when present, as the server does.
        let beforeIat = Date(timeIntervalSince1970: TimeInterval(Self.sampleIat - 1))
        XCTAssertEqual(checkTicket(Self.sampleTicket, clientID: Self.sampleClient, spaceID: Self.sampleSpace, now: beforeIat)?.code, 0x1A5A01)
    }

    func testTicketWithoutTimesNeverExpires() {
        let t = Self.token(#"{"iss":"x","aud":"s","panaudia":{"client_id":"c"}}"#)
        XCTAssertNil(checkTicket(t, clientID: "c", spaceID: "s", now: Date(timeIntervalSince1970: 4_000_000_000)))
        XCTAssertNil(checkTicket(t, clientID: "c", spaceID: "s", now: Date(timeIntervalSince1970: 0)))
    }

    func testUndecodableTicketIs1A5A01() {
        XCTAssertEqual(checkTicket("not-a-jwt", clientID: "c", spaceID: "s", now: Self.inWindow)?.code, 0x1A5A01)
        XCTAssertEqual(checkTicket(Self.token("{}"), clientID: "c", spaceID: "s", now: Self.inWindow)?.code, 0x1A5A01)
    }

    func testTicketChecksPrecedeTheClientIDCheck() {
        // Expired and for another client: the server's verifier fails
        // the ticket before the config is matched against it.
        let later = Date(timeIntervalSince1970: TimeInterval(Self.sampleIat + 10 * 86_400))
        XCTAssertEqual(checkTicket(Self.sampleTicket, clientID: "someone-else", spaceID: Self.sampleSpace, now: later)?.code, 0x1A5A01)
        XCTAssertEqual(checkTicket(Self.sampleTicket, clientID: "someone-else", spaceID: "elsewhere", now: Self.inWindow)?.code, 0x1A5A01)
    }
}
