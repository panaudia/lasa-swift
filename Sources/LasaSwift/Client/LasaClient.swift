// The LASA client (plan lasa-swift.md §2): one connection presenting a
// Connection Config, entity publishers, sink and presence subscriptions,
// the state store and sync, the base-profile controls, and the lifecycle
// events. The TypeScript client's shape in Swift (lasa/client.ts), over
// the probe's transport and session.
//
// A client is one connection, as in TypeScript and Go: a reconnect is a
// new client with the same options (lasa-core.md §4.5). The client
// watches no global: the app's lifecycle is passed in (§2.2) and the
// audio session is the app's (§2.5).
//
// Lifted from the probe's LasaProbeClient 2026-11-03 and extended the
// same day; the probe's narrower `Options` initialiser is kept for the
// Part B tests and the S4 session.

import Foundation
import os

#if canImport(Network)

/// The sink formats a listener may subscribe (lasa-core.md §5.3).
public enum SinkFormat: String, Sendable {
    case binaural, ambi2, ambi3
}

public typealias SinkHandler = @Sendable (_ seq: UInt64, _ packet: SinkPacket) -> Void
public typealias PresenceHandler = @Sendable (_ group: UInt64, _ packet: PresencePacket) -> Void

@available(iOS 26.0, macOS 26.0, *)
public struct LasaClientOptions: Sendable {
    public var address: String                  // "host:port", raw QUIC
    public var spaceID = "main"
    public var clientID: String                 // MUST equal the ticket's client_id
    public var ticket: String?                  // signed JWT; refused by an unticketed space
    public var entities: [Lasa.Entity] = []     // ad hoc definitions
    public var setups: [Lasa.Setup] = []        // instantiations of ticket-defined entities
    public var lockstep = false
    public var establishDeadlineSeconds: Double = 10
    public var idleTimeoutMS = 30_000
    /// The app's foreground and background transitions (§2.2). nil: the
    /// client infers nothing about suspension.
    public var lifecycle: (any AppLifecycle)?
    public var log: @Sendable (String) -> Void = { _ in }

    public init(address: String, spaceID: String = "main", clientID: String) {
        self.address = address; self.spaceID = spaceID; self.clientID = clientID
    }
}

@available(iOS 26.0, macOS 26.0, *)
public final class LasaClient: @unchecked Sendable {
    /// The probe's options: one listener entity by id, plus extras. Kept
    /// for the Part B procedure and the S4 session; new code uses
    /// LasaClientOptions.
    public struct Options: Sendable {
        public var address: String
        public var space = "main"
        public var clientID: String
        public var entityID: String
        public var entityName = "probe-swift"
        public var hears = ["main"]
        /// Further entities in the config beside the listener, such as
        /// the microphone source.
        public var extraEntities: [Lasa.Entity] = []
        public var log: @Sendable (String) -> Void = { _ in }

        public init(address: String, clientID: String, entityID: String) {
            self.address = address; self.clientID = clientID; self.entityID = entityID
        }

        var full: LasaClientOptions {
            var o = LasaClientOptions(address: address, spaceID: space, clientID: clientID)
            o.entities = [Lasa.Entity(id: entityID, name: entityName, hears: hears, attrs: nil)] + extraEntities
            o.log = log
            return o
        }
    }

    public enum ProbeResult: Sendable { case alive(roundTripMS: Double), dead }

    /// §2.2: one stream, one consumer, in order; `closed` is terminal.
    public enum Event: Sendable {
        case closed(code: UInt32?, reason: String?)
        case suspended
        case resumed(ProbeResult)
    }

    public struct Stats: Sendable {
        public var handshakeMS: Double = 0
        public var configBytes = 0
        public var closed: String?
        public var rejectionCode: UInt32?
    }

    public let options: Options
    public let config: LasaClientOptions
    public let transport: QUICTransport
    public let session: MoQSession
    public let events: AsyncStream<Event>
    public private(set) var handshake: HandshakeResult?
    public private(set) var serverSetup: [UInt64: KVPValue] = [:]
    public private(set) var configBytes = 0

