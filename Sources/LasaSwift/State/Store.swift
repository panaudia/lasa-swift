// The client half of the LASA state machinery (lasa-core.md §6.5 to
// §6.6): the local store, the catch-up window with the reference
// apply-live-with-transient-tombstones strategy, and the in-memory
// cursor honouring invariant F7 (no cursor until the subscription's
// first catch-up frontier is applied). Port of
// lasa/typescript/src/lasa/store.ts, 2026-11-03, itself a port of the
// Go `lasa/state/clientstore` minus persistence. Behavioural changes
// belong in Go first.
//
// The cursor lives with the store, in memory, so a re-subscription
// within the store's lifetime (StateSync's own retries, or a new
// LasaClient handed the same Store) resumes with a delta. Nothing is
// persisted across launches: a fresh process presents no cursor and
// takes a snapshot, which §6.6 permits (a client that does not persist
// its store MUST NOT persist a cursor).
//
// Threading contract. The TypeScript applies on one promise chain; here
// Store is a final class behind one unfair lock, and every method is
// synchronous and safe to call from any thread. StateSync calls the two
// apply methods from the transport's receive loop, one task per lane,
// so each lane keeps its arrival order and the lock serialises the
// lanes. Observers are invoked after the lock is released, on the
// applying thread, with the batch of changes the one message produced;
// batches from the two lanes may reach observers in an order that
// differs from their application, so an observer that needs the truth
// reads the store. Observers must not block.
//
// Divergences from the TypeScript, where the Go is the truth:
// - The transient-tombstone guard reads an absent record as seq 0, as
//   the Go map read does (`transient[key] >= seq`); the TypeScript reads
//   it as -1, so a seq-0 op during the window applies there and is
//   dropped here and in Go. Server seqs start above 0, so no wire case
//   reaches this.
// - The clock is a monotonic millisecond reading (process uptime by
//   default) rather than wall-clock Date.now(); only differences are
//   taken, for the catch-up deadline.
// - `init` throws on an invalid prefix, as `Store.create` does in
//   TypeScript (the Go validates at subscribe time instead).

import Foundation
import os

/// One stored key: the latest value and its seq.
public struct KV: Sendable, Equatable {
    public var value: [UInt8]
    public var seq: UInt64

    public init(value: [UInt8], seq: UInt64) { self.value = value; self.seq = seq }
}

public struct StoreOptions: Sendable {
    /// Clock override for the catch-up deadline: milliseconds on any
    /// monotonic scale. Default: process uptime.
    public var clock: @Sendable () -> Double

    public init(clock: (@Sendable () -> Double)? = nil) {
        self.clock = clock ?? { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    }
}

public enum StoreError: Error, Sendable, CustomStringConvertible, Equatable {
    case entryBeforeBegin
    case frontierBeforeBegin
    case unexpectedLiveMessage(String)
    case unexpectedCatchUpMessage(String)

    public var description: String {
        switch self {
        case .entryBeforeBegin: return "catch-up entry before begin"
        case .frontierBeforeBegin: return "catch-up frontier before begin"
        case .unexpectedLiveMessage(let k): return "unexpected live message \(k)"
        case .unexpectedCatchUpMessage(let k): return "unexpected catch-up message \(k)"
        }
    }
}

/// A client state store for one subscription's scope.
public final class Store: @unchecked Sendable {
    /// One key's change: `value` is the new value, or nil when the key
    /// was removed. `seq` is the op's seq, or the frontier cut for a
    /// removal by the snapshot deletion rule.
    public struct Change: Sendable, Equatable {
        public var key: String
        public var value: [UInt8]?
        public var seq: UInt64
    }

    /// The subscribe inputs for a (re)connection: the prefix set plus
    /// the cursor earned so far, if any.
    public struct SubscribeParams: Sendable, Equatable {
        public var prefixes: [String]
        public var cursor: Cursor?
    }

    public typealias Observer = @Sendable ([Change]) -> Void

    private struct State {
        var entries: [String: KV] = [:]
        var cursor: Cursor?
        // eligible: the first catch-up frontier of the current
        // subscription instance has been applied (invariant F7); until
        // then no cursor may be advanced.
        var eligible = false

        // Catch-up window state (transient-tombstone strategy).
        var inWindow = false
        var windowKind: BeginKind = .delta
        var windowStart: Double = 0
        var transient: [String: UInt64] = [:]   // key to live clear seq
        var snapshotIn: Set<String> = []        // keys delivered by the current snapshot
        var liveMaxSeq: UInt64 = 0
        var epoch: [UInt8]?

