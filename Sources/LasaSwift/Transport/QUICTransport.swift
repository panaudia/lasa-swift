// The Part B transport (plan §5.3): Apple's QUIC through
// NetworkConnection<QUIC> on iOS 26 and macOS 26, with the MoQ session
// on top. The layering follows the TypeScript client (connection, a
// session with one control-stream reader, a datagram router and a
// subgroup router) and the Go client's alias-routed receive path.
//
// Lifecycle, measured against the live server (plan §7.5): the
// connection's state turns `failed` within about 13 ms of the peer
// closing; a pending receive ends when its task is cancelled, and fails
// when the connection fails; a pending send ends when its task is
// cancelled but is never completed by the framework when the connection
// fails. So the connection state is the authority. One observer turns
// `failed` or `cancelled` into a teardown that cancels every task the
// session owns, sends included, and that makes a dead connection a
// prompt error everywhere. There are no per-operation timers. The one
// wall-clock deadline is on session establishment, because a server that
// neither answers nor closes is otherwise undetectable; it is a
// cancellation of the establishing task, the same shape as the Go
// client's setup context.
//
// Other rules from the plan: the datagram receive loop stamps arrival
// first, parses second, hands on third; nothing here is main-actor
// isolated; handlers run on the receive loop and must not block.
//
// TLS is the system default: the server presents a publicly trusted
// certificate. A LAN server with its own certificate is a pinning
// question for later, not a reason to weaken verification here.

import Foundation
import os

public struct TransportConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var alpn: String = Lasa.alpn
    public var idleTimeoutMS: Int = 30_000
    /// Our max_datagram_frame_size transport parameter: what we accept.
    public var maxDatagramFrameSize: Int = 1500

    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    /// "host:port".
    public init(address: String) throws {
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]) else {
            throw TransportError.badAddress(address)
        }
        self.init(host: String(address[..<colon]), port: port)
    }
}

public enum TransportError: Error, CustomStringConvertible, Sendable {
    case badAddress(String)
    case notConnected
    case connectionFailed(String)
    case setupDeadline(String)
    case unexpectedMessage(UInt64)
    case controlStreamClosed
    case sessionClosed(String)

    public var description: String {
        switch self {
        case .badAddress(let a): return "bad address \(a)"
        case .notConnected: return "not connected"
        case .connectionFailed(let s): return "connection failed: \(s)"
        case .setupDeadline(let s): return "setup deadline passed during \(s)"
        case .unexpectedMessage(let t): return "unexpected control message 0x\(String(t, radix: 16))"
        case .controlStreamClosed: return "control stream closed by the peer"
        case .sessionClosed(let why): return "session closed: \(why)"
        }
    }
}

public struct HandshakeResult: Sendable {
    public var negotiatedALPN: String?
    public var handshakeMS: Double
    public var usableDatagramFrameSize: Int
    public var remoteIdleTimeoutMS: Int
    public var remoteMaxStreamsBidirectional: Int
    public var remoteMaxStreamsUnidirectional: Int
}

/// Datagram handler: arrival stamp (unix ns, taken before parsing), the
/// MoQ group id (the frame sequence), and the object payload.
public typealias DatagramHandler = @Sendable (_ arrivalNS: Int64, _ groupID: UInt64, _ payload: UnsafeRawBufferPointer) -> Void

/// Subgroup object handler: the stream's header and one object.
public typealias SubgroupHandler = @Sendable (_ header: MoQ.SubgroupHeader, _ objectID: UInt64, _ payload: [UInt8]) -> Void

/// A one-shot result that may be awaited before or after it is set, and
/// ignores every setting after the first.
public final class OneShot<T: Sendable>: @unchecked Sendable {
    private struct S { var result: Result<T, Error>?; var cont: CheckedContinuation<T, Error>? }
    private let lock = OSAllocatedUnfairLock<S>(initialState: S())

    public init() {}

    public func set(_ r: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock { s in
            guard s.result == nil else { return nil }
            s.result = r
            defer { s.cont = nil }
            return s.cont
        }
        c?.resume(with: r)
    }

    public func wait() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            let ready: Result<T, Error>? = lock.withLock { s in
                if let r = s.result { return r }
                s.cont = c
                return nil
            }
            if let r = ready { c.resume(with: r) }
        }
    }
}

#if canImport(Network)
import Network

// MARK: - The QUIC connection

@available(iOS 26.0, macOS 26.0, *)
public final class QUICTransport: @unchecked Sendable {
    public typealias Connection = NetworkConnection<QUIC>
    public typealias Stream = QUIC.Stream<QUICStream>

