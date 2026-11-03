// The MoQ Transport subset the LASA wire rides, draft-16 as the server's
// moqtransport fork speaks it. Pure Swift, tested on macOS.
//
// Reference: lasa/typescript/src/transport/moq-transport.ts and
// subgroups.ts (the hand-rolled TypeScript codec this mirrors), and the
// fork's internal/wire package for the byte layouts.
//
// Control messages: [type varint][length u16 big-endian][body].
// Parameters (KVP lists): [count][delta-type, value]... sorted ascending
// by type, each type written as its delta from the previous; even types
// carry a bare varint, odd types length-prefixed bytes.

import Foundation

public enum WireError: Error, CustomStringConvertible, Sendable {
    case truncated
    case badFrame(String)
    case tooLong(Int)

    public var description: String {
        switch self {
        case .truncated: return "truncated"
        case .badFrame(let s): return "bad frame: \(s)"
        case .tooLong(let n): return "control message body \(n) bytes exceeds 65535"
        }
    }
}

// MARK: - Byte helpers

public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8]
    public init(capacity: Int = 64) { bytes = []; bytes.reserveCapacity(capacity) }

    public mutating func varint(_ v: UInt64) { Varint.encode(v, into: &bytes) }
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16BE(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xff)) }
    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func raw(_ b: UnsafeRawBufferPointer) { bytes.append(contentsOf: b) }
    public mutating func prefixed(_ b: [UInt8]) { varint(UInt64(b.count)); raw(b) }
    public mutating func string(_ s: String) { prefixed(Array(s.utf8)) }
}

public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public var offset: Int
    public init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func varint() throws -> UInt64 {
        guard let v = Varint.decode(bytes, offset: &offset) else { throw WireError.truncated }
        return v
    }
    public mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }
    public mutating func raw(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw WireError.truncated }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
    public mutating func prefixed() throws -> [UInt8] {
        let n = try varint()
        guard n <= UInt64(remaining) else { throw WireError.truncated }
        return try raw(Int(n))
    }
    public mutating func string() throws -> String {
        String(decoding: try prefixed(), as: UTF8.self)
    }
}

// MARK: - Key-value parameters

public enum KVPValue: Equatable, Sendable {
    case varint(UInt64)
    case bytes([UInt8])
}

public struct KVP: Equatable, Sendable {
    public var type: UInt64
    public var value: KVPValue
    public init(_ type: UInt64, _ value: KVPValue) { self.type = type; self.value = value }
    public init(_ type: UInt64, bytes: [UInt8]) { self.init(type, .bytes(bytes)) }
    public init(_ type: UInt64, varint: UInt64) { self.init(type, .varint(varint)) }
}

public enum MoQ: Sendable {
    public enum MessageType: UInt64, Sendable {
        case subscribeUpdate = 0x02
        case subscribe = 0x03
        case subscribeOk = 0x04
        case subscribeError = 0x05
        case announce = 0x06
        case announceOk = 0x07
        case announceError = 0x08
        case unannounce = 0x09
        case unsubscribe = 0x0a
        case publishDone = 0x0b
        case goaway = 0x10
        case subscribeAnnounces = 0x11
        case subscribeAnnouncesOk = 0x12
        case maxRequestID = 0x15
        case clientSetup = 0x20
        case serverSetup = 0x21
    }

    // Setup parameter keys.
    public static let setupParamPath: UInt64 = 0x01            // odd, bytes
    public static let setupParamMaxRequestID: UInt64 = 0x02    // even, varint

    // SUBSCRIBE / SUBSCRIBE_OK parameter keys (draft-16).
    public static let subParamForward: UInt64 = 0x10
    public static let subParamPriority: UInt64 = 0x20
    public static let subParamFilter: UInt64 = 0x21
    public static let subParamGroupOrder: UInt64 = 0x22
    public static let subOkParamExpires: UInt64 = 0x08
    public static let subOkParamLargest: UInt64 = 0x09

