// Ticket claims, decoded locally before dialling (lasa-swift.md §2.1,
// lasa-core.md §4.3, schemata/ticket.schema.json). Written 2026-11-03;
// there is no TypeScript source for this, the browser client sends the
// ticket blind. The shape mirrors lasa/connect/ticket.go, the server's
// own verifier, minus the signature: the client cannot verify it and
// does not try. The point is that the common mistakes (wrong client
// id, a ticket for another space, an expired one) fail at once with
// the code the server would give, and never cost a round trip.
//
// The claim set is closed (iss, aud, exp, nbf, iat, panaudia) and
// `aud` is the single-string form. Unknown members are left to the
// server: the local check covers only the cases §2.1 names, so it can
// never refuse a ticket the server would admit.

import Foundation

/// The decoded payload of a LASA ticket. Not verified.
public struct TicketClaims: Decodable, Equatable, Sendable {
    public struct Permissions: Decodable, Equatable, Sendable {
        public var set: [String]?
        public var clear: [String]?
        public var read: [String]?

        public init(set: [String]? = nil, clear: [String]? = nil, read: [String]? = nil) {
            self.set = set; self.clear = clear; self.read = read
        }
    }

    public struct Panaudia: Decodable, Equatable, Sendable {
        /// Must equal the Connection Config's client_id.
        public var clientID: String
        public var roles: [String]?
        public var permissions: Permissions?
        /// The signed entity definitions a config's setups instantiate.
        public var entities: [Lasa.Entity]?

        public init(clientID: String, roles: [String]? = nil, permissions: Permissions? = nil, entities: [Lasa.Entity]? = nil) {
            self.clientID = clientID; self.roles = roles; self.permissions = permissions; self.entities = entities
        }
        enum CodingKeys: String, CodingKey { case clientID = "client_id", roles, permissions, entities }
    }

    public var iss: String
    /// The space id.
    public var aud: String
    /// Epoch seconds; absent means never expires.
    public var exp: Int64?
    public var nbf: Int64?
    public var iat: Int64?
    public var panaudia: Panaudia

    public init(iss: String, aud: String, exp: Int64? = nil, nbf: Int64? = nil, iat: Int64? = nil, panaudia: Panaudia) {
        self.iss = iss; self.aud = aud; self.exp = exp; self.nbf = nbf; self.iat = iat; self.panaudia = panaudia
    }

    /// Decodes the payload of a compact JWT (header.payload.signature)
    /// without looking at the header or the signature.
    public static func decode(_ jwt: String) throws -> TicketClaims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw TicketDecodeError.notAJWT }
        guard let payload = base64URLDecode(String(parts[1])) else { throw TicketDecodeError.badBase64 }
        do {
            return try JSONDecoder().decode(TicketClaims.self, from: payload)
        } catch {
            throw TicketDecodeError.badClaims("\(error)")
        }
    }

    /// base64url without padding, as RFC 7515 §2 requires; padding is
    /// tolerated.
    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem == 1 { return nil }
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: b64)
    }
}

public enum TicketDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAJWT
    case badBase64
    case badClaims(String)

    public var description: String {
        switch self {
        case .notAJWT: return "ticket: not a JWT (expected header.payload.signature)"
        case .badBase64: return "ticket: payload is not base64url"
        case .badClaims(let why): return "ticket claims: \(why)"
        }
    }
}

/// The rejection the server would give for `jwt` presented by
/// `clientID` to `spaceID` at `now`, judged from the claims alone, or
/// nil when the local checks pass. Mirrors lasa/connect/ticket.go's
/// order: the ticket itself first (undecodable, wrong audience, expired,
/// not yet valid, issued in the future: 0x1A5A01), then the client id
/// against the claim (0x1A5A02). The signature is not checked, so a nil
/// here is not admission.
public func checkTicket(_ jwt: String, clientID: String, spaceID: String, now: Date) -> LasaRejection? {
    let claims: TicketClaims
    do {
        claims = try TicketClaims.decode(jwt)
    } catch {
        return LasaRejection(.invalidTicket, reason: "\(error)")
    }
    if claims.aud != spaceID {
        return LasaRejection(.invalidTicket, reason: "ticket: audience \(claims.aud) is not this space (\(spaceID))")
    }
    // golang-jwt's rule, which the server applies: valid while
    // now < exp, and from nbf and iat inclusive.
    let t = Int64(now.timeIntervalSince1970.rounded(.down))
    if let exp = claims.exp, t >= exp {
        return LasaRejection(.invalidTicket, reason: "ticket: expired at \(exp) (now \(t))")
    }
    if let nbf = claims.nbf, t < nbf {
        return LasaRejection(.invalidTicket, reason: "ticket: not valid before \(nbf) (now \(t))")
    }
    if let iat = claims.iat, t < iat {
        return LasaRejection(.invalidTicket, reason: "ticket: issued at \(iat), in the future (now \(t))")
    }
    if claims.panaudia.clientID != clientID {
        return LasaRejection(.clientIDMismatch, reason: "client_id \(clientID) does not match the ticket's \(claims.panaudia.clientID)")
    }
    return nil
}