    private let slot = OSAllocatedUnfairLock<Connection?>(initialState: nil)
    /// The first client-opened bidirectional stream, opened by `connect`
    /// as the handshake's completion and taken by the session as the MoQ
    /// control stream.
    public private(set) var controlStream: Stream?
    public let log: @Sendable (String) -> Void
    /// Called once, off the caller's task, when the connection reports
    /// `failed` or `cancelled`. The session hangs its teardown here.
    public var onDeath: (@Sendable (String) -> Void)?

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) { self.log = log }

    public var connection: Connection? { slot.withLock { $0 } }

    /// Dials and opens the control stream, which the API completes only
    /// once the QUIC handshake has, and reports the handshake numbers
    /// (S1). Cancelling the calling task cancels the dial.
    public func connect(_ config: TransportConfig) async throws -> HandshakeResult {
        let endpoint = NWEndpoint.hostPort(host: .name(config.host, nil), port: NWEndpoint.Port(rawValue: config.port)!)
        let conn = Connection(to: endpoint) {
            QUIC(alpn: [config.alpn])
                .idleTimeout(config.idleTimeoutMS)
                .maxDatagramFrameSize(config.maxDatagramFrameSize)
        }
        slot.withLock { $0 = conn }
        let log = self.log
        let died = OneShot<Void>()
        conn.onStateUpdate { [weak self] _, state in
            log("connection state: \(state)")
            switch state {
            case .failed(let e):
                died.set(.success(()))
                self?.onDeath?("\(e)")
            case .cancelled:
                died.set(.success(()))
                self?.onDeath?("cancelled")
            default: break
            }
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        // iOS 27 SDK: start() returns Self for chaining, not @discardableResult.
        _ = conn.start()
        let stream = try await conn.openStream(directionality: .bidirectional)
        let t1 = DispatchTime.now().uptimeNanoseconds
        controlStream = stream

        return HandshakeResult(
            negotiatedALPN: conn.negotiatedALPN,
            handshakeMS: Double(t1 - t0) / 1e6,
            usableDatagramFrameSize: conn.usableDatagramFrameSize,
            remoteIdleTimeoutMS: conn.remoteIdleTimeout,
            remoteMaxStreamsBidirectional: conn.remoteMaxStreamsBidirectional,
            remoteMaxStreamsUnidirectional: conn.remoteMaxStreamsUnidirectional)
    }

    public func openStream(bidirectional: Bool) async throws -> Stream {
        guard let conn = connection else { throw TransportError.notConnected }
        return try await conn.openStream(directionality: bidirectional ? .bidirectional : .unidirectional)
    }

    public func datagrams() async throws -> QUIC.Datagrams<QUICDatagram> {
        guard let conn = connection else { throw TransportError.notConnected }
        return try await conn.datagrams
    }

    /// Runs `handler` for every server-opened stream until the connection ends.
    public func inboundStreams(_ handler: @escaping @Sendable (Stream) async throws -> Void) async throws {
        guard let conn = connection else { throw TransportError.notConnected }
        try await conn.inboundStreams(handler)
    }

    /// The new API has no explicit cancel; dropping the last reference
    /// closes the connection. The session cancels its tasks first.
    public func close() {
        controlStream = nil
        slot.withLock { $0 = nil }
    }
}

// MARK: - The MoQ session

/// The control stream, its single reader, the two routers, and the
/// lifecycle: every task doing I/O belongs to the session, and a dead
/// connection or a close cancels them all.
@available(iOS 26.0, macOS 26.0, *)
public final class MoQSession: @unchecked Sendable {
    public let transport: QUICTransport
    public let log: @Sendable (String) -> Void

    private var control: QUICTransport.Stream?
    public private(set) var controlStreamID: UInt64 = .max
    private var readBuf: [UInt8] = []