    public static let filterLatestGroup: UInt64 = 0x01
    public static let filterLatestObject: UInt64 = 0x02

    /// The 16-bit control message length prefix bounds every control
    /// message body, in every implementation.
    public static let maxControlBody = 65535

    // MARK: Parameters

    public static func encodeParams(_ params: [KVP], into w: inout ByteWriter) {
        let sorted = params.sorted { $0.type < $1.type }
        w.varint(UInt64(sorted.count))
        var prev: UInt64 = 0
        for p in sorted {
            w.varint(p.type - prev)
            prev = p.type
            switch p.value {
            case .bytes(let b):
                w.prefixed(b)
            case .varint(let v):
                w.varint(v)
            }
        }
    }

    public static func decodeParams(_ r: inout ByteReader) throws -> [UInt64: KVPValue] {
        let count = try r.varint()
        var out: [UInt64: KVPValue] = [:]
        var prev: UInt64 = 0
        for _ in 0..<count {
            let type = prev + (try r.varint())
            prev = type
            if type % 2 == 1 {
                out[type] = .bytes(try r.prefixed())
            } else {
                out[type] = .varint(try r.varint())
            }
        }
        return out
    }

    // MARK: Control framing

    /// [type varint][length u16 BE][body]. Throws when the body cannot be
    /// described by the 16-bit length.
    public static func frame(_ type: MessageType, body: [UInt8]) throws -> [UInt8] {
        guard body.count <= maxControlBody else { throw WireError.tooLong(body.count) }
        return frameUnchecked(type, body: body)
    }

    /// The same framing with the length truncated to 16 bits. Only for the
    /// S1 oversize probe, which sends a body the framing cannot describe
    /// and expects the server to reject it.
    public static func frameUnchecked(_ type: MessageType, body: [UInt8]) -> [UInt8] {
        var w = ByteWriter(capacity: body.count + 10)
        w.varint(type.rawValue)
        w.u16BE(UInt16(truncatingIfNeeded: body.count))
        w.raw(body)
        return w.bytes
    }

    public struct Framed: Sendable {
        public var type: UInt64
        public var body: [UInt8]
    }

    /// Parses one framed message from the front of `buf`, returning it and
    /// the bytes consumed, or nil when more bytes are needed.
    public static func parseFrame(_ buf: [UInt8]) throws -> (Framed, Int)? {
        var r = ByteReader(buf)
        guard buf.count >= 3 else { return nil }
        guard let type = Varint.decode(buf, offset: &r.offset) else { return nil }
        guard r.remaining >= 2 else { return nil }
        let hi = try r.u8(), lo = try r.u8()
        let length = Int(hi) << 8 | Int(lo)
        guard r.remaining >= length else { return nil }
        let body = try r.raw(length)
        return (Framed(type: type, body: body), r.offset)
    }

    // MARK: CLIENT_SETUP / SERVER_SETUP

    /// Draft-16 CLIENT_SETUP: no version list, no role; a parameter list
    /// only. `extra` carries application parameters such as LASA's
    /// Connection Config.
    /// `path` is the PATH parameter, required by the server over raw QUIC
    /// (the fork's validatePathParameter) and forbidden over WebTransport.
    public static func clientSetupBody(maxRequestID: UInt64? = 100, path: String? = "/", extra: [KVP]) -> [UInt8] {
        var params = extra
        if let m = maxRequestID { params.append(KVP(setupParamMaxRequestID, varint: m)) }
        if let p = path { params.append(KVP(setupParamPath, bytes: Array(p.utf8))) }
        var w = ByteWriter(capacity: 32)
        encodeParams(params, into: &w)
        return w.bytes
    }

    public static func clientSetup(maxRequestID: UInt64? = 100, path: String? = "/", extra: [KVP]) throws -> [UInt8] {
        try frame(.clientSetup, body: clientSetupBody(maxRequestID: maxRequestID, path: path, extra: extra))
    }

