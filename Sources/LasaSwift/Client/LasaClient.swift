// The LASA layer over MoQSession: one connection with one listener
// entity, sink subscriptions, the state sink and source, and the
// Connection Config. Lifted from the probe's LasaProbeClient on
// 2026-11-03; the surface in lasa-planning/plan/lasa-swift.md §2 (the
// state store, presence, roster and the uplink sequencer) is the port
// that follows.

import Foundation

#if canImport(Network)

@available(iOS 26.0, macOS 26.0, *)
public final class LasaClient: @unchecked Sendable {
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
    }

    public let options: Options
    public let transport: QUICTransport
    public let session: MoQSession
    public private(set) var handshake: HandshakeResult?
    public private(set) var serverSetup: [UInt64: KVPValue] = [:]
    public private(set) var configBytes = 0

    private var stateSender: MoQSession.SubgroupSender?

    public init(_ options: Options) {
        self.options = options
        transport = QUICTransport(log: options.log)
        session = MoQSession(transport: transport, log: options.log)
    }

    public var space: String { options.space }

    /// The Connection Config this client presents.
    public func connectionConfig() -> Lasa.ConnectionConfig {
        let entity = Lasa.Entity(id: options.entityID, name: options.entityName, hears: options.hears, attrs: nil)
        return Lasa.ConnectionConfig(clientID: options.clientID, entities: [entity] + options.extraEntities)
    }

    /// Dial, handshake, CLIENT_SETUP with the config, SERVER_SETUP, then
    /// the loops, all under the one establishment deadline. With
    /// `oversize` the setup is the S1 rejection probe and this throws.
    public func connect(oversize: Bool = false, deadlineSeconds: Double = 10) async throws {
        let cfg = try TransportConfig(address: options.address)
        let param = try connectionConfig().setupParam()
        if case .bytes(let b) = param.value { configBytes = b.count }
        let (h, params) = try await session.establish(cfg, extra: [param], oversize: oversize, deadlineSeconds: deadlineSeconds)
        handshake = h
        serverSetup = params
    }

    public func close() {
        stateSender = nil
        session.close()
    }

    // MARK: Sinks

    /// Subscribes an entity sink (binaural, ambi2, ambi3); `handler` runs on
    /// the datagram receive loop with the raw sink packet.
    public func subscribeSink(entity: String, format: String, _ handler: @escaping DatagramHandler) async throws -> MoQSession.Subscribed {
        let ns = Lasa.entityNamespace(space: space, entity: entity, .sink)
        let sub = try await session.subscribe(namespace: ns, track: format)
        session.registerDatagramHandler(alias: sub.trackAlias, handler)
        return sub
    }

    /// Subscribes this client's own state sink. With a nil handler the
    /// caller registers one later (the S2 ordering check) and objects that
    /// arrive first are held by the router.
    public func subscribeStateSink(prefixes: [String], _ handler: SubgroupHandler? = nil) async throws -> MoQSession.Subscribed {
        let ns = Lasa.clientNamespace(space: space, client: options.clientID, .sink)
        let param = KVP(Lasa.subscribeParamState, bytes: Lasa.stateSubscribeParams(prefixes: prefixes))
        let sub = try await session.subscribe(namespace: ns, track: Lasa.trackState, extra: [param])
        if let h = handler { session.registerSubgroupHandler(alias: sub.trackAlias, h) }
        return sub
    }

    // MARK: State source

    /// The alias the server's subscription to our state source carries.
    public func stateSourceAlias() async throws -> UInt64 {
        let want = Lasa.clientNamespace(space: space, client: options.clientID, .source)
        return try await session.incomingAlias { $0.namespace == want && $0.track == Lasa.trackState }
    }

    /// The alias the server's subscription to an entity's source carries
    /// (ours by default).
    public func entitySourceAlias(entity: String? = nil) async throws -> UInt64 {
        let want = Lasa.entityNamespace(space: space, entity: entity ?? options.entityID, .source)
        return try await session.incomingAlias { $0.namespace == want && $0.track == Lasa.trackMonoObject }
    }

    /// Writes client-authored state ops on the state source track, one
    /// per MoQ object, opening the subgroup stream on first use.
    public func writeState(_ ops: [Lasa.UpstreamState]) async throws {
        if stateSender == nil {
            let alias = try await stateSourceAlias()
            stateSender = try await session.openSubgroup(trackAlias: alias)
        }
        for op in ops { try await stateSender!.write(op.encode()) }
    }

    public var stateSourceStreamID: UInt64? { stateSender?.streamID }

    /// The key an `audience` client may write for its own entity
    /// (base profile §2).
    public func attrKey(_ attr: String) -> String { "lasa.entity.\(options.entityID).attrs.\(attr)" }
}
#endif