    private struct Waiter {
        let types: Set<UInt64>
        let cont: CheckedContinuation<MoQ.Framed, Error>
    }
    private struct IncomingWaiter {
        let match: @Sendable (MoQ.IncomingSubscribe) -> Bool
        let cont: CheckedContinuation<UInt64, Error>
    }
    private struct State: @unchecked Sendable {
        var nextRequestID: UInt64 = 0          // client request ids are even
        var nextIncomingAlias: UInt64 = 1
        var waiters: [Waiter] = []
        var incoming: [UInt64: MoQ.IncomingSubscribe] = [:]   // by the alias we assigned
        var incomingWaiters: [IncomingWaiter] = []
        var datagramHandlers: [UInt64: DatagramHandler] = [:]
        var pendingDatagrams: [(alias: UInt64, group: UInt64, arrival: Int64, payload: [UInt8])] = []
        var pendingDatagramBytes = 0
        var subgroupHandlers: [UInt64: SubgroupHandler] = [:]
        var pendingObjects: [(MoQ.SubgroupHeader, UInt64, [UInt8])] = []
        /// Every task the session owns, by a serial id. Teardown cancels them all.
        var tasks: [UInt64: Task<Void, Never>] = [:]
        var nextTaskID: UInt64 = 0
        var closed: Error?
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init(transport: QUICTransport, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.log = log
        transport.onDeath = { [weak self] why in self?.teardown(TransportError.connectionFailed(why)) }
    }

    /// The reason the session ended, nil while it lives.
    public var closedError: Error? { state.withLock { $0.closed } }

    // MARK: Ownership

    /// Runs `body` in a task the session owns, so that teardown cancels
    /// it, and returns its value. A cancelled send throws, a cancelled
    /// receive returns an empty end-of-stream that the readers check.
    @discardableResult
    private func owned<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        if let e = closedError { throw e }
        let result = OneShot<T>()
        let id: UInt64 = state.withLock { s in defer { s.nextTaskID += 1 }; return s.nextTaskID }
        let task = Task.detached(priority: .userInitiated) {
            do { result.set(.success(try await body())) } catch { result.set(.failure(error)) }
        }
        let alreadyClosed: Bool = state.withLock { s in
            if s.closed != nil { return true }
            s.tasks[id] = task
            return false
        }
        if alreadyClosed { task.cancel() }
        defer { _ = state.withLock { $0.tasks.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await result.wait()
        } onCancel: {
            task.cancel()
        }
    }

    /// The priority of the session's three loops (control, datagram,
    /// inbound streams). S4 cell F raises it to .high to ask
    /// whether the receive path needs it (plan §5.7). Set before
    /// establish.
    public var loopPriority: TaskPriority = .userInitiated

    /// Starts a long-lived loop the session owns.
    private func spawn(_ body: @escaping @Sendable () async -> Void) {
        let id: UInt64 = state.withLock { s in defer { s.nextTaskID += 1 }; return s.nextTaskID }
        let task = Task.detached(priority: loopPriority) { await body() }
        let alreadyClosed: Bool = state.withLock { s in
            if s.closed != nil { return true }
            s.tasks[id] = task
            return false
        }
        if alreadyClosed { task.cancel() }
    }

    /// Ends the session: records the reason, fails every waiter, cancels
    /// every owned task. Idempotent; the first reason wins.
    private func teardown(_ reason: Error) {
        let (first, tasks, ws, iws): (Bool, [Task<Void, Never>], [Waiter], [IncomingWaiter]) = state.withLock { s in
            if s.closed != nil { return (false, [], [], []) }
            s.closed = reason
            defer { s.waiters.removeAll(); s.incomingWaiters.removeAll(); s.tasks.removeAll() }
            return (true, Array(s.tasks.values), s.waiters, s.incomingWaiters)
        }
        guard first else { return }
        log("session teardown: \(reason)")
        for w in ws { w.cont.resume(throwing: reason) }
        for w in iws { w.cont.resume(throwing: reason) }
        for t in tasks { t.cancel() }
    }

    public func close() {
        teardown(TransportError.sessionClosed("closed by the client"))
        control = nil
        transport.close()
    }

    // MARK: Establishment