    private let eventsCont: AsyncStream<Event>.Continuation
    private struct Guarded: @unchecked Sendable {
        var stateSender: MoQSession.SubgroupSender?
        var publishers: [String: EntityPublisher] = [:]
        var syncs: [StateSync] = []
        var lifecycleTask: Task<Void, Never>?
        var lastActivityNS: Int64 = 0
        var closedReason: Error?
        var finished = false
    }
    private let g = OSAllocatedUnfairLock(initialState: Guarded())

    public init(_ config: LasaClientOptions) {
        self.config = config
        var o = Options(address: config.address, clientID: config.clientID, entityID: config.entities.first?.id ?? "")
        o.space = config.spaceID
        o.log = config.log
        options = o
        transport = QUICTransport(log: config.log)
        session = MoQSession(transport: transport, log: config.log)
        let (stream, cont) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        eventsCont = cont
        session.onClosed = { [weak self] reason in self?.sessionClosed(reason) }
    }

    public convenience init(_ options: Options) {
        self.init(options.full)
    }

    public var space: String { config.spaceID }
    public var clientID: String { config.clientID }

    /// The Connection Config this client presents.
    public func connectionConfig() -> Lasa.ConnectionConfig {
        var cfg = Lasa.ConnectionConfig(clientID: config.clientID, ticket: config.ticket,
                                        entities: config.entities.isEmpty && !config.setups.isEmpty ? nil : config.entities,
                                        lockstep: config.lockstep ? true : nil)
        if !config.setups.isEmpty { cfg.setups = config.setups }
        return cfg
    }

    // MARK: Connecting

    /// Dial, handshake, CLIENT_SETUP with the config, SERVER_SETUP, then
    /// the loops, all under the one establishment deadline. The local
    /// ticket and lockstep checks run first (§2.1) so the common mistakes
    /// never cost a round trip. With `oversize` the setup is the S1
    /// rejection probe and this throws.
    public func connect(oversize: Bool = false, deadlineSeconds: Double? = nil) async throws {
        let cfg = connectionConfig()
        if let t = config.ticket, let rejection = checkTicket(t, clientID: config.clientID, spaceID: config.spaceID, now: Date()) {
            throw rejection
        }
        try cfg.assertLockstepSupported()
        var tc = try TransportConfig(address: config.address)
        tc.idleTimeoutMS = config.idleTimeoutMS
        let param = try cfg.setupParam()
        if case .bytes(let b) = param.value { configBytes = b.count }
        let (h, params) = try await session.establish(tc, extra: [param], oversize: oversize,
                                                      deadlineSeconds: deadlineSeconds ?? config.establishDeadlineSeconds)
        handshake = h
        serverSetup = params
        noteActivity()
        if let lc = config.lifecycle { watch(lc) }
    }

    public func close() {
        let (pubs, syncs, task): ([EntityPublisher], [StateSync], Task<Void, Never>?) = g.withLock { s in
            defer { s.stateSender = nil; s.publishers = [:]; s.syncs = [] }
            return (Array(s.publishers.values), s.syncs, s.lifecycleTask)
        }
        task?.cancel()
        for p in pubs { p.close() }
        for sy in syncs { sy.stop() }
        session.close()
    }

    public var stats: Stats {
        var s = Stats()
        s.handshakeMS = handshake?.handshakeMS ?? 0
        s.configBytes = configBytes
        let r = g.withLock { $0.closedReason }
        s.closed = r.map { "\($0)" }
        s.rejectionCode = (r as? LasaRejection)?.code
        return s
    }

    private func sessionClosed(_ reason: Error) {
        let (pubs, syncs, first): ([EntityPublisher], [StateSync], Bool) = g.withLock { s in
            let first = !s.finished
            s.finished = true
            s.closedReason = reason
            return (Array(s.publishers.values), s.syncs, first)
        }
        guard first else { return }
        for p in pubs { p.close() }
        for sy in syncs { sy.instanceEnded(); sy.stop() }
        if let r = reason as? LasaRejection {
            eventsCont.yield(.closed(code: r.code, reason: r.reason.isEmpty ? nil : r.reason))
        } else {
            eventsCont.yield(.closed(code: nil, reason: "\(reason)"))
        }
        eventsCont.finish()
    }