    /// Draft-16 SERVER_SETUP is a parameter list only.
    public static func parseServerSetup(_ body: [UInt8]) throws -> [UInt64: KVPValue] {
        var r = ByteReader(body)
        return try decodeParams(&r)
    }

    // MARK: SUBSCRIBE and its replies

    /// Body: request id, namespace tuple, track name, parameters. The
    /// defaults are the fork's own (priority 128, ascending, forward 1,
    /// latest group), as the TypeScript client sends them.
    public static func subscribe(requestID: UInt64, namespace: [String], track: String,
                                 filter: UInt64 = filterLatestGroup, extra: [KVP] = []) throws -> [UInt8] {
        var w = ByteWriter(capacity: 64)
        w.varint(requestID)
        w.varint(UInt64(namespace.count))
        for part in namespace { w.string(part) }
        w.string(track)
        var params: [KVP] = [
            KVP(subParamPriority, varint: 128),
            KVP(subParamGroupOrder, varint: 1),
            KVP(subParamForward, varint: 1),
        ]
        var f = ByteWriter(capacity: 2)
        f.varint(filter)
        params.append(KVP(subParamFilter, bytes: f.bytes))
        params.append(contentsOf: extra)
        encodeParams(params, into: &w)
        return try frame(.subscribe, body: w.bytes)
    }

    public struct SubscribeOk: Sendable {
        public var requestID: UInt64
        public var trackAlias: UInt64
        public var params: [UInt64: KVPValue]
    }

    public static func parseSubscribeOk(_ body: [UInt8]) throws -> SubscribeOk {
        var r = ByteReader(body)
        let rid = try r.varint()
        let alias = try r.varint()
        let params = try decodeParams(&r)
        return SubscribeOk(requestID: rid, trackAlias: alias, params: params)
    }

    public struct SubscribeError: Error, CustomStringConvertible, Sendable {
        public var requestID: UInt64
        public var code: UInt64
        public var retryMS: UInt64
        public var reason: String
        public var description: String { "SUBSCRIBE_ERROR request \(requestID) code 0x\(String(code, radix: 16)) \(reason)" }
    }

    public static func parseSubscribeError(_ body: [UInt8]) throws -> SubscribeError {
        var r = ByteReader(body)
        let rid = try r.varint()
        let code = try r.varint()
        let retry = try r.varint()
        let reason = try r.string()
        return SubscribeError(requestID: rid, code: code, retryMS: retry, reason: reason)
    }

    public struct IncomingSubscribe: Sendable {
        public var requestID: UInt64
        public var namespace: [String]
        public var track: String
        public var params: [UInt64: KVPValue]
    }

    /// A SUBSCRIBE the server sends for one of our tracks.
    public static func parseIncomingSubscribe(_ body: [UInt8]) throws -> IncomingSubscribe {
        var r = ByteReader(body)
        let rid = try r.varint()
        let n = try r.varint()
        var ns: [String] = []
        for _ in 0..<n { ns.append(try r.string()) }
        let track = try r.string()
        let params = r.isAtEnd ? [:] : try decodeParams(&r)
        return IncomingSubscribe(requestID: rid, namespace: ns, track: track, params: params)
    }

    /// Our SUBSCRIBE_OK for the server's subscription: request id, the
    /// alias we assign, and an empty parameter list.
    public static func subscribeOk(requestID: UInt64, trackAlias: UInt64) throws -> [UInt8] {
        var w = ByteWriter(capacity: 8)
        w.varint(requestID)
        w.varint(trackAlias)
        encodeParams([], into: &w)
        return try frame(.subscribeOk, body: w.bytes)
    }

    public static func parseRequestID(_ body: [UInt8]) throws -> UInt64 {
        var r = ByteReader(body)
        return try r.varint()
    }