        var observers: [UInt64: Observer] = [:]
        var nextObserver: UInt64 = 0
        var changes: [Change] = []
    }

    /// The canonical prefix set this store is scoped to.
    public let prefixes: [String]
    /// The set-hash stamped on every cursor this store earns.
    public let prefixSetHash: [UInt8]
    private let clock: @Sendable () -> Double
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Creates an empty store for one prefix set. The set is
    /// canonicalized; an invalid prefix throws. A store belongs to one
    /// space: its cursor is meaningless anywhere else.
    public init(prefixes: [String], options: StoreOptions = StoreOptions()) throws {
        let canon = try StateWire.canonicalPrefixes(prefixes)
        self.prefixes = canon
        self.prefixSetHash = try StateWire.setHash(canon)
        self.clock = options.clock
    }

    // MARK: Reading

    public func subscribeParams() -> SubscribeParams {
        state.withLock { SubscribeParams(prefixes: prefixes, cursor: $0.cursor) }
    }

    /// The latest value for `key`, or nil.
    public func get(_ key: String) -> [UInt8]? {
        state.withLock { $0.entries[key]?.value }
    }

    /// The latest value and seq for `key`, or nil.
    public func entry(_ key: String) -> KV? {
        state.withLock { $0.entries[key] }
    }

    /// Number of keys held.
    public var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Every live key, unordered.
    public var keys: [String] {
        state.withLock { Array($0.entries.keys) }
    }

    /// A copy of every live entry.
    public var entries: [String: KV] {
        state.withLock { $0.entries }
    }

    // MARK: Observing

    /// A registered observer; `cancel()` removes it. Deallocation does
    /// not.
    public struct Observation: Sendable {
        let id: UInt64
        weak var store: Store?
        public func cancel() { store?.removeObserver(id) }
    }

    /// Registers `observer` for every batch of changes applied from now.
    public func observe(_ observer: @escaping Observer) -> Observation {
        let id: UInt64 = state.withLock { s in
            defer { s.nextObserver += 1 }
            s.observers[s.nextObserver] = observer
            return s.nextObserver
        }
        return Observation(id: id, store: self)
    }

    private func removeObserver(_ id: UInt64) {
        state.withLock { $0.observers[id] = nil }
    }

    /// The change batches as a stream; ending the stream unregisters.
    public func changes(bufferingPolicy: AsyncStream<[Change]>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<[Change]> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { cont in
            let obs = observe { cont.yield($0) }
            cont.onTermination = { _ in obs.cancel() }
        }
    }

    // Runs `body` under the lock, then delivers whatever it recorded to
    // the observers outside it.
    private func mutate<R: Sendable>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
        let (result, batch, observers): (R, [Change], [Observer]) = try state.withLock { s in
            let r = try body(&s)
            defer { s.changes.removeAll(keepingCapacity: true) }
            return (r, s.changes, s.changes.isEmpty ? [] : Array(s.observers.values))
        }
        for o in observers { o(batch) }
        return result
    }

    // MARK: Live lane

    /// Applies one live-lane message. Live ops apply immediately under
    /// per-key dedup; during the catch-up window every live clear,
    /// including for keys not held, is recorded as a transient tombstone
    /// so a late catch-up chunk cannot resurrect it (lasa-core.md §6.5).
    public func applyLive(_ m: StateMessage) throws {
        try mutate { s in try self.applyLive(&s, m) }
    }

    private func applyLive(_ s: inout State, _ m: StateMessage) throws {
        switch m {
        case .set(let op):
            liveSet(&s, op)
        case .clear(let op):
            liveClear(&s, op)
        case .group(let ops):
            for op in ops { try applyLive(&s, op.message) }
        case .frontier(let epoch, let seq):
            setEpoch(&s, epoch)
            if seq > s.liveMaxSeq { s.liveMaxSeq = seq }
            advanceCursor(&s)
        case .begin:
            throw StoreError.unexpectedLiveMessage("begin")
        }
    }

    private func liveSet(_ s: inout State, _ v: SetOp) {
        if let kv = s.entries[v.key], v.seq <= kv.seq { return }
        if s.inWindow, (s.transient[v.key] ?? 0) >= v.seq { return }
        s.entries[v.key] = KV(value: v.value, seq: v.seq)
        s.changes.append(Change(key: v.key, value: v.value, seq: v.seq))
    }