    @inline(__always) private static func nowNS() -> Int64 {
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
    private func noteActivity() { g.withLock { $0.lastActivityNS = Self.nowNS() } }

    // MARK: Lifecycle (§2.2, §4)

    private func watch(_ lifecycle: any AppLifecycle) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            for await t in lifecycle.transitions {
                guard let self, !Task.isCancelled else { return }
                switch t {
                case .didBecomeActive:
                    await self.resumed()
                default:
                    break
                }
            }
        }
        g.withLock { $0.lifecycleTask = task }
    }

    /// On return to the foreground: a gap in receive-loop activity longer
    /// than half the idle timeout is a suspension, then the session is
    /// probed at once (a SUBSCRIBE the server must refuse: a round trip
    /// with no side effect) so the app learns alive or dead within the
    /// T7 design point rather than at the idle timeout.
    private func resumed() async {
        if session.closedError != nil { return }
        let gapNS = Self.nowNS() - g.withLock { $0.lastActivityNS }
        if gapNS > Int64(config.idleTimeoutMS) * 500_000 {
            eventsCont.yield(.suspended)
        }
        let t0 = Self.nowNS()
        let probe = Task { [session, space] () throws -> Void in
            _ = try await session.subscribe(namespace: Lasa.presenceNamespace(space: space), track: "lasa-probe")
        }
        let outcome: ProbeResult
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { _ = try await probe.value; return true }
                group.addTask { try await Task.sleep(nanoseconds: 1_000_000_000); return false }
                let first = try await group.next() ?? false
                group.cancelAll()
                if !first { throw TransportError.setupDeadline("probe") }
            }
            outcome = .alive(roundTripMS: Double(Self.nowNS() - t0) / 1e6)
        } catch is MoQ.SubscribeError {
            // The expected answer: the server is there to refuse.
            outcome = .alive(roundTripMS: Double(Self.nowNS() - t0) / 1e6)
        } catch {
            outcome = session.closedError == nil && !(error is TransportError) ? .alive(roundTripMS: Double(Self.nowNS() - t0) / 1e6) : .dead
        }
        noteActivity()
        eventsCont.yield(.resumed(outcome))
        if case .dead = outcome { session.close() }
    }

    // MARK: Entities and publishing (§2.3)

    /// The publisher for one of this connection's entities, once the
    /// server has subscribed its source track.
    public func entity(_ id: String) async throws -> EntityPublisher {
        if let p = g.withLock({ $0.publishers[id] }) { return p }
        guard let def = config.entities.first(where: { $0.id == id }) ?? config.setups.first(where: { $0.id == id }).map({ _ in Lasa.Entity(id: id, name: id) }) else {
            throw MalformedError("entity \(id) is not in this connection's config")
        }
        let alias = try await entitySourceAlias(entity: id)
        let p = try EntityPublisher(id: id, trackAlias: alias, declaredRedundancy: def.redundancy ?? 0, session: session, writer: self)
        let existing: EntityPublisher? = g.withLock { s in
            if let e = s.publishers[id] { return e }
            s.publishers[id] = p
            return nil
        }
        if let e = existing { p.close(); return e }
        return p
    }

    public func controls(entity id: String) throws -> EntityControls { try EntityControls(self, entityId: id) }
    public var spaceControls: SpaceControls { SpaceControls(self) }

    // MARK: Sinks and presence (§2.4)

    /// Subscribes an entity sink; `handler` runs on the datagram receive
    /// loop with the raw sink packet (the probe's form).
    public func subscribeSink(entity: String, format: String, _ handler: @escaping DatagramHandler) async throws -> MoQSession.Subscribed {
        let ns = Lasa.entityNamespace(space: space, entity: entity, .sink)
        let sub = try await session.subscribe(namespace: ns, track: format)
        session.registerDatagramHandler(alias: sub.trackAlias) { [weak self] a, g, p in
            self?.noteActivity()
            handler(a, g, p)
        }
        return sub
    }

    /// Subscribes an entity sink with the packet parsed; a packet with
    /// unknown flag bits is discarded as §5.1 says.
    public func subscribeSink(entity: String, format: SinkFormat, _ handler: @escaping SinkHandler) async throws {
        _ = try await subscribeSink(entity: entity, format: format.rawValue) { _, seq, payload in
            if let pkt = try? SinkPacket.parse(Array(payload)) { handler(seq, pkt) }
        }
    }

    public func subscribePresence(_ handler: @escaping PresenceHandler) async throws {
        let sub = try await session.subscribe(namespace: Lasa.presenceNamespace(space: space), track: Lasa.trackPresence)
        session.registerDatagramHandler(alias: sub.trackAlias) { [weak self] _, group, payload in
            self?.noteActivity()
            if let pkt = try? PresencePacket.parse(Array(payload)) { handler(group, pkt) }
        }
    }

    /// The live roster from the presence track, §7's rules applied.
    public func subscribeRoster() async throws -> PresenceRoster {
        let roster = PresenceRoster()
        try await subscribePresence { group, pkt in roster.apply(group: group, packet: pkt) }
        return roster
    }

    /// Subscribes this client's own state sink. With a nil handler the
    /// caller registers one later (the S2 ordering check) and objects that
    /// arrive first are held by the router.
    public func subscribeStateSink(prefixes: [String], _ handler: SubgroupHandler? = nil) async throws -> MoQSession.Subscribed {
        let ns = Lasa.clientNamespace(space: space, client: config.clientID, .sink)
        let param = KVP(Lasa.subscribeParamState, bytes: Lasa.stateSubscribeParams(prefixes: prefixes))
        let sub = try await session.subscribe(namespace: ns, track: Lasa.trackState, extra: [param])
        if let h = handler { session.registerSubgroupHandler(alias: sub.trackAlias, h) }
        return sub
    }

    /// Registers a sync so a session death ends its instance and close()
    /// stops it. StateSync.init calls this through syncState.
    func track(_ sync: StateSync) { g.withLock { $0.syncs.append(sync) } }

    // MARK: State source

    /// The alias the server's subscription to our state source carries.
    public func stateSourceAlias() async throws -> UInt64 {
        let want = Lasa.clientNamespace(space: space, client: config.clientID, .source)
        return try await session.incomingAlias { $0.namespace == want && $0.track == Lasa.trackState }
    }

    /// The alias the server's subscription to an entity's source carries
    /// (the first configured entity by default).
    public func entitySourceAlias(entity: String? = nil) async throws -> UInt64 {
        let want = Lasa.entityNamespace(space: space, entity: entity ?? options.entityID, .source)
        return try await session.incomingAlias { $0.namespace == want && $0.track == Lasa.trackMonoObject }
    }

    /// Writes client-authored state ops on the state source track, one
    /// per MoQ object, opening the subgroup stream on first use.
    public func writeState(_ ops: [Lasa.UpstreamState]) async throws {
        let existing = g.withLock { $0.stateSender }
        let sender: MoQSession.SubgroupSender
        if let e = existing {
            sender = e
        } else {
            let alias = try await stateSourceAlias()
            let s = try await session.openSubgroup(trackAlias: alias)
            sender = g.withLock { g in
                if let e = g.stateSender { return e }
                g.stateSender = s
                return s
            }
        }
        for op in ops { try await sender.write(op.encode()) }
    }

    public var stateSourceStreamID: UInt64? { g.withLock { $0.stateSender?.streamID } }

    /// The key an `audience` client may write for its own entity
    /// (base profile §2).
    public func attrKey(_ attr: String) -> String { "lasa.entity.\(options.entityID).attrs.\(attr)" }
}

@available(iOS 26.0, macOS 26.0, *)
extension LasaClient: StateWriter {}

extension Store: StateReadable {
    public func keys(withPrefix prefix: String) -> [String] { keys.filter { $0.hasPrefix(prefix) } }
}
#endif
