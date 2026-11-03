// The LASA state-plane wire codecs (lasa-core.md §6.5 to §6.7): state
// messages in both directions, the state subscribe parameter, cursors
// and the set-hash. Port of lasa/typescript/src/lasa/statewire.ts,
// 2026-11-03, byte-exact against the Go `lasa/wire` (the golden vectors
// in Tests/LasaSwiftTests/Fixtures/wire/lasa-wire.json).
//
// Divergences from the TypeScript, none of them visible on the wire:
// - `setHash` is synchronous (CryptoKit SHA-256, no WebCrypto promise).
// - Ops carry a non-optional `seq` (0 when the caller has none); the
//   upstream layout never writes it, so the TypeScript's "seq-less op
//   refused downstream" case cannot arise here. `Lasa.UpstreamState`
//   (Wire/LasaWire.swift) remains the seq-less client type and encodes
//   to the same bytes as `encodeStateMessage(_, .upstream)`.
// - A group's members are typed `StateOp` (set or clear only), so the
//   "groups may contain only set and clear" checks are the type system's.
// - `encodeSubscribeParams` checks the cursor's epoch and set-hash
//   lengths, which the Go fixes by array type and the TypeScript trusts.
// Byte helpers are the package's ByteWriter and ByteReader; errors are
// the package's WireError, with the TypeScript's message text.

import Foundation
import CryptoKit

public enum StateDirection: Sendable, Equatable {
    case upstream
    case downstream
}

/// `set` assigns `value` to `key`. `seq` is server-assigned and
/// meaningful downstream only.
public struct SetOp: Sendable, Equatable {
    public var key: String
    public var value: [UInt8]
    public var seq: UInt64

    public init(key: String, value: [UInt8], seq: UInt64 = 0) {
        self.key = key; self.value = value; self.seq = seq
    }
}

/// `clear` removes `key`. `seq` is server-assigned and meaningful
/// downstream only.
public struct ClearOp: Sendable, Equatable {
    public var key: String
    public var seq: UInt64

    public init(key: String, seq: UInt64 = 0) {
        self.key = key; self.seq = seq
    }
}

/// A group member: groups do not nest and carry only set and clear.
public enum StateOp: Sendable, Equatable {
    case set(SetOp)
    case clear(ClearOp)

    public var key: String {
        switch self {
        case .set(let s): return s.key
        case .clear(let c): return c.key
        }
    }
    public var seq: UInt64 {
        switch self {
        case .set(let s): return s.seq
        case .clear(let c): return c.seq
        }
    }
    var message: StateMessage {
        switch self {
        case .set(let s): return .set(s)
        case .clear(let c): return .clear(c)
        }
    }
}

/// The two catch-up payloads (lasa-core.md §6.5), with their wire bytes.
public enum BeginKind: UInt8, Sendable {
    case delta = 1
    case snapshot = 2
}

/// One state-track message: one per MoQ object.
public enum StateMessage: Sendable, Equatable {
    case set(SetOp)
    case clear(ClearOp)
    case group([StateOp])
    /// "Nothing further at or below seq on this path." Downstream only;
    /// epoch is `StateWire.epochSize` opaque bytes.
    case frontier(epoch: [UInt8], seq: UInt64)
    /// Opens a catch-up payload, closed by a frontier. Downstream only.
    case begin(BeginKind)

    public static func set(key: String, value: [UInt8], seq: UInt64 = 0) -> StateMessage {
        .set(SetOp(key: key, value: value, seq: seq))
    }
    public static func clear(key: String, seq: UInt64 = 0) -> StateMessage {
        .clear(ClearOp(key: key, seq: seq))
    }
}

/// A resume position in the space's state history (lasa-core.md §6.6),
/// earned by a completed catch-up.
public struct Cursor: Sendable, Equatable {
    public var epoch: [UInt8]    // StateWire.epochSize bytes
    public var seq: UInt64
    public var setHash: [UInt8]  // StateWire.setHashSize bytes

    public init(epoch: [UInt8], seq: UInt64, setHash: [UInt8]) {
        self.epoch = epoch; self.seq = seq; self.setHash = setHash
    }
}

public enum StateWire: Sendable {
    /// SUBSCRIBE parameter key carrying the state subscribe message.
    public static let subscribeParamState: UInt64 = Lasa.subscribeParamState
    public static let epochSize = 8
    public static let setHashSize = 32
    public static let maxValueLen = 65536
    public static let maxKeyLen = 512

