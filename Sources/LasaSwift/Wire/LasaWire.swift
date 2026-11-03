// The LASA wire over MoQ (lasa-core.md §3, §4.1, §5.1, §6.7): namespaces,
// the Connection Config setup parameter, the sink packet header, the
// state messages and the state subscribe parameter. Pure Swift, tested on
// macOS against the vectors in lasa/typescript/tests/vectors.

import Foundation

public enum Lasa: Sendable {
    public static let alpn = "moqt-16"

    /// CLIENT_SETUP parameter key carrying the Connection Config JSON
    /// (odd, so length-prefixed bytes). lasa-core.md §9.
    public static let setupParamConnectionConfig: UInt64 = 0x1A5A1
    /// SUBSCRIBE parameter key carrying the state subscribe message.
    public static let subscribeParamState: UInt64 = 0x1A5A3

    public static let trackMonoObject = "mono-object"
    public static let trackBinaural = "binaural"
    public static let trackAmbi2 = "ambi2"
    public static let trackAmbi3 = "ambi3"
    public static let trackState = "state"
    public static let trackPresence = "presence"

    public enum Direction: String, Sendable { case source, sink }

    public static func entityNamespace(space: String, entity: String, _ dir: Direction) -> [String] {
        [space, "entity", entity, dir.rawValue]
    }
    public static func clientNamespace(space: String, client: String, _ dir: Direction) -> [String] {
        [space, "client", client, dir.rawValue]
    }
    public static func presenceNamespace(space: String) -> [String] { [space, "presence"] }

    // MARK: Connection Config (§4.1)
    //
    // Entity, Setup and ConnectionConfig mirror schemata/entity.schema.json,
    // setup.schema.json and connection.schema.json field for field, with
    // the schema's hyphenated keys; the port of lasa/typescript/src/lasa/
    // setup.ts (2026-11-03). JSON encoding is Foundation's JSONEncoder
    // with sorted keys, so the bytes are stable. Divergence from the
    // TypeScript: an empty ticket string is sent as given, not dropped
    // (the existing bytes), and lockstep false is sent as false.

