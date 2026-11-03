// LASA session rejection codes (lasa-core.md §4.6) and the error that
// surfaces them. Ported from lasa/typescript/src/lasa/errors.ts on
// 2026-11-03. A rejection is a deliberate close of the session: the
// code rides the QUIC CONNECTION_CLOSE application error, and
// correctness rides the code alone. The reason string is advisory and
// may be truncated or dropped (C-4.6-3).
//
// Divergence from the TypeScript: the codes are a UInt32 enum rather
// than a const object, and LasaRejection keeps a raw UInt32 `code` so
// an unknown-but-in-range code the server may add later still carries.

import Foundation

/// Session error codes, lasa-core.md §4.6 / §9.
public enum LasaRejectionCode: UInt32, CaseIterable, Sendable {
    /// Malformed or schema-invalid Connection Config.
    case malformedConfig = 0x1A5A00
    /// Invalid ticket (signature, expired, not yet valid, wrong
    /// audience), or no ticket presented to a ticketed space.
    case invalidTicket = 0x1A5A01
    /// client_id does not match the ticket claim.
    case clientIDMismatch = 0x1A5A02
    /// Retired 2026-08-13 (unticketed collisions now supersede); never
    /// reused and never on the wire.
    case idCollisionRetired = 0x1A5A03
    /// Entity id collides with another client's live entity (ticketed).
    case entityCollision = 0x1A5A04
    /// Ad-hoc entities not permitted for this ticket.
    case adHocNotPermitted = 0x1A5A05
    /// Blocked (the reason string should carry the block expiry).
    case blocked = 0x1A5A06
    /// Space at capacity.
    case atCapacity = 0x1A5A07
    /// Ticket presented to an unticketed space (mode mismatch).
    case modeMismatch = 0x1A5A08
    /// The space is shutting down deliberately; reconnecting later is reasonable.
    case shuttingDown = 0x1A5A09
    /// Superseded by a newer connection exercising the same client id (§4.4).
    case superseded = 0x1A5A0A

    /// The human-readable name, the same strings as the TypeScript table.
    public var name: String {
        switch self {
        case .malformedConfig: return "malformed connection config"
        case .invalidTicket: return "invalid or missing ticket"
        case .clientIDMismatch: return "client_id does not match the ticket claim"
        case .idCollisionRetired: return "id collision (retired code)"
        case .entityCollision: return "entity id collides with another client's live entity"
        case .adHocNotPermitted: return "ad-hoc entities not permitted for this ticket"
        case .blocked: return "blocked"
        case .atCapacity: return "space at capacity"
        case .modeMismatch: return "ticket presented to an unticketed space"
        case .shuttingDown: return "space shutting down"
        case .superseded: return "superseded by a newer connection"
        }
    }
}

/// True iff `code` is a LASA session-rejection code a server may issue:
/// the §4.6 range minus the retired 0x1A5A03, which must never appear
/// on the wire.
public func isLasaRejectionCode(_ code: UInt32) -> Bool {
    code >= LasaRejectionCode.malformedConfig.rawValue
        && code <= LasaRejectionCode.superseded.rawValue
        && code != LasaRejectionCode.idCollisionRetired.rawValue
}

/// Human-readable name for a §4.6 code; nil outside the range.
public func lasaErrorName(_ code: UInt32) -> String? {
    LasaRejectionCode(rawValue: code)?.name
}

/// A LASA session rejection: the server deliberately closed the session
/// with a §4.6 code. `code` is normative; `reason` is advisory and may
/// be empty.
public struct LasaRejection: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: UInt32
    public let reason: String

    public init(code: UInt32, reason: String = "") {
        self.code = code
        self.reason = reason
    }

    public init(_ code: LasaRejectionCode, reason: String = "") {
        self.init(code: code.rawValue, reason: reason)
    }

    /// The rejection a session close carries, or nil when the close code
    /// is not a LASA code (a transport failure or a MoQ terminate is
    /// reported as what it is, not as a rejection).
    public static func fromClose(code: UInt32, reason: String?) -> LasaRejection? {
        guard isLasaRejectionCode(code) else { return nil }
        return LasaRejection(code: code, reason: reason ?? "")
    }

    /// The tabled code, nil for a code outside the table.
    public var rejectionCode: LasaRejectionCode? { LasaRejectionCode(rawValue: code) }

    /// The name of the code, nil outside the table.
    public var name: String? { lasaErrorName(code) }

    /// The same message the TypeScript error carries.
    public var description: String {
        "LASA rejection 0x\(String(code, radix: 16)) (\(name ?? "unknown"))" + (reason.isEmpty ? "" : ": \(reason)")
    }
}