    static let msgSet: UInt8 = 1
    static let msgClear: UInt8 = 2
    static let msgGroup: UInt8 = 3
    static let msgFrontier: UInt8 = 4
    static let msgBegin: UInt8 = 5
    static let subscribeFlagCursor: UInt8 = 1 << 0

    // MARK: Key and prefix grammar (lasa-core.md §2)

    /// Keys are [a-z0-9.-], 1 to 512 bytes.
    public static func isValidKey(_ s: String) -> Bool {
        let n = s.utf8.count
        return n >= 1 && n <= maxKeyLen && hasKeyChars(s)
    }

    /// Prefixes share the key grammar but may be empty (the
    /// subscribe-everything set, lasa-core.md §6.3).
    public static func isValidPrefix(_ s: String) -> Bool {
        s.utf8.count <= maxKeyLen && hasKeyChars(s)
    }

    private static func hasKeyChars(_ s: String) -> Bool {
        for c in s.utf8 {
            let ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2e || c == 0x2d
            if !ok { return false }
        }
        return true
    }

    // MARK: State messages

    public static func encodeStateMessage(_ m: StateMessage, _ dir: StateDirection) throws -> [UInt8] {
        var w = ByteWriter(capacity: 64)
        try appendStateMessage(&w, m, dir, allowGroup: true)
        return w.bytes
    }

    private static func appendKey(_ w: inout ByteWriter, _ key: String) throws {
        guard isValidKey(key) else { throw WireError.badFrame("invalid key") }
        w.string(key)
    }

    private static func appendStateMessage(_ w: inout ByteWriter, _ m: StateMessage, _ dir: StateDirection, allowGroup: Bool) throws {
        switch m {
        case .set(let op):
            guard op.value.count <= maxValueLen else { throw WireError.badFrame("value too long") }
            w.u8(msgSet)
            try appendKey(&w, op.key)
            w.prefixed(op.value)
            if dir == .downstream { w.varint(op.seq) }
        case .clear(let op):
            w.u8(msgClear)
            try appendKey(&w, op.key)
            if dir == .downstream { w.varint(op.seq) }
        case .group(let ops):
            guard allowGroup else { throw WireError.badFrame("groups do not nest") }
            w.u8(msgGroup)
            w.varint(UInt64(ops.count))
            for op in ops { try appendStateMessage(&w, op.message, dir, allowGroup: false) }
        case .frontier(let epoch, let seq):
            guard dir == .downstream else { throw WireError.badFrame("frontier is downstream-only") }
            guard epoch.count == epochSize else { throw WireError.badFrame("epoch must be \(epochSize) bytes") }
            w.u8(msgFrontier)
            w.raw(epoch)
            w.varint(seq)
        case .begin(let kind):
            guard dir == .downstream else { throw WireError.badFrame("begin is downstream-only") }
            w.u8(msgBegin)
            w.u8(kind.rawValue)
        }
    }

    /// Decodes exactly one state message for the given direction;
    /// trailing bytes are an error (one message per MoQ object).
    public static func parseStateMessage(_ data: [UInt8], _ dir: StateDirection) throws -> StateMessage {
        var r = ByteReader(data)
        let m = try parseOne(&r, dir, allowGroup: true)
        guard r.isAtEnd else { throw WireError.badFrame("trailing bytes after state message") }
        return m
    }

    // Parses a length-prefixed key, holding it to the §2 grammar and the
    // 512-byte cap, and erroring on truncation.
    private static func readKey(_ r: inout ByteReader) throws -> String {
        let klen = try r.varint()
        guard klen <= UInt64(maxKeyLen) else { throw WireError.badFrame("key too long") }
        guard Int(klen) <= r.remaining else { throw WireError.badFrame("truncated key") }
        let key = String(decoding: try r.raw(Int(klen)), as: UTF8.self)
        guard isValidKey(key) else { throw WireError.badFrame("invalid key") }
        return key
    }

    private static func readSeq(_ r: inout ByteReader, _ dir: StateDirection) throws -> UInt64 {
        dir == .downstream ? try r.varint() : 0
    }

