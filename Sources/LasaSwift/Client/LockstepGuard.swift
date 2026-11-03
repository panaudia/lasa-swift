// The lockstep guard: assertLockstepSupported from
// lasa/typescript/src/lasa/setup.ts, ported 2026-11-03. The client
// carries the declaration but cannot honour it for more than one
// entity: its uplink runs one capture and one counter per entity, so
// two entities cannot share a frame index (lasa-core.md §5.2,
// plan/lockstep.md §4.3, lasa-swift.md §5 rule 12). Connect refuses
// that shape before dialling rather than letting an app declare an
// obligation it would silently violate. With zero or one entity the
// flag has no effect and passes.
//
// Divergence: a typed error instead of a plain Error with a message;
// the message text is the TypeScript one.

import Foundation

/// Thrown by `assertLockstepSupported` for a lockstep config naming
/// more than one entity.
public struct LockstepUnsupported: Error, Equatable, Sendable, CustomStringConvertible {
    /// Entities plus setups the config instantiates.
    public let entityCount: Int

    public init(entityCount: Int) { self.entityCount = entityCount }

    public var description: String {
        "lockstep with \(entityCount) entities is not supported by this client: its uplink runs one capture and one counter per entity, so the tracks cannot share a frame index (plan/lockstep.md). Use the bridge for multi-channel lockstep, or declare one entity."
    }
}

/// Throws `LockstepUnsupported` when `cfg` declares lockstep over more
/// than one entity, counting `entities` and `setups` together. Passes
/// without the flag, and with the flag over zero or one entity.
public func assertLockstepSupported(_ cfg: Lasa.ConnectionConfig) throws {
    guard cfg.lockstep == true else { return }
    let n = (cfg.entities?.count ?? 0) + (cfg.setups?.count ?? 0)
    if n > 1 { throw LockstepUnsupported(entityCount: n) }
}

extension Lasa.ConnectionConfig {
    /// `assertLockstepSupported(self)`.
    public func assertLockstepSupported() throws {
        try LasaSwift.assertLockstepSupported(self)
    }
}