    /// Dials, opens the control stream, sends CLIENT_SETUP and reads
    /// SERVER_SETUP, then starts the loops. The one wall-clock deadline in
    /// the transport: if it passes, the establishing task is cancelled,
    /// which ends whichever step it is in, and the session is torn down.
    /// `oversize` frames a body the 16-bit length cannot describe (the S1
    /// rejection probe), so the call is expected to fail.
    public func establish(_ config: TransportConfig, extra: [KVP], maxRequestID: UInt64? = 100,
                          oversize: Bool = false, deadlineSeconds: Double = 10) async throws -> (HandshakeResult, [UInt64: KVPValue]) {
        let phase = OSAllocatedUnfairLock<String>(initialState: "dial")
        let work = Task.detached(priority: .userInitiated) { [self] () throws -> (HandshakeResult, [UInt64: KVPValue]) in
            let handshake = try await transport.connect(config)
            try Task.checkCancellation()
            guard let stream = transport.controlStream else { throw TransportError.notConnected }
            control = stream
            controlStreamID = stream.streamID
            phase.withLock { $0 = "CLIENT_SETUP send" }
            let body = MoQ.clientSetupBody(maxRequestID: maxRequestID, extra: extra)
            let msg = oversize ? MoQ.frameUnchecked(.clientSetup, body: body) : try MoQ.frame(.clientSetup, body: body)
            try await stream.send(msg)
            phase.withLock { $0 = "SERVER_SETUP" }
            let reply = try await readFramed()
            guard reply.type == MoQ.MessageType.serverSetup.rawValue else {
                throw TransportError.unexpectedMessage(reply.type)
            }
            return (handshake, try MoQ.parseServerSetup(reply.body))
        }
        // The establishing task is session-owned too, so a connection death
        // during setup cancels it at once rather than at the deadline.
        let workID: UInt64 = state.withLock { s in defer { s.nextTaskID += 1 }; return s.nextTaskID }
        state.withLock { $0.tasks[workID] = Task.detached { await withTaskCancellationHandler { _ = try? await work.value } onCancel: { work.cancel() } } }
        let timer = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1e9))
            if !Task.isCancelled { work.cancel() }
        }
        defer { timer.cancel(); _ = state.withLock { $0.tasks.removeValue(forKey: workID) } }
        do {
            let result = try await work.value
            start()
            return result
        } catch {
            // A connection death already named the reason. Otherwise a
            // cancelled establishing task means the deadline passed; any
            // other error is the step's own.
            let reason: Error
            if let dead = closedError {
                reason = dead
            } else if work.isCancelled {
                reason = TransportError.setupDeadline(phase.withLock { $0 })
            } else {
                reason = error
            }
            teardown(reason)
            throw reason
        }
    }

    /// Starts the control, datagram and inbound-stream loops.
    private func start() {
        spawn { [self] in await self.controlLoop() }
        spawn { [self] in await self.datagramLoop() }
        spawn { [self] in await self.inboundLoop() }
    }

    // MARK: Subscribe

    public struct Subscribed: Sendable {
        public var requestID: UInt64
        public var trackAlias: UInt64
        public var params: [UInt64: KVPValue]
        public var roundTripMS: Double
    }

    public func subscribe(namespace: [String], track: String, extra: [KVP] = []) async throws -> Subscribed {
        guard let stream = control else { throw closedError ?? TransportError.notConnected }
        let rid: UInt64 = state.withLock { s in defer { s.nextRequestID += 2 }; return s.nextRequestID }
        let msg = try MoQ.subscribe(requestID: rid, namespace: namespace, track: track, extra: extra)
        let t0 = DispatchTime.now().uptimeNanoseconds
        try await owned { try await stream.send(msg) }
        let reply = try await waitFor([MoQ.MessageType.subscribeOk.rawValue, MoQ.MessageType.subscribeError.rawValue])
        let t1 = DispatchTime.now().uptimeNanoseconds
        if reply.type == MoQ.MessageType.subscribeError.rawValue {
            throw try MoQ.parseSubscribeError(reply.body)
        }
        let ok = try MoQ.parseSubscribeOk(reply.body)
        return Subscribed(requestID: ok.requestID, trackAlias: ok.trackAlias, params: ok.params,
                          roundTripMS: Double(t1 - t0) / 1e6)
    }

    /// The alias we assigned to the server's subscription matching
    /// `match`, waiting for the SUBSCRIBE if it has not arrived yet. Ends
    /// with the session.
    public func incomingAlias(_ match: @escaping @Sendable (MoQ.IncomingSubscribe) -> Bool) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt64, Error>) in
            let outcome: Result<UInt64, Error>? = self.state.withLock { s in
                if let e = s.closed { return .failure(e) }
                if let hit = s.incoming.first(where: { match($0.value) }) { return .success(hit.key) }
                s.incomingWaiters.append(IncomingWaiter(match: match, cont: c))
                return nil
            }
            if let o = outcome { c.resume(with: o) }
        }
    }

    // MARK: Routers

    public func registerDatagramHandler(alias: UInt64, _ h: @escaping DatagramHandler) {
        let drained: [(UInt64, Int64, [UInt8])] = state.withLock { s in
            s.datagramHandlers[alias] = h
            let mine = s.pendingDatagrams.filter { $0.alias == alias }
            s.pendingDatagrams.removeAll { $0.alias == alias }
            s.pendingDatagramBytes -= mine.reduce(0) { $0 + $1.payload.count }
            return mine.map { ($0.group, $0.arrival, $0.payload) }
        }
        for (g, t, p) in drained { p.withUnsafeBytes { h(t, g, $0) } }
    }

    public func unregisterDatagramHandler(alias: UInt64) {
        state.withLock { $0.datagramHandlers[alias] = nil }
    }

    public func registerSubgroupHandler(alias: UInt64, _ h: @escaping SubgroupHandler) {
        let drained: [(MoQ.SubgroupHeader, UInt64, [UInt8])] = state.withLock { s in
            s.subgroupHandlers[alias] = h
            let mine = s.pendingObjects.filter { $0.0.trackAlias == alias }
            s.pendingObjects.removeAll { $0.0.trackAlias == alias }
            return mine
        }
        for (hd, id, p) in drained { h(hd, id, p) }
    }

    // MARK: Send paths

    public func sendDatagram(_ bytes: [UInt8]) async throws {
        try await owned { [transport] in try await transport.datagrams().send(bytes) }
    }

    /// An outgoing subgroup stream on a client-opened unidirectional stream.
    public final class SubgroupSender: @unchecked Sendable {
        let stream: QUICTransport.Stream
        let writer: MoQ.SubgroupWriter
        unowned let session: MoQSession
        public let streamID: UInt64
        private var nextObjectID: UInt64 = 0

        init(stream: QUICTransport.Stream, writer: MoQ.SubgroupWriter, session: MoQSession) {
            self.stream = stream; self.writer = writer; self.session = session; self.streamID = stream.streamID
        }

        /// Writes the next object (ids 0, 1, 2 ...), header included the first time.
        @discardableResult
        public func write(_ payload: [UInt8]) async throws -> UInt64 {
            let id = nextObjectID
            nextObjectID += 1
            let bytes = writer.encode(objectID: id, payload: payload)
            try await session.owned { [stream] in try await stream.send(bytes) }
            return id
        }

        public func finish() async throws {
            try await session.owned { [stream] in try await stream.send([UInt8](), endOfStream: true) }
        }
    }

    public func openSubgroup(trackAlias: UInt64, groupID: UInt64 = 0, subgroupID: UInt64 = 0, priority: UInt8 = 0) async throws -> SubgroupSender {
        let stream = try await owned { [transport] in try await transport.openStream(bidirectional: false) }
        return SubgroupSender(stream: stream, writer: MoQ.SubgroupWriter(trackAlias: trackAlias, groupID: groupID, subgroupID: subgroupID, priority: priority), session: self)
    }

    // MARK: Control loop

    /// Reads one framed control message. A cancelled receive comes back as
    /// an empty end-of-stream, so cancellation is checked before that is
    /// read as the peer closing.
    private func readFramed() async throws -> MoQ.Framed {
        guard let stream = control else { throw closedError ?? TransportError.notConnected }
        while true {
            if let (f, n) = try MoQ.parseFrame(readBuf) {
                readBuf.removeFirst(n)
                return f
            }
            let m = try await stream.receive(atLeast: 1, atMost: 65536)
            try Task.checkCancellation()
            readBuf.append(contentsOf: m.content)
            if m.content.isEmpty && m.metadata.endOfStream { throw closedError ?? TransportError.controlStreamClosed }
        }
    }

    private func waitFor(_ types: [UInt64]) async throws -> MoQ.Framed {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<MoQ.Framed, Error>) in
            let closed: Error? = self.state.withLock { s in
                if let e = s.closed { return e }
                s.waiters.append(Waiter(types: Set(types), cont: c))
                return nil
            }
            if let e = closed { c.resume(throwing: e) }
        }
    }

    private func controlLoop() async {
        do {
            while !Task.isCancelled {
                let f = try await readFramed()
                let waiter: Waiter? = state.withLock { s in
                    guard let i = s.waiters.firstIndex(where: { $0.types.contains(f.type) }) else { return nil }
                    return s.waiters.remove(at: i)
                }
                if let w = waiter { w.cont.resume(returning: f); continue }
                do { try await handle(f) } catch { log("control: handler error for 0x\(String(f.type, radix: 16)): \(error)") }
            }
        } catch {
            if !(error is CancellationError) { teardown(error) }
        }
    }

    private func handle(_ f: MoQ.Framed) async throws {
        guard let stream = control else { return }
        switch MoQ.MessageType(rawValue: f.type) {
        case .subscribe:
            let sub = try MoQ.parseIncomingSubscribe(f.body)
            let alias: UInt64 = state.withLock { s in defer { s.nextIncomingAlias += 1 }; return s.nextIncomingAlias }
            try await stream.send(try MoQ.subscribeOk(requestID: sub.requestID, trackAlias: alias))
            log("server SUBSCRIBE \(sub.namespace.joined(separator: "/")) \(sub.track) request \(sub.requestID) -> alias \(alias)")
            let hit: [IncomingWaiter] = state.withLock { s in
                s.incoming[alias] = sub
                let h = s.incomingWaiters.filter { $0.match(sub) }
                s.incomingWaiters.removeAll { $0.match(sub) }
                return h
            }
            for w in hit { w.cont.resume(returning: alias) }
        case .announce:
            try await stream.send(try MoQ.requestIDOnly(.announceOk, requestID: try MoQ.parseRequestID(f.body)))
        case .subscribeAnnounces:
            try await stream.send(try MoQ.requestIDOnly(.subscribeAnnouncesOk, requestID: try MoQ.parseRequestID(f.body)))
        case .publishDone:
            var r = ByteReader(f.body)
            let rid = try r.varint(); let status = try r.varint()
            log("PUBLISH_DONE request \(rid) status \(status)")
        case .maxRequestID:
            log("MAX_REQUEST_ID \(try MoQ.parseRequestID(f.body))")
        case .goaway:
            log("GOAWAY")
        default:
            log("ignoring control message 0x\(String(f.type, radix: 16)) (\(f.body.count) bytes)")
        }
    }

    // MARK: Datagram loop

    private static let pendingDatagramCap = 1 << 20

    private func datagramLoop() async {
        do {
            let dg = try await transport.datagrams()
            while !Task.isCancelled {
                let m = try await dg.receive()
                let arrival = ArrivalClock.nowNS()
                if Task.isCancelled { break }
                m.content.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                    guard let d = MoQ.parseObjectDatagram(b), !d.isStatus else { return }
                    let payload = UnsafeRawBufferPointer(rebasing: b[d.payloadOffset...])
                    let h: DatagramHandler? = state.withLock { $0.datagramHandlers[d.trackAlias] }
                    if let h {
                        h(arrival, d.groupID, payload)
                    } else {
                        let copy = Array(payload)
                        state.withLock { s in
                            s.pendingDatagrams.append((d.trackAlias, d.groupID, arrival, copy))
                            s.pendingDatagramBytes += copy.count
                            while s.pendingDatagramBytes > Self.pendingDatagramCap, !s.pendingDatagrams.isEmpty {
                                s.pendingDatagramBytes -= s.pendingDatagrams.removeFirst().payload.count
                            }
                        }
                    }
                }
            }
        } catch {
            if !(error is CancellationError) { log("datagram loop ended: \(error)") }
        }
    }

    // MARK: Inbound streams

    private static let pendingObjectCap = 512

    private func inboundLoop() async {
        do {
            try await transport.inboundStreams { [self] stream in
                self.log("inbound stream \(stream.streamID) \(stream.directionality == .unidirectional ? "uni" : "bidi")")
                let parser = MoQ.SubgroupParser()
                var header: MoQ.SubgroupHeader?
                while !Task.isCancelled {
                    let m = try await stream.receive(atLeast: 1, atMost: 65536)
                    if Task.isCancelled { break }
                    let events = try m.content.withUnsafeBytes { try parser.feed($0) }
                    for e in events {
                        switch e {
                        case .header(let h):
                            header = h
                            self.log("subgroup stream \(stream.streamID): alias \(h.trackAlias) group \(h.groupID) subgroup \(h.subgroupID)")
                        case .object(let id, let payload):
                            if let h = header { self.route(h, id, payload) }
                        }
                    }
                    if m.metadata.endOfStream { break }
                }
                self.log("inbound stream \(stream.streamID) ended")
            }
        } catch {
            if !(error is CancellationError) { log("inbound loop ended: \(error)") }
        }
    }

    private func route(_ h: MoQ.SubgroupHeader, _ id: UInt64, _ payload: [UInt8]) {
        let handler: SubgroupHandler? = state.withLock { s in
            if let x = s.subgroupHandlers[h.trackAlias] { return x }
            if s.pendingObjects.count < Self.pendingObjectCap { s.pendingObjects.append((h, id, payload)) }
            return nil
        }
        handler?(h, id, payload)
    }
}
#endif
