// A value behind a lock, for counters the receive loops bump. Package
// internal; the public API never exposes it.

import Foundation

/// A value behind a lock, for counters the receive loops bump.
package final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    package init(_ v: T) { self.v = v }
    package func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&v) }
}