    public static func requestIDOnly(_ type: MessageType, requestID: UInt64) throws -> [UInt8] {
        var w = ByteWriter(capacity: 8)
        w.varint(requestID)
        return try frame(type, body: w.bytes)
    }

    // MARK: OBJECT_DATAGRAM

    public struct ObjectDatagram: Sendable {
        public var trackAlias: UInt64
        public var groupID: UInt64
        public var objectID: UInt64
        public var priority: UInt8
        /// Offset of the payload within the datagram. Status datagrams
        /// (types 0x02, 0x03) carry no payload and are reported with
        /// `isStatus`.
        public var payloadOffset: Int
        public var isStatus: Bool
    }

    /// [type][alias][group][object][priority u8][ext length + bytes if
    /// type bit 0][payload]. Non-allocating: the caller slices the payload
    /// from `payloadOffset`.
    @inline(__always)
    public static func parseObjectDatagram(_ b: UnsafeRawBufferPointer) -> ObjectDatagram? {
        var off = 0
        guard let type = Varint.decode(b, offset: &off),
              let alias = Varint.decode(b, offset: &off),
              let group = Varint.decode(b, offset: &off),
              let object = Varint.decode(b, offset: &off),
              off < b.count else { return nil }
        let priority = b[off]
        off += 1
        if type & 0x01 != 0 {
            guard let extLen = Varint.decode(b, offset: &off), off + Int(extLen) <= b.count else { return nil }
            off += Int(extLen)
        }
        return ObjectDatagram(trackAlias: alias, groupID: group, objectID: object, priority: priority,
                              payloadOffset: off, isStatus: type & 0x02 != 0)
    }

    /// Writes a type-0x00 datagram (no extension headers) into `out`.
    public static func encodeObjectDatagram(into out: inout [UInt8], trackAlias: UInt64, groupID: UInt64,
                                            objectID: UInt64, priority: UInt8, payload: UnsafeRawBufferPointer) {
        out.removeAll(keepingCapacity: true)
        Varint.encode(0x00, into: &out)
        Varint.encode(trackAlias, into: &out)
        Varint.encode(groupID, into: &out)
        Varint.encode(objectID, into: &out)
        out.append(priority)
        out.append(contentsOf: payload)
    }

    // MARK: Subgroup streams

    /// The stream type the fork writes: explicit subgroup id, extension
    /// headers present (length 0 when none), priority byte.
    public static let streamTypeSubgroupSIDExt: UInt64 = 0x15

    public struct SubgroupHeader: Equatable, Sendable {
        public var trackAlias: UInt64
        public var groupID: UInt64
        public var subgroupID: UInt64
        public var priority: UInt8
        public var endOfGroup: Bool
    }

    public static func subgroupHeader(trackAlias: UInt64, groupID: UInt64, subgroupID: UInt64, priority: UInt8) -> [UInt8] {
        var w = ByteWriter(capacity: 16)
        w.varint(streamTypeSubgroupSIDExt)
        w.varint(trackAlias)
        w.varint(groupID)
        w.varint(subgroupID)
        w.u8(priority)
        return w.bytes
    }

    /// One object on a subgroup stream: [id delta][ext length 0][payload
    /// length][payload]. Object ids are delta-encoded: the first delta is
    /// the id, each later one is id − previous − 1.
    public static func subgroupObject(delta: UInt64, payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter(capacity: payload.count + 8)
        w.varint(delta)
        w.varint(0)
        w.prefixed(payload)
        if payload.isEmpty { w.varint(0) } // object status: normal
        return w.bytes
    }

    /// Outgoing subgroup stream state: header on first write, delta ids.
    public final class SubgroupWriter {
        public let trackAlias: UInt64, groupID: UInt64, subgroupID: UInt64, priority: UInt8
        private var headerSent = false
        private var count: UInt64 = 0
        private var prev: UInt64 = 0

