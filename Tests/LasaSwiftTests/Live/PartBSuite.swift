// Part B gates S1 and S2 (plan §5.4, §5.5) and the S3 (a) receive
// smoke, as one procedure the Mac tests and the Probe app's Part B
// screen both run, so a phone result is the same steps as the Mac's
// (plan §1.6: a Mac result goes into §7 only once repeated on a device).
//
// Each step logs its "[partB]" lines through `log`, and throws
// `Failure` on a check the XCTest version asserted.

import Foundation
@testable import LasaSwift

#if canImport(Network)

@available(iOS 26.0, macOS 26.0, *)
public final class PartBSuite: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    public let address: String
    /// Prefix of the client and entity ids, so a phone run is told from a
    /// Mac run in the server's logs.
    public let idPrefix: String
    public let log: @Sendable (String) -> Void
    public let sessionLog: @Sendable (String) -> Void

    public init(address: String, idPrefix: String = "swift",
                log: @escaping @Sendable (String) -> Void,
                sessionLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.address = address
        self.idPrefix = idPrefix
        self.log = log
        self.sessionLog = sessionLog
    }

    func ids(_ tag: String) -> (String, String) {
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let c = "\(idPrefix)-\(tag)-\(stamp)"
        return (c, c + "-e")
    }

    func makeClient(_ tag: String, pad: Int = 0) -> LasaClient {
        let (c, e) = ids(tag)
        var o = LasaClient.Options(address: address, clientID: c, entityID: e)
        if pad > 0 {
            // The S1 size probe: 1 KiB values under short attr names on a
            // second entity; each lands as one state key.
            let chunk = String(repeating: "x", count: 1024)
            let n = max(1, pad / (chunk.count + 24))
            var a: [String: String] = [:]
            for i in 0..<n { a[String(format: "pad-%03d", i)] = chunk }
            o.extraEntities = [Lasa.Entity(id: e + "-pad", name: "pad", hears: nil, attrs: a)]
        }
        o.log = sessionLog
        return LasaClient(o)
    }

    func check(_ ok: Bool, _ message: @autoclosure () -> String) throws {
        if !ok { throw Failure(message()) }
    }

    static func ms(_ v: Double) -> String { String(format: "%.1f", v) }

    // MARK: S1

    /// Dial, ALPN, default verification, a plain config; a config near
    /// 60 KiB; one past 64 KiB that the server must reject; then the
    /// fresh redials that follow a server-failed connection (plan §7.5).
    public func s1() async throws {
        // Steps 1 and 2.
        let client = makeClient("s1")
        try await client.connect()
        guard let h = client.handshake else { throw Failure("no handshake result") }
        log("S1 handshake \(Self.ms(h.handshakeMS)) ms, ALPN \(h.negotiatedALPN ?? "nil"), usable datagram frame \(h.usableDatagramFrameSize), remote idle \(h.remoteIdleTimeoutMS) ms, remote max streams bidi \(h.remoteMaxStreamsBidirectional) uni \(h.remoteMaxStreamsUnidirectional)")
        log("S1 control stream id \(client.session.controlStreamID), config \(client.configBytes) bytes, SERVER_SETUP params \(client.serverSetup)")
        try check(h.negotiatedALPN == "moqt-16", "negotiated ALPN \(h.negotiatedALPN ?? "nil"), not moqt-16")
        // usableDatagramFrameSize reads 0 on this API even when datagrams are
        // negotiated (plan §7.3); the datagram path is proven by S3 (a).
        client.close()

        // Step 3a: a config near 60 KiB.
        let big = makeClient("s1big", pad: 60_000)
        try await big.connect()
        log("S1 large config \(big.configBytes) bytes: SERVER_SETUP received, control stream \(big.session.controlStreamID)")
        try check(big.configBytes > 55_000 && big.configBytes < 65_000, "large config is \(big.configBytes) bytes, not near 60 KiB")
        big.close()

        // Step 3b: past 64 KiB, which the framing cannot describe; the
        // server must reject it rather than answer.
        let over = makeClient("s1over", pad: 70_000)
        let failedAt = Date()
        var answered = false
        do {
            try await over.connect(oversize: true)
            answered = true
        } catch {
            log("S1 oversize config \(over.configBytes) bytes rejected: \(error)")
        }
        over.close()
        try check(!answered, "oversize CLIENT_SETUP (\(over.configBytes) bytes) was answered with SERVER_SETUP")

        // After the server fails a connection, the process cannot open a new
        // tunnel to the same endpoint for about 3.4 s, and a dial begun inside
        // that window never completes (plan §7.5). The product's reconnect
        // path therefore redials fresh, briefly, until one opens. Measured
        // here so the suite carries the number and S2's dial is not caught
        // in the window.
        var attempts = 0
        while true {
            attempts += 1
            let again = makeClient("s1redial")
            do {
                try await again.connect(deadlineSeconds: 1)
                log("S1 redial after a failed connection: open on attempt \(attempts), \(Int(Date().timeIntervalSince(failedAt) * 1000)) ms after the failure")
                again.close()
                break
            } catch {
                again.close()
                if attempts >= 12 { throw Failure("no redial succeeded within 12 attempts: \(error)") }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: S2

    /// The control stream's id, the state sink delivered to a handler
    /// registered late, our state source with one SET echoed back, and
    /// the server's subscription to the entity source.
    public func s2() async throws {
        let client = makeClient("s2")
        try await client.connect()
        defer { client.close() }

        // Step 1: the control stream's id. The server takes the first
        // bidirectional stream it accepts as the control stream, and
        // SERVER_SETUP arrived on ours, so there was no phantom stream
        // ahead of it; the id says whether it was stream 0 outright.
        log("S2 control stream id \(client.session.controlStreamID)")
        try check(client.session.controlStreamID == 0, "control stream is not QUIC stream 0; check the server's accept order")

        // Step 2: subscribe the state sink, then register the handler
        // only after the lanes have had time to open and write, so the
        // router's pending buffer is exercised (the "after" ordering).
        let seen = Locked<[(UInt64, UInt64, Lasa.DownstreamState)]>([])
        let gotSet = OneShot<UInt64>()
        let probeKey = client.attrKey("probe")
        let sub = try await client.subscribeStateSink(prefixes: ["lasa."])
        log("S2 state sink SUBSCRIBE_OK alias \(sub.trackAlias) in \(Self.ms(sub.roundTripMS)) ms")
        try await Task.sleep(nanoseconds: 300_000_000)
        client.session.registerSubgroupHandler(alias: sub.trackAlias) { h, id, payload in
            guard let m = try? Lasa.parseDownstream(payload) else { return }
            seen.with { $0.append((h.subgroupID, id, m)) }
            if case .set(let key, _, let seq) = m, key == probeKey { gotSet.set(.success(seq)) }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let early = seen.with { $0 }
        let lanes = Set(early.map { $0.0 })
        log("S2 state sink delivered \(early.count) objects on lanes \(lanes.sorted()) after late registration")
        try check(lanes.contains(1), "no catch-up lane (subgroup 1) objects arrived")
        try check(early.contains { if case .frontier = $0.2 { return true } else { return false } }, "no frontier arrived")

        // Step 3: the server's subscription to our state source, our
        // unidirectional stream, one SET, and the echo on the sink.
        let alias = try await client.stateSourceAlias()
        let t0 = DispatchTime.now().uptimeNanoseconds
        try await client.writeState([.set(key: probeKey, value: Array("\"s2\"".utf8))])
        log("S2 state source alias \(alias), subgroup stream id \(client.stateSourceStreamID ?? 0), SET written")
        let seq = try await within(seconds: 5, "SET echo") { try await gotSet.wait() }
        let t1 = DispatchTime.now().uptimeNanoseconds
        log("S2 SET round trip \(Self.ms(Double(t1 - t0) / 1e6)) ms, seq \(seq)")

        // The server's subscription to the entity's mono-object source
        // exists too (used by S3's send tests).
        let entityAlias = try await client.entitySourceAlias()
        log("S2 entity source alias \(entityAlias)")
    }

    // MARK: S3 (a) smoke: the datagram receive path

    public struct S3aResult: Sendable {
        public var packets: Int
        public var seconds: Int
        public var stoppedEarly: Bool
    }

    /// Subscribes the entity's binaural sink for `seconds` and counts the
    /// packets; `record` receives the arrival record if given. `progress`
    /// is called once a second with the elapsed seconds and the count so
    /// far. Cancelling the calling task ends the capture early, with the
    /// record still written; the pass check is only applied to a full run.
    public func s3a(seconds: Int, record: URL? = nil,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> S3aResult {
        let client = makeClient("s3a")
        try await client.connect()

        // Sized on wall time, not the sleep loop's count: on a locked phone
        // the loop runs late (305.7 s for a 300 s run on 2026-11-02) and the
        // server sends a little over 200 per second, so 200 * (seconds + 5)
        // dropped the last 116 packets of that run from the record.
        let rec = RecordWriter(maxRecords: 220 * (seconds + 30))
        let count = Locked(0)
        let sub = try await client.subscribeSink(entity: client.options.entityID, format: Lasa.trackBinaural) { arrival, seq, payload in
            guard let s = Lasa.splitSink(payload) else { return }
            rec.append(seq: seq, arrivalNS: arrival, serverUS: s.timestamp, payloadLen: UInt32(payload.count))
            count.with { $0 += 1 }
        }
        log("S3a binaural SUBSCRIBE_OK alias \(sub.trackAlias) in \(Self.ms(sub.roundTripMS)) ms")

        var elapsed = 0
        var stoppedEarly = false
        do {
            while elapsed < seconds {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                elapsed += 1
                progress?(elapsed, count.with { $0 })
            }
        } catch is CancellationError {
            stoppedEarly = true
        }
        // Close before reading the record so the receive loop is not
        // appending while the file is written.
        client.close()
        let n = count.with { $0 }
        log("S3a received \(n) packets in \(elapsed) s (\(n / max(elapsed, 1)) per second)\(stoppedEarly ? ", stopped early" : "")")
        if let record {
            try rec.flush(to: record)
            log("S3a record written to \(record.path)")
        }
        if !stoppedEarly {
            try check(n > 150 * seconds, "sink not continuous at 200 packets per second: \(n) in \(seconds) s")
        }
        return S3aResult(packets: n, seconds: elapsed, stoppedEarly: stoppedEarly)
    }

    // MARK: S3 (b) to (e): the send path

    public enum SendPayload: Sendable {
        /// A mono-object packet carrying a padded Opus silence frame; the
        /// server decodes silence (S3 (b)).
        case silence
        /// A packet the server discards on sight, reserved flag bit set
        /// (S3 (c), (d), (e)): the arrival record still stamps it.
        case discard
    }

    public struct SendResult: Sendable {
        public var sent = 0
        public var failed = 0
        public var seconds = 0.0
        public var size = 0
        public var datagramBytes = 0
        public var firstError: String?
        public var stoppedEarly = false
        public init() {}
    }

    /// Sends `rate` packets per second of `size` bytes on `client`'s
    /// entity source for `seconds`, each packet paced to its due time on
    /// a continuous clock and the loop catching up without sleeping when
    /// late (the product's uplink has no tick of its own; the pacing here
    /// stands in for the mic callback). A failed send is counted and the
    /// loop goes on; a dead session ends it. `record` receives the local
    /// send record (seq, send time, size), the sending end of the
    /// server's arrival record. Cancellation ends the loop early with
    /// the record kept.
    func send(_ client: LasaClient, alias: UInt64, rate: Int, size: Int, seconds: Double,
              payload: SendPayload, record: URL? = nil, seqStart: UInt64 = 0,
              progress: (@Sendable (Int, Int, Int) -> Void)? = nil) async throws -> SendResult {
        let body: [UInt8]
        switch payload {
        case .silence: body = Lasa.silencePacket(size: size)
        case .discard: body = Lasa.discardPacket(size: size)
        }
        let rec = RecordWriter(maxRecords: rate * (Int(seconds) + 10))
        var out = [UInt8]()
        out.reserveCapacity(size + 16)
        var r = SendResult()
        r.size = body.count
        var seq = seqStart
        let clock = ContinuousClock()
        let start = clock.now
        let end = start + .seconds(seconds)
        var nextReport = 1
        do {
            while clock.now < end {
                let due = start + .seconds(Double(seq - seqStart) / Double(rate))
                if due > clock.now { try await clock.sleep(until: due) }
                body.withUnsafeBytes {
                    MoQ.encodeObjectDatagram(into: &out, trackAlias: alias, groupID: seq, objectID: 0, priority: 0, payload: $0)
                }
                r.datagramBytes = out.count
                let now = ArrivalClock.nowNS()
                do {
                    try await client.session.sendDatagram(out)
                    r.sent += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    r.failed += 1
                    if r.firstError == nil { r.firstError = "\(error)" }
                    if let dead = client.session.closedError {
                        // The record so far is still the evidence (a phone
                        // suspended mid-run ends here, 2026-11-02).
                        r.seconds = start.duration(to: clock.now) / .seconds(1)
                        if let record { try? rec.flush(to: record) }
                        throw Failure("session died during send after \(Self.ms(r.seconds * 1000)) ms, \(r.sent) sent: \(dead)")
                    }
                }
                rec.append(seq: seq, arrivalNS: now, serverUS: 0, payloadLen: UInt32(body.count))
                seq += 1
                let secs = Int(start.duration(to: clock.now) / .seconds(1))
                if secs >= nextReport {
                    nextReport = secs + 1
                    progress?(secs, r.sent, r.failed)
                }
            }
        } catch is CancellationError {
            r.stoppedEarly = true
        }
        r.seconds = start.duration(to: clock.now) / .seconds(1)
        if let record { try rec.flush(to: record) }
        return r
    }

    func describe(_ what: String, _ r: SendResult) -> String {
        var s = "\(what) sent \(r.sent), failed \(r.failed), \(r.size)-byte packets (\(r.datagramBytes)-byte datagrams) in \(Self.ms(r.seconds * 1000)) ms"
        if r.sent > 0 { s += ", \(Int(Double(r.sent) / max(r.seconds, 0.001))) per second" }
        if r.stoppedEarly { s += ", stopped early" }
        if let e = r.firstError { s += ", first error: \(e)" }
        return s
    }

    /// Whether one `size`-byte payload sends (the stack refuses a
    /// datagram above its path limit).
    func trySend(_ client: LasaClient, alias: UInt64, size: Int) async throws -> (ok: Bool, datagramBytes: Int) {
        let body = Lasa.discardPacket(size: size)
        var out = [UInt8]()
        body.withUnsafeBytes {
            MoQ.encodeObjectDatagram(into: &out, trackAlias: alias, groupID: 0, objectID: 0, priority: 0, payload: $0)
        }
        do {
            try await client.session.sendDatagram(out)
            return (true, out.count)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (false, out.count)
        }
    }

    /// The largest payload the stack accepts for send, by bisection
    /// between 64 and 1,500 bytes, and the datagram size that makes.
    func sendLimit(_ client: LasaClient, alias: UInt64) async throws -> (payload: Int, datagram: Int) {
        var lo = 64, hi = 1500
        let first = try await trySend(client, alias: alias, size: lo)
        try check(first.ok, "even a \(lo)-byte datagram payload fails to send")
        var loDatagram = first.datagramBytes
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            let t = try await trySend(client, alias: alias, size: mid)
            if t.ok { lo = mid; loDatagram = t.datagramBytes } else { hi = mid }
        }
        return (lo, loDatagram)
    }

    /// S3 (b): the product's rate, 200 silence packets per second, ten
    /// minutes by default. The pass is read on the server's arrival
    /// record against the Go client's run; here, zero failed sends.
    public func s3b(seconds: Double = 600, size: Int = 120, record: URL? = nil,
                    progress: (@Sendable (Int, Int, Int) -> Void)? = nil) async throws -> SendResult {
        let client = makeClient("s3b")
        try await client.connect()
        defer { client.close() }
        let alias = try await client.entitySourceAlias()
        log("S3b entity \(client.options.entityID) alias \(alias): \(size)-byte silence packets at 200 per second for \(Int(seconds)) s")
        let r = try await send(client, alias: alias, rate: 200, size: size, seconds: seconds, payload: .silence, record: record, progress: progress)
        log(describe("S3b", r))
        if let record { log("S3b send record written to \(record.path)") }
        try await Task.sleep(nanoseconds: 1_000_000_000) // the tail reaches the server before the entity leaves
        if !r.stoppedEarly { try check(r.failed == 0, "\(r.failed) sends failed at the product's rate") }
        return r
    }

    /// S3 (c): 2,000 packets per second of 200 bytes for five minutes
    /// by default, the load that broke the legacy API. Pass: no send
    /// fails.
    public func s3c(seconds: Double = 300, record: URL? = nil,
                    progress: (@Sendable (Int, Int, Int) -> Void)? = nil) async throws -> SendResult {
        let client = makeClient("s3c")
        try await client.connect()
        defer { client.close() }
        let alias = try await client.entitySourceAlias()
        log("S3c entity \(client.options.entityID) alias \(alias): 200-byte discard packets at 2,000 per second for \(Int(seconds)) s")
        let r = try await send(client, alias: alias, rate: 2000, size: 200, seconds: seconds, payload: .discard, record: record, progress: progress)
        log(describe("S3c", r))
        if let record { log("S3c send record written to \(record.path)") }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if !r.stoppedEarly { try check(r.failed == 0, "\(r.failed) sends failed under load") }
        return r
    }

    /// S3 (e): the empirical datagram limit (the API's property reads 0,
    /// §7.3), whether the plan's 1,200-byte payload sends, then
    /// `seconds` of 200 per second at the limit so the server's record
    /// shows that size arriving intact.
    public func s3e(seconds: Double = 10, record: URL? = nil,
                    progress: (@Sendable (Int, Int, Int) -> Void)? = nil) async throws -> SendResult {
        let client = makeClient("s3e")
        try await client.connect()
        defer { client.close() }
        let alias = try await client.entitySourceAlias()
        let limit = try await sendLimit(client, alias: alias)
        log("S3e entity \(client.options.entityID): largest payload that sends \(limit.payload) bytes, a \(limit.datagram)-byte datagram; usableDatagramFrameSize reads \(client.handshake?.usableDatagramFrameSize ?? -1)")
        let t = try await trySend(client, alias: alias, size: 1200)
        log("S3e 1,200-byte payload (\(t.datagramBytes)-byte datagram): \(t.ok ? "sends" : "refused")")
        let r = try await send(client, alias: alias, rate: 200, size: limit.payload, seconds: seconds, payload: .discard, record: record, seqStart: 1, progress: progress)
        log(describe("S3e at the limit", r))
        if let record { log("S3e send record written to \(record.path)") }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if !r.stoppedEarly { try check(r.failed == 0, "\(r.failed) sends failed at the limit size") }
        return r
    }

    /// S3 (d): the ramp, 200, 500, 1,000, 2,000 and 5,000 packets per
    /// second of the largest payload under the limit (the plan's 1,200
    /// if it sends), `stepSeconds` each on one session. The pass is read
    /// on the server's record against the Go client's ramp from the same
    /// phone and the Mac's; here, each step's sends and failures.
    public func s3d(stepSeconds: Double = 60, recordDir: URL? = nil, stamp: String = "",
                    progress: (@Sendable (Int, Int, Int, Int) -> Void)? = nil) async throws -> [SendResult] {
        let client = makeClient("s3d")
        try await client.connect()
        defer { client.close() }
        let alias = try await client.entitySourceAlias()
        let limit = try await sendLimit(client, alias: alias)
        let size = min(1200, limit.payload)
        log("S3d entity \(client.options.entityID) alias \(alias): \(size)-byte discard packets, \(Int(stepSeconds)) s per step")
        var results: [SendResult] = []
        var seq: UInt64 = 1
        for rate in [200, 500, 1000, 2000, 5000] {
            let record = recordDir?.appendingPathComponent("s3d-send-\(rate)pps-\(stamp).rec")
            let r = try await send(client, alias: alias, rate: rate, size: size, seconds: stepSeconds, payload: .discard,
                                   record: record, seqStart: seq) { s, n, f in progress?(rate, s, n, f) }
            seq += UInt64(r.sent + r.failed)
            log(describe("S3d \(rate) per second:", r))
            results.append(r)
            if r.stoppedEarly { break }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return results
    }

    // MARK: Helpers

    /// Bound on a wait: cancels the waiting task when the time is up, so
    /// the wait ends as a failure rather than hanging the caller. The
    /// transport itself has no such timers (plan §7.5).
    func within<T: Sendable>(seconds: Double, _ what: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let work = Task { try await body() }
        let timer = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); work.cancel() }
        defer { timer.cancel() }
        do { return try await work.value } catch is CancellationError { throw Failure("\(what) did not complete in \(seconds) s") }
    }
}

#endif