    private func liveClear(_ s: inout State, _ v: ClearOp) {
        if let kv = s.entries[v.key], v.seq <= kv.seq { return }
        if s.entries.removeValue(forKey: v.key) != nil {
            s.changes.append(Change(key: v.key, value: nil, seq: v.seq))
        }
        if s.inWindow { s.transient[v.key] = v.seq }
    }

    // MARK: Catch-up lane

    /// Applies one catch-up-lane message: begin opens the window, entries
    /// stream lazily, and the closing frontier finalizes, running the
    /// snapshot deletion rule, dropping the transient records, and
    /// earning the cursor (invariant F7).
    public func applyCatchUp(_ m: StateMessage) throws {
        try mutate { s in try self.applyCatchUp(&s, m) }
    }

    private func applyCatchUp(_ s: inout State, _ m: StateMessage) throws {
        switch m {
        case .begin(let kind):
            s.inWindow = true
            s.windowKind = kind
            s.windowStart = clock()
            s.transient = [:]
            s.snapshotIn = []
        case .set(let op):
            guard s.inWindow else { throw StoreError.entryBeforeBegin }
            if s.windowKind == .snapshot { s.snapshotIn.insert(op.key) }
            // Resurrection guard: cleared live at or after this seq.
            if (s.transient[op.key] ?? 0) >= op.seq { return }
            if let kv = s.entries[op.key], op.seq <= kv.seq { return }
            s.entries[op.key] = KV(value: op.value, seq: op.seq)
            s.changes.append(Change(key: op.key, value: op.value, seq: op.seq))
        case .clear(let op):
            guard s.inWindow else { throw StoreError.entryBeforeBegin }
            if let kv = s.entries[op.key], op.seq > kv.seq {
                s.entries[op.key] = nil
                s.changes.append(Change(key: op.key, value: nil, seq: op.seq))
            }
        case .frontier(let epoch, let seq):
            guard s.inWindow else { throw StoreError.frontierBeforeBegin }
            setEpoch(&s, epoch)
            if s.windowKind == .snapshot {
                // Rule 3, snapshot only: delete every in-scope local key
                // absent from the snapshot whose seq is at or below the cut.
                for (k, kv) in s.entries where !s.snapshotIn.contains(k) && kv.seq <= seq {
                    s.entries[k] = nil
                    s.changes.append(Change(key: k, value: nil, seq: seq))
                }
            }
            s.inWindow = false
            s.transient = [:]
            s.snapshotIn = []
            s.eligible = true
            if seq > s.liveMaxSeq { s.liveMaxSeq = seq }
            advanceCursor(&s)
        case .group:
            throw StoreError.unexpectedCatchUpMessage("group")
        }
    }

    private func setEpoch(_ s: inout State, _ e: [UInt8]) {
        if s.epoch == nil || s.epoch! != e {
            // New epoch: any previously earned cursor is for a dead seq space.
            if s.epoch != nil, let c = s.cursor, c.epoch != e {
                s.cursor = nil
            }
            s.epoch = e
        }
    }

    // Moves the cursor to the max seq seen across both paths, only once
    // eligible (invariant F7), and only within the current epoch.
    private func advanceCursor(_ s: inout State) {
        guard s.eligible, let epoch = s.epoch else { return }
        if s.cursor == nil || s.cursor!.epoch != epoch || s.liveMaxSeq > s.cursor!.seq {
            s.cursor = Cursor(epoch: epoch, seq: s.liveMaxSeq, setHash: prefixSetHash)
        }
    }

    // MARK: Instance lifecycle

    /// Informs the store its subscription instance ended (too-far-behind,
    /// displacement, transport close). The catch-up window state,
    /// including the transient records, which belong to the dead
    /// instance, is discarded; eligibility resets so the next instance
    /// must earn its own frontier before any cursor advances again.
    public func terminated() {
        state.withLock { s in
            s.inWindow = false
            s.transient = [:]
            s.snapshotIn = []
            s.eligible = false
            s.liveMaxSeq = 0
        }
    }

    /// Whether a catch-up window has been open longer than `deadlineMS`:
    /// the cue to unsubscribe and re-subscribe fresh rather than hold a
    /// transient-record window forever.
    public func catchUpStalled(deadlineMS: Double) -> Bool {
        let now = clock()
        return state.withLock { $0.inWindow && now - $0.windowStart > deadlineMS }
    }
}