        public init(trackAlias: UInt64, groupID: UInt64 = 0, subgroupID: UInt64 = 0, priority: UInt8 = 0) {
            self.trackAlias = trackAlias; self.groupID = groupID; self.subgroupID = subgroupID; self.priority = priority
        }

        /// The bytes to send for `objectID`, header included the first time.
        public func encode(objectID: UInt64, payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            if !headerSent {
                out = MoQ.subgroupHeader(trackAlias: trackAlias, groupID: groupID, subgroupID: subgroupID, priority: priority)
                headerSent = true
            }
            let delta = count == 0 ? objectID : objectID - prev - 1
            prev = objectID
            count += 1
            out.append(contentsOf: MoQ.subgroupObject(delta: delta, payload: payload))
            return out
        }
    }

    public enum SubgroupEvent: Equatable, Sendable {
        case header(SubgroupHeader)
        case object(objectID: UInt64, payload: [UInt8])
    }

    /// Incremental parser for an incoming subgroup stream. Feed it bytes as
    /// they arrive; it returns every complete event and keeps the rest.
    public final class SubgroupParser {
        private var buf: [UInt8] = []
        private var header: SubgroupHeader?
        private var ext = false
        private var sidIsFirstObject = false
        private var first = true
        private var prev: UInt64 = 0

        public init() {}

        public func feed(_ bytes: UnsafeRawBufferPointer) throws -> [SubgroupEvent] {
            buf.append(contentsOf: bytes)
            var events: [SubgroupEvent] = []
            var consumed = 0
            while true {
                var r = ByteReader(buf, offset: consumed)
                if header == nil {
                    guard let type = Varint.decode(buf, offset: &r.offset) else { break }
                    let low = type & ~0x20
                    guard low >= 0x10, low <= 0x1d, (low & 0x06) != 0x06 else {
                        throw WireError.badFrame("not a subgroup stream (type 0x\(String(type, radix: 16)))")
                    }
                    let explicitSid = low == 0x14 || low == 0x15 || low == 0x1c || low == 0x1d
                    sidIsFirstObject = low == 0x12 || low == 0x13 || low == 0x1a || low == 0x1b
                    ext = (low & 0x01) != 0
                    guard let alias = Varint.decode(buf, offset: &r.offset),
                          let group = Varint.decode(buf, offset: &r.offset) else { break }
                    var sid: UInt64 = 0
                    if explicitSid {
                        guard let s = Varint.decode(buf, offset: &r.offset) else { break }
                        sid = s
                    }
                    var priority: UInt8 = 0
                    if type & 0x20 == 0 {
                        guard r.offset < buf.count else { break }
                        priority = buf[r.offset]; r.offset += 1
                    }
                    let h = SubgroupHeader(trackAlias: alias, groupID: group, subgroupID: sid, priority: priority, endOfGroup: low >= 0x18)
                    header = h
                    events.append(.header(h))
                    consumed = r.offset
                    continue
                }
                guard let delta = Varint.decode(buf, offset: &r.offset) else { break }
                let objectID = first ? delta : prev + delta + 1
                if ext {
                    guard let extLen = Varint.decode(buf, offset: &r.offset), r.offset + Int(extLen) <= buf.count else { break }
                    r.offset += Int(extLen)
                }
                guard let plen = Varint.decode(buf, offset: &r.offset) else { break }
                var payload: [UInt8] = []
                if plen == 0 {
                    guard Varint.decode(buf, offset: &r.offset) != nil else { break } // object status
                } else {
                    guard r.offset + Int(plen) <= buf.count else { break }
                    payload = Array(buf[r.offset..<r.offset + Int(plen)])
                    r.offset += Int(plen)
                }
                if first && sidIsFirstObject, var h = header {
                    h.subgroupID = objectID; header = h
                }
                first = false
                prev = objectID
                events.append(.object(objectID: objectID, payload: payload))
                consumed = r.offset
            }
            if consumed > 0 { buf.removeFirst(consumed) }
            return events
        }
    }
}