    private static func parseOne(_ r: inout ByteReader, _ dir: StateDirection, allowGroup: Bool) throws -> StateMessage {
        guard !r.isAtEnd else { throw WireError.badFrame("empty state message") }
        let t = try r.u8()
        switch t {
        case msgSet:
            let key = try readKey(&r)
            let vlen = try r.varint()
            guard vlen <= UInt64(maxValueLen) else { throw WireError.badFrame("value too long") }
            guard Int(vlen) <= r.remaining else { throw WireError.badFrame("truncated value") }
            let value = try r.raw(Int(vlen))
            let seq = try readSeq(&r, dir)
            return .set(SetOp(key: key, value: value, seq: seq))
        case msgClear:
            let key = try readKey(&r)
            let seq = try readSeq(&r, dir)
            return .clear(ClearOp(key: key, seq: seq))
        case msgGroup:
            guard allowGroup else { throw WireError.badFrame("groups do not nest") }
            let count = try r.varint()
            var ops: [StateOp] = []
            for _ in 0..<count {
                switch try parseOne(&r, dir, allowGroup: false) {
                case .set(let s): ops.append(.set(s))
                case .clear(let c): ops.append(.clear(c))
                default: throw WireError.badFrame("groups may contain only set and clear ops")
                }
            }
            return .group(ops)
        case msgFrontier:
            guard dir == .downstream else { throw WireError.badFrame("frontier is downstream-only") }
            guard r.remaining >= epochSize else { throw WireError.badFrame("truncated epoch") }
            let epoch = try r.raw(epochSize)
            let seq = try r.varint()
            return .frontier(epoch: epoch, seq: seq)
        case msgBegin:
            guard dir == .downstream else { throw WireError.badFrame("begin is downstream-only") }
            guard !r.isAtEnd else { throw WireError.badFrame("truncated begin") }
            guard let kind = BeginKind(rawValue: try r.u8()) else { throw WireError.badFrame("unknown begin kind") }
            return .begin(kind)
        default:
            throw WireError.badFrame("unknown state message type \(t)")
        }
    }

    // MARK: Subscribe params

    /// Canonical prefix set: validated against the §2 grammar (empty
    /// allowed), deduplicated, sorted bytewise. Validation keeps the sort
    /// bytewise by construction: a valid prefix is ASCII.
    public static func canonicalPrefixes(_ prefixes: [String]) throws -> [String] {
        for p in prefixes {
            guard isValidPrefix(p) else { throw WireError.badFrame("invalid prefix \"\(p)\"") }
        }
        var seen = Set<String>()
        var out: [String] = []
        for p in prefixes where seen.insert(p).inserted { out.append(p) }
        return out.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// The state subscribe parameter: flags, the canonical prefix set,
    /// and the cursor block when resuming (lasa-core.md §6.7).
    public static func encodeSubscribeParams(_ prefixes: [String], cursor: Cursor? = nil) throws -> [UInt8] {
        let canon = try canonicalPrefixes(prefixes)
        guard !canon.isEmpty else { throw WireError.badFrame("empty prefix set is a protocol error") }
        if let c = cursor {
            guard c.epoch.count == epochSize else { throw WireError.badFrame("cursor epoch must be \(epochSize) bytes") }
            guard c.setHash.count == setHashSize else { throw WireError.badFrame("cursor set-hash must be \(setHashSize) bytes") }
        }
        var w = ByteWriter(capacity: 64)
        w.u8(cursor != nil ? subscribeFlagCursor : 0)
        w.varint(UInt64(canon.count))
        for p in canon { w.string(p) }
        if let c = cursor {
            w.raw(c.epoch)
            w.varint(c.seq)
            w.raw(c.setHash)
        }
        return w.bytes
    }

    /// The cursor set-hash (lasa-core.md §6.6): SHA-256 over the
    /// canonical encoding [len varint][prefix bytes]... .
    public static func setHash(_ prefixes: [String]) throws -> [UInt8] {
        var w = ByteWriter(capacity: 64)
        for p in try canonicalPrefixes(prefixes) { w.string(p) }
        return Array(SHA256.hash(data: w.bytes))
    }
}

extension Lasa.UpstreamState {
    /// The same message as a `StateMessage` (seq 0), for encoding
    /// alongside server-authored messages. Groups never nest; a nested
    /// group's ops are flattened into the parent rather than lost.
    public var stateMessage: StateMessage {
        switch self {
        case .set(let key, let value): return .set(SetOp(key: key, value: value))
        case .clear(let key): return .clear(ClearOp(key: key))
        case .group(let ops): return .group(ops.flatMap { $0.stateOps })
        }
    }

    private var stateOps: [StateOp] {
        switch self {
        case .set(let key, let value): return [.set(SetOp(key: key, value: value))]
        case .clear(let key): return [.clear(ClearOp(key: key))]
        case .group(let ops): return ops.flatMap { $0.stateOps }
        }
    }
}
