// The S4 session: the Swift pump wired to a live LASA connection, the
// mirror of go/probe5/session.go. The phone joins with two entities, a
// mono source fed by its microphone and a listener whose binaural sink
// feeds its output. With hearSelf (headphones) the two share a channel
// and the phone hears itself through the server; on the speaker the mic
// goes to a private channel and the sink carries the rest of the space.
//
// The uplink's send is async on Apple's API, so the sender thread hands
// each encoded packet to an ordered stream that one session-owned task
// drains with sendDatagram; the hop is a few tens of microseconds and
// keeps the sender off the cooperative pool.

import Foundation

#if canImport(Network)

@available(iOS 26.0, macOS 26.0, *)
public final class S4Session: @unchecked Sendable {
    public struct Options: Sendable {
        public var address: String
        public var clientID: String
        /// The listener entity; the source is entityID + "-mic".
        public var entityID: String
        public var hears = "main"
        public var hearSelf = false
        public var pump = SwiftPump.Config()
        /// Raises the session's receive loop to .userInteractive (cell F).
        public var receivePriorityHigh = false
        public var log: @Sendable (String) -> Void = { _ in }
        public init(address: String, clientID: String, entityID: String) {
            self.address = address; self.clientID = clientID; self.entityID = entityID
        }
    }

    public struct Stats: Sendable {
        public var pump = SwiftPump.Stats()
        public var sent: UInt64 = 0
        public var sendErrors: UInt64 = 0
        public var closed = false
        public var closeError = ""
    }

    public let options: Options
    public let pump: SwiftPump
    public let client: LasaClient
    public var micID: String { options.entityID + "-mic" }

    private let sent = Locked<UInt64>(0)
    private let sendErrors = Locked<UInt64>(0)
    private let closeError = Locked<String?>(nil)
    private var sender: Task<Void, Never>?
    private var continuation: AsyncStream<[UInt8]>.Continuation?

    public init(_ options: Options) throws {
        self.options = options
        pump = try SwiftPump(options.pump)
        var o = LasaClient.Options(address: options.address, clientID: options.clientID, entityID: options.entityID)
        o.entityName = "s4 ears"
        o.hears = [options.hears]
        let micChannel = options.hearSelf ? options.hears : options.entityID + "-uplink"
        o.extraEntities = [Lasa.Entity(id: options.entityID + "-mic", name: "s4 mic", heardIn: [micChannel])]
        o.log = options.log
        client = LasaClient(o)
        if options.receivePriorityHigh { client.session.loopPriority = .high }
    }

    /// Dials, subscribes the sink into the pump, resolves the mic's alias
    /// and starts the sender. Setup is under the client's deadline.
    public func start() async throws {
        client.transport.onDeath = { [closeError] reason in closeError.with { $0 = reason } }
        try await client.connect()
        _ = try await client.subscribeSink(entity: options.entityID, format: Lasa.trackBinaural) { [pump] arrival, seq, payload in
            pump.onSink(arrivalNS: arrival, seq: seq, payload: payload)
        }
        let alias = try await client.entitySourceAlias(entity: micID)
        let (stream, cont) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        let session = client.session
        let sent = self.sent, sendErrors = self.sendErrors
        sender = Task.detached(priority: .userInitiated) {
            for await dg in stream {
                do {
                    try await session.sendDatagram(dg)
                    sent.with { $0 += 1 }
                } catch {
                    sendErrors.with { $0 += 1 }
                }
            }
        }
        // Audio-only mono-object packets, seq as the MoQ group id, the
        // whole datagram framed here on the sender's thread.
        pump.run { [cont] seq, frame in
            var body = [UInt8]()
            body.reserveCapacity(frame.count + 1)
            body.append(Lasa.flagAudio)
            body.append(contentsOf: frame)
            var out = [UInt8]()
            body.withUnsafeBytes {
                MoQ.encodeObjectDatagram(into: &out, trackAlias: alias, groupID: seq, objectID: 0, priority: 0, payload: $0)
            }
            cont.yield(out)
        }
    }

    public func stop() {
        pump.stop()
        continuation?.finish()
        sender?.cancel()
        client.close()
    }

    public func stats() -> Stats {
        var s = Stats()
        s.pump = pump.stats()
        s.sent = sent.with { $0 }
        s.sendErrors = sendErrors.with { $0 }
        if let e = closeError.with({ $0 }) { s.closed = true; s.closeError = e }
        return s
    }
}
#endif
