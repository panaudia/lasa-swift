// The LASA state sync client (lasa-core.md §6.5 to §6.7): subscribes the
// client sink `state` track with the 0x1A5A3 subscribe parameter, feeds
// the two subgroup lanes into the Store (subgroup 0 live, subgroup 1
// catch-up), and re-subscribes with doubling backoff, capped at 5 s,
// when the server ends the instance. Port of
// lasa/typescript/src/lasa/state.ts, 2026-11-03; mirrors Go
// `lasa/client.SyncState`. The store rules live in Store.swift.
//
// Divergences from the TypeScript:
// - No promise chain: Store's apply methods are synchronous under its
//   own lock, so lane objects are applied straight from the receive
//   loop's handler (plan rule 6), each lane in its arrival order.
// - The instance-ended signal is MoQSession.onPublishDone, as in the
//   TypeScript; `instanceEnded(status:)` is the same signal for a caller
//   that learns it another way (a lane stream closing). MoQSession has
//   no subgroup handler removal yet, so objects for a dead instance are
//   dropped by generation and the stale alias handler is harmless.
// - `start()` and `stop()` replace `run()`; `join()` awaits the loop.

import Foundation
import os

public struct StateSyncOptions: Sendable {
    /// Initial re-subscribe backoff in ms (doubles to a 5 s cap).
    public var initialBackoffMS: Double = 100
    /// Logging of subscribe, instance and re-subscribe events.
    public var log: @Sendable (String) -> Void = { _ in }

    public init(initialBackoffMS: Double = 100, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.initialBackoffMS = initialBackoffMS
        self.log = log
    }
}

#if canImport(Network)

/// Runs the state subscription loop from `start()` until `stop()`.
@available(iOS 26.0, macOS 26.0, *)
public final class StateSync: @unchecked Sendable {
    static let catchUpLane: UInt64 = 1
    static let maxBackoffMS: Double = 5000

    public let store: Store
    private let session: MoQSession
    private let spaceID: String
    private let clientID: String
    private let opts: StateSyncOptions

    private struct Instance {
        let generation: UInt64
        let requestID: UInt64
        let trackAlias: UInt64
        let ended: OneShot<Void>
    }
    private struct State {
        var stopped = false
        var task: Task<Void, Never>?
        var nextGeneration: UInt64 = 1
        var current: Instance?
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init(session: MoQSession, spaceID: String, clientID: String, store: Store, options: StateSyncOptions = StateSyncOptions()) {
        self.session = session
        self.spaceID = spaceID
        self.clientID = clientID
        self.store = store
        self.opts = options
    }

    public convenience init(client: LasaClient, store: Store, options: StateSyncOptions = StateSyncOptions()) {
        self.init(session: client.session, spaceID: client.space, clientID: client.options.clientID, store: store, options: options)
    }

    private func log(_ s: String) { opts.log("[state] \(s)") }

    /// The request id and track alias of the live subscription instance,
    /// nil between instances.
    public var currentInstance: (requestID: UInt64, trackAlias: UInt64)? {
        state.withLock { s in s.current.map { ($0.requestID, $0.trackAlias) } }
    }

    // MARK: Lifecycle

    /// Starts the subscribe/apply/re-subscribe loop. A second call, or a
    /// call after `stop()`, does nothing.
    public func start() {
        let task: Task<Void, Never>? = state.withLock { s in
            guard !s.stopped, s.task == nil else { return nil }
            let t = Task.detached(priority: .userInitiated) { [self] in await self.run() }
            s.task = t
            return t
        }
        _ = task
    }

    /// Ends the loop: ends the current instance, cancels the backoff
    /// wait, and leaves the store terminated.
    public func stop() {
        let (task, current): (Task<Void, Never>?, Instance?) = state.withLock { s in
            s.stopped = true
            return (s.task, s.current)
        }
        current?.ended.set(.success(()))
        task?.cancel()
    }

    /// Resolves once the loop has exited after `stop()`.
    public func join() async {
        let task: Task<Void, Never>? = state.withLock { $0.task }
        await task?.value
    }