    /// A free-form attribute value (entity.schema.json attr-value): a
    /// boolean, string, number, or an object of the same.
    public indirect enum AttrValue: Codable, Equatable, Sendable {
        case bool(Bool)
        case string(String)
        case number(Double)
        case object([String: AttrValue])

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            if let o = try? c.decode([String: AttrValue].self) { self = .object(o); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "attr value must be a boolean, string, number or object")
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let b): try c.encode(b)
            case .string(let s): try c.encode(s)
            case .number(let d): try c.encode(d)
            case .object(let o): try c.encode(o)
            }
        }
    }

    /// Pose frame (lasa-core.md §3): world (default) or head.
    public enum Frame: String, Codable, Sendable { case world, head }

    /// Degrees of freedom an entity's pose carries (default 6).
    public enum DOF: Int, Codable, Sendable { case zero = 0, three = 3, six = 6 }

    /// Latency-tolerance intent for an entity's audio path (§4.2).
    public enum Quality: Int, Codable, Sendable { case interactive = 0, resilient = 1, playback = 2 }

    /// pose.schema.json with plain Doubles; the client's own Pose type is
    /// separate (Wire/Pose.swift) and converts as needed.
    public struct Position: Codable, Equatable, Sendable {
        public var x: Double, y: Double, z: Double
        public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    }
    public struct Attitude: Codable, Equatable, Sendable {
        public var yaw: Double, pitch: Double, roll: Double
        public init(yaw: Double, pitch: Double, roll: Double) { self.yaw = yaw; self.pitch = pitch; self.roll = roll }
    }
    public struct InitialPose: Codable, Equatable, Sendable {
        public var position: Position?
        public var attitude: Attitude?
        public init(position: Position? = nil, attitude: Attitude? = nil) { self.position = position; self.attitude = attitude }
    }

    /// Rendering parameters: gain multiplier, distance attenuation,
    /// source size, directivity.
    public struct Render: Codable, Equatable, Sendable {
        public var gain: Double?
        public var attenuation: Double?
        public var size: Double?
        public var directivity: Double?
        public init(gain: Double? = nil, attenuation: Double? = nil, size: Double? = nil, directivity: Double? = nil) {
            self.gain = gain; self.attenuation = attenuation; self.size = size; self.directivity = directivity
        }
    }

    /// An entity definition, every field of entity.schema.json.
    public struct Entity: Codable, Equatable, Sendable {
        /// Unique within the space; identifier grammar (§2).
        public var id: String
        /// Display name, surfaced to other participants.
        public var name: String
        /// Priority entity (base profile).
        public var priority: Bool?
        /// Channels in which this entity's source is heard (omitted: ["main"]).
        public var heardIn: [String]?
        /// Channels this entity's sink listens to (omitted: ["main"]).
        public var hears: [String]?
        /// Free-form application attributes, published in state.
        public var attrs: [String: AttrValue]?
        public var frame: Frame?
        public var dof: DOF?
        public var quality: Quality?
        /// Maximum redundancy offset 0 to 7 (§4.2, §5.1); 0 is none.
        public var redundancy: Int?
        public var initialPose: InitialPose?
        public var render: Render?

        public init(id: String, name: String, hears: [String]? = nil, heardIn: [String]? = nil, attrs: [String: AttrValue]? = nil,
                    priority: Bool? = nil, frame: Frame? = nil, dof: DOF? = nil, quality: Quality? = nil, redundancy: Int? = nil,
                    initialPose: InitialPose? = nil, render: Render? = nil) {
            self.id = id; self.name = name; self.hears = hears; self.heardIn = heardIn; self.attrs = attrs
            self.priority = priority; self.frame = frame; self.dof = dof; self.quality = quality
            self.redundancy = redundancy; self.initialPose = initialPose; self.render = render
        }

        /// String-valued attrs, the probe's shape.
        public init(id: String, name: String, hears: [String]? = nil, heardIn: [String]? = nil, attrs: [String: String]) {
            self.init(id: id, name: name, hears: hears, heardIn: heardIn, attrs: attrs.mapValues { AttrValue.string($0) })
        }

        enum CodingKeys: String, CodingKey, Sendable {
            case id, name, priority, heardIn = "heard-in", hears, attrs, frame, dof, quality, redundancy
            case initialPose = "initial-pose", render
        }
    }

    /// A setup instantiating a ticket-defined entity by id
    /// (setup.schema.json, §4.2).
    public struct Setup: Codable, Equatable, Sendable {
        /// Id of an entity the ticket defines.
        public var id: String
        /// Unsigned attributes merged over the ticket's definition.
        public var attrs: [String: AttrValue]?
        /// Overrides the ticket definition's initial pose.
        public var initialPose: InitialPose?

        public init(id: String, attrs: [String: AttrValue]? = nil, initialPose: InitialPose? = nil) {
            self.id = id; self.attrs = attrs; self.initialPose = initialPose
        }
        enum CodingKeys: String, CodingKey, Sendable { case id, attrs, initialPose = "initial-pose" }
    }

    public struct ConnectionConfig: Encodable, Sendable {
        public var clientID: String
        /// Signed JWT ticket; omit only against a space allowing unticketed.
        public var ticket: String?
        /// Ad-hoc entity definitions (unticketed, or presenter/admin tickets).
        public var entities: [Entity]?
        /// Instantiations of ticket-defined entities (requires a ticket).
        public var setups: [Setup]?
        /// One frame counter across every entity source track (§4.2).
        public var lockstep: Bool?

        public init(clientID: String, ticket: String? = nil, entities: [Entity]? = nil, setups: [Setup]? = nil, lockstep: Bool? = nil) {
            self.clientID = clientID; self.ticket = ticket; self.entities = entities; self.setups = setups; self.lockstep = lockstep
        }
        enum CodingKeys: String, CodingKey, Sendable { case clientID = "client_id", ticket, entities, setups, lockstep }

        public func json() throws -> [UInt8] {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return Array(try enc.encode(self))
        }

        public func setupParam() throws -> KVP {
            KVP(Lasa.setupParamConnectionConfig, bytes: try json())
        }
    }

    // MARK: Sink packet (§5.1)

    static let flagPose: UInt8 = 1 << 0
    static let flagAudio: UInt8 = 1 << 1
    static let flagRedundancy: UInt8 = 1 << 2
    static let offsetBits: UInt8 = 0x7 << 3
    static let flagTS: UInt8 = 1 << 6
    static let flagReserved: UInt8 = 1 << 7

    public struct SinkSplit: Sendable {
        /// Unix microseconds, 0 when the packet carries no timestamp.
        public var timestamp: UInt64
        /// The primary audio payload's range within the packet.
        public var audio: Range<Int>
    }

    /// Splits a sink packet into its timestamp and primary audio, the
    /// same cut go/sink.Split makes. Nil for a packet that is not this
    /// format (unknown flag bits) or is malformed.
    @inline(__always)
    public static func splitSink(_ b: UnsafeRawBufferPointer) -> SinkSplit? {
        guard b.count >= 1 else { return nil }
        let flags = b[0]
        if flags & (flagPose | flagAudio | flagReserved) != 0 { return nil }
        if flags & flagRedundancy == 0 && flags & offsetBits != 0 { return nil }
        var off = 1
        var ts: UInt64 = 0
        if flags & flagTS != 0 {
            guard b.count >= off + 8 else { return nil }
            ts = b.loadUnaligned(fromByteOffset: off, as: UInt64.self).littleEndian
            off += 8
        }
        if flags & flagRedundancy != 0 {
            guard b.count >= off + 2 else { return nil }
            let n = Int(b.loadUnaligned(fromByteOffset: off, as: UInt16.self).littleEndian)
            off += 2
            guard b.count >= off + n else { return nil }
            return SinkSplit(timestamp: ts, audio: off..<off + n)
        }
        guard b.count > off else { return nil }
        return SinkSplit(timestamp: ts, audio: off..<b.count)
    }

    // MARK: State messages (§6.7)

    /// Client-authored ops carry no seq.
    public indirect enum UpstreamState: Sendable, Equatable {
        case set(key: String, value: [UInt8])
        case clear(key: String)
        /// Several ops the server applies together (type 3, varint count,
        /// the ops; lasa-core.md §6.7). Never nested.
        case group([UpstreamState])

        public func encode() -> [UInt8] {
            var w = ByteWriter(capacity: 32)
            encode(into: &w)
            return w.bytes
        }

        private func encode(into w: inout ByteWriter) {
            switch self {
            case .set(let key, let value):
                w.u8(1); w.string(key); w.prefixed(value)
            case .clear(let key):
                w.u8(2); w.string(key)
            case .group(let ops):
                w.u8(3); w.varint(UInt64(ops.count))
                for op in ops { op.encode(into: &w) }
            }
        }
    }

    /// Space-authored messages carry seqs; the same type bytes parse
    /// differently per direction, so this parser is downstream-only.
    public indirect enum DownstreamState: Equatable {
        case set(key: String, value: [UInt8], seq: UInt64)
        case clear(key: String, seq: UInt64)
        case group([DownstreamState])
        case frontier(epoch: [UInt8], seq: UInt64)
        case begin(kind: UInt8)
    }

    public static func parseDownstream(_ bytes: [UInt8]) throws -> DownstreamState {
        var r = ByteReader(bytes)
        let m = try parseDownstream(&r, nested: false)
        guard r.isAtEnd else { throw WireError.badFrame("trailing bytes after state message") }
        return m
    }

    private static func parseDownstream(_ r: inout ByteReader, nested: Bool) throws -> DownstreamState {
        switch try r.u8() {
        case 1:
            let key = try r.string(); let value = try r.prefixed(); let seq = try r.varint()
            return .set(key: key, value: value, seq: seq)
        case 2:
            let key = try r.string(); let seq = try r.varint()
            return .clear(key: key, seq: seq)
        case 3:
            guard !nested else { throw WireError.badFrame("nested group") }
            let n = try r.varint()
            var ops: [DownstreamState] = []
            for _ in 0..<n { ops.append(try parseDownstream(&r, nested: true)) }
            return .group(ops)
        case 4:
            let epoch = try r.raw(8); let seq = try r.varint()
            return .frontier(epoch: epoch, seq: seq)
        case 5:
            return .begin(kind: try r.u8())
        case let t:
            throw WireError.badFrame("unknown state message type \(t)")
        }
    }

    // MARK: State subscribe parameter (§6.7)

    /// A fresh subscription: flags 0, the canonical (deduplicated, sorted
    /// bytewise) prefix set, no cursor.
    public static func stateSubscribeParams(prefixes: [String]) -> [UInt8] {
        let canonical = Array(Set(prefixes)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var w = ByteWriter(capacity: 32)
        w.u8(0)
        w.varint(UInt64(canonical.count))
        for p in canonical { w.string(p) }
        return w.bytes
    }
}