    /// The server ended the subscription instance (PUBLISH_DONE, which
    /// the session reports here itself, or a lane stream closing). The
    /// loop re-subscribes after the backoff. With a `requestID`, ignored
    /// unless it names the current instance.
    public func instanceEnded(requestID: UInt64? = nil, status: UInt64? = nil) {
        let current: Instance? = state.withLock { s in
            guard let c = s.current, requestID == nil || requestID == c.requestID else { return nil }
            return c
        }
        guard let c = current else { return }
        log("instance ended, request=\(c.requestID) status=\(status.map(String.init) ?? "-")")
        c.ended.set(.success(()))
    }

    // MARK: The loop

    private func run() async {
        var backoff = opts.initialBackoffMS
        while !Task.isCancelled {
            do {
                try await syncOnce()
                backoff = opts.initialBackoffMS // instance ended after a healthy run
            } catch {
                log("sync error: \(error)")
            }
            if Task.isCancelled { return }
            do { try await Task.sleep(for: .milliseconds(Int64(backoff))) } catch { return }
            if backoff < Self.maxBackoffMS { backoff *= 2 }
        }
    }

    private func syncOnce() async throws {
        let p = store.subscribeParams()
        let raw = try StateWire.encodeSubscribeParams(p.prefixes, cursor: p.cursor)
        let ns = Lasa.clientNamespace(space: spaceID, client: clientID, .sink)
        let sub = try await session.subscribe(namespace: ns, track: Lasa.trackState,
                                              extra: [KVP(StateWire.subscribeParamState, bytes: raw)])
        let instance: Instance? = state.withLock { s in
            // stop() ran while SUBSCRIBE was in flight: register nothing;
            // the instance lapses with the session.
            guard !s.stopped else { return nil }
            defer { s.nextGeneration += 1 }
            let i = Instance(generation: s.nextGeneration, requestID: sub.requestID, trackAlias: sub.trackAlias, ended: OneShot<Void>())
            s.current = i
            return i
        }
        guard let instance else { return }
        log("subscribed, id=\(sub.requestID) alias=\(sub.trackAlias) cursor=\(p.cursor != nil)")

        let gen = instance.generation
        // The instance ends when the server says so (PUBLISH_DONE) or we stop.
        session.onPublishDone(requestID: sub.requestID) { [weak self] status in
            self?.instanceEnded(requestID: sub.requestID, status: status)
        }
        session.registerSubgroupHandler(alias: sub.trackAlias) { [weak self] h, id, payload in
            self?.onObject(gen, h, id, payload)
        }
        defer {
            state.withLock { s in if s.current?.generation == gen { s.current = nil } }
            // Objects of the dead instance are dropped by generation from
            // here on, so the terminated store sees nothing stale.
            store.terminated()
        }
        try await withTaskCancellationHandler {
            try await instance.ended.wait()
        } onCancel: {
            instance.ended.set(.success(()))
        }
    }

    private func onObject(_ gen: UInt64, _ h: MoQ.SubgroupHeader, _ id: UInt64, _ payload: [UInt8]) {
        if payload.isEmpty { return } // status-only object
        let live: Bool = state.withLock { $0.current?.generation == gen }
        guard live else { return }
        apply(subgroupID: h.subgroupID, payload)
    }

    /// Applies one lane object to the store: subgroup 1 is the catch-up
    /// lane, every other subgroup the live lane. Malformed messages and
    /// store errors are logged and dropped, as the TypeScript does.
    func apply(subgroupID: UInt64, _ payload: [UInt8]) {
        do {
            let msg = try StateWire.parseStateMessage(payload, .downstream)
            if subgroupID == Self.catchUpLane {
                try store.applyCatchUp(msg)
            } else {
                try store.applyLive(msg)
            }
        } catch {
            log("apply error: \(error)")
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension LasaClient {
    /// A StateSync over this client's session for `store`, not yet
    /// started.
    public func syncState(_ store: Store, options: StateSyncOptions = StateSyncOptions()) -> StateSync {
        let sync = StateSync(client: self, store: store, options: options)
        track(sync)
        return sync
    }
}
#endif
