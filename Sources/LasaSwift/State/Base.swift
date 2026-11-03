// The LASA base profile (lasa-base-profile.md) as a typed client API:
// the `lasa.` key vocabulary, the §1 value codec, the owner and space
// controls, and a typed read view over the state store. Ported from
// lasa/typescript/src/lasa/base.ts on 2026-11-03.
//
// Everything here reduces to state ops (lasa-core.md §6). A "command" is
// a set or clear on a reserved key, ordered and echoed by the server
// like any other write. The helpers only build keys and encode values;
// permission is the server's, and a write the caller's roles do not
// allow is silently dropped (profile §6.2), never surfaced here.
//
// Key builders and the codec mirror Go profile/base (keys.go,
// consume.go); a change to the vocabulary lands there first.
//
// Deliberate divergences from the TypeScript:
//
// - Groups. Several ops become one `Lasa.UpstreamState.group` (type 3,
//   varint count, the ops), as the TypeScript's `group` message; one op
//   stays bare. `oneOrGroup` is the only place that decides.
// - Dof and frame are enums (`Dof`, `Frame`), so an invalid dof is a
//   compile error rather than a thrown MalformedError.
// - setRender takes `[RenderField: Double?]`: a present key with a nil
//   value clears, an absent key is untouched (TypeScript null/undefined).
// - setChannels takes the wanted sides as two optional parameters.
// - The read view never throws: a query with an id that violates the
//   grammar answers as if the key were absent, where the TypeScript key
//   builder would throw from inside the getter.
// - Collections the TypeScript fills in store iteration order (heardIn,
//   hears, mutes, solos, attrs) are filled in bytewise key order here,
//   so a view does not depend on the store's iteration contract.
// - The store and the writer are protocols (StateReadable, StateWriter)
//   so this file builds without the Store type; the lead conforms Store.

import Foundation

// MARK: - Errors

/// A caller-side validation failure: an identifier, attr path, range or
/// value the profile grammar rejects. Thrown at the call, so a bad id
/// fails loudly rather than as a silently dropped write.
public struct MalformedError: Error, CustomStringConvertible, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Values (profile §1)

/// A base-profile value: Boolean, String or Number (profile §1).
public enum BaseValue: Sendable, Equatable, Hashable {
    case bool(Bool)
    case string(String)
    case number(Double)

    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
}

extension BaseValue: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
}

/// Encodes a §1 value per JSON conventions, byte-for-byte as the Go
/// profile and the TypeScript client write them: `true`/`false`, a
/// JSON string, or a shortest round-trip number in JSON's grammar.
public func encodeValue(_ v: BaseValue) throws -> [UInt8] {
    switch v {
    case .bool(let b):
        return Array((b ? "true" : "false").utf8)
    case .string(let s):
        return jsonString(s)
    case .number(let n):
        guard n.isFinite else { throw MalformedError("base value must be finite, got \(n)") }
        return Array(jsonNumber(n).utf8)
    }
}

/// Decodes a §1 value. Returns nil for absent bytes, and for bytes that
/// are not one of the three types: the profile says an invalid value is
/// stored and delivered but ignored by every consumer (§2), so a reader
/// treats it as absent.
public func decodeValue(_ bytes: [UInt8]?) -> BaseValue? {
    guard let bytes, !bytes.isEmpty else { return nil }
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
    } catch {
        return nil
    }
    if let s = parsed as? String { return .string(s) }
    guard let n = parsed as? NSNumber else { return nil }
    if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
    let d = n.doubleValue
    return d.isFinite ? .number(d) : nil
}

/// A JSON string literal, escaped as JSON.stringify and Go's
/// encoding/json agree on for the characters that must be escaped. Go
/// additionally escapes <, >, & and U+2028/2029 by default, which the
/// profile does not require and the TypeScript does not do; the server
/// reads both forms the same.
private func jsonString(_ s: String) -> [UInt8] {
    var out: [UInt8] = [UInt8(ascii: "\"")]
    out.reserveCapacity(s.utf8.count + 2)
    for b in s.utf8 {
        switch b {
        case UInt8(ascii: "\""): out.append(contentsOf: Array("\\\"".utf8))
        case UInt8(ascii: "\\"): out.append(contentsOf: Array("\\\\".utf8))
        case 0x08: out.append(contentsOf: Array("\\b".utf8))
        case 0x0C: out.append(contentsOf: Array("\\f".utf8))
        case 0x0A: out.append(contentsOf: Array("\\n".utf8))
        case 0x0D: out.append(contentsOf: Array("\\r".utf8))
        case 0x09: out.append(contentsOf: Array("\\t".utf8))
        case 0..<0x20:
            let hex = String(b, radix: 16)
            out.append(contentsOf: Array(("\\u00" + (hex.count == 1 ? "0" : "") + hex).utf8))
        default: out.append(b)
        }
    }
    out.append(UInt8(ascii: "\""))
    return out
}

/// A finite double as ECMAScript Number::toString writes it, which is
/// also what Go's encoding/json writes for a float64: the shortest
/// round-trip digits, positional for decimal exponents in -6 ..< 21,
/// exponential (`1e+21`, `1e-7`) outside. Swift's description already
/// gives the shortest digits; this only reshapes them.
func jsonNumber(_ d: Double) -> String {
    if d == 0 { return "0" }  // -0 too, as JSON.stringify(-0) is "0"
    let negative = d < 0
    var text = Substring(abs(d).description)
    var exp10 = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exp10 = Int(text[text.index(after: e)...])!
        text = text[..<e]
    }
    var intPart = text
    var fracPart = Substring("")
    if let dot = text.firstIndex(of: ".") {
        intPart = text[..<dot]
        fracPart = text[text.index(after: dot)...]
    }
    // digits: the significant digits with no leading or trailing zeros;
    // n: the decimal point's position counted from the first digit.
    var digits = Array((intPart + fracPart).utf8)
    var n = intPart.count + exp10
    while let f = digits.first, f == UInt8(ascii: "0") { digits.removeFirst(); n -= 1 }
    while let l = digits.last, l == UInt8(ascii: "0") { digits.removeLast() }
    let k = digits.count
    var out = negative ? "-" : ""
    let ds = String(decoding: digits, as: UTF8.self)
    if k <= n && n <= 21 {
        out += ds + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        out += ds.prefix(n) + "." + ds.dropFirst(n)
    } else if -6 < n && n <= 0 {
        out += "0." + String(repeating: "0", count: -n) + ds
    } else {
        let e = n - 1
        out += k == 1 ? ds : ds.prefix(1) + "." + ds.dropFirst(1)
        out += "e" + (e >= 0 ? "+" : "-") + String(abs(e))
    }
    return out
}

// MARK: - Identifiers and keys (core §2, profile §6)

/// Reports whether `s` matches the identifier grammar `[a-z0-9-]{1,128}`
/// (lasa-core.md §2).
public func isIdentifier(_ s: String) -> Bool {
    let u = s.utf8
    guard !u.isEmpty, u.count <= 128 else { return false }
    return u.allSatisfy { b in
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: "-")
    }
}

@discardableResult
private func ident(_ s: String, _ what: String) throws -> String {
    guard isIdentifier(s) else {
        throw MalformedError("invalid \(what) \"\(s)\": must match [a-z0-9-]{1,128}")
    }
    return s
}

private func attrPath(_ s: String) throws -> String {
    let segments = s.split(separator: ".", omittingEmptySubsequences: false)
    guard !segments.isEmpty, segments.allSatisfy({ isIdentifier(String($0)) }) else {
        throw MalformedError("invalid attr path \"\(s)\": dotted identifiers only")
    }
    return s
}

/// Key builders for the base-profile vocabulary (profile §6). Each
/// validates its identifier arguments and throws MalformedError on a
/// violation. The TypeScript `keys` object.
public enum BaseKeys {
    /// The reserved base-profile key prefix.
    public static let basePrefix = "lasa."

    /// `lasa.entity.{id}`: the existence marker, valued with the owning client id.
    public static func entityMarker(_ id: String) throws -> String {
        "lasa.entity.\(try ident(id, "entity id"))"
    }
    /// `lasa.entity.{id}.{suffix}`. The suffix is not validated; prefer a specific builder.
    public static func entity(_ id: String, _ suffix: String) throws -> String {
        "lasa.entity.\(try ident(id, "entity id")).\(suffix)"
    }
    public static func name(_ id: String) throws -> String { try entity(id, "name") }
    public static func attr(_ id: String, _ path: String) throws -> String {
        try entity(id, "attrs.\(try attrPath(path))")
    }
    public static func signedAttr(_ id: String, _ path: String) throws -> String {
        try entity(id, "signed-attrs.\(try attrPath(path))")
    }
    public static func heardIn(_ id: String, _ channel: String) throws -> String {
        try entity(id, "heard-in.\(try ident(channel, "channel"))")
    }
    public static func hears(_ id: String, _ channel: String) throws -> String {
        try entity(id, "hears.\(try ident(channel, "channel"))")
    }
    public static func priority(_ id: String) throws -> String { try entity(id, "priority") }
    public static func renderGain(_ id: String) throws -> String { try entity(id, "render.gain") }
    public static func renderAttenuation(_ id: String) throws -> String { try entity(id, "render.attenuation") }
    public static func renderSize(_ id: String) throws -> String { try entity(id, "render.size") }
    public static func renderDirectivity(_ id: String) throws -> String { try entity(id, "render.directivity") }
    public static func frame(_ id: String) throws -> String { try entity(id, "frame") }
    public static func dof(_ id: String) throws -> String { try entity(id, "dof") }
    public static func personalMute(_ owner: String, _ other: String) throws -> String {
        try entity(owner, "mute.\(try ident(other, "entity id"))")
    }
    public static func personalSolo(_ owner: String, _ other: String) throws -> String {
        try entity(owner, "solo.\(try ident(other, "entity id"))")
    }

    public static func spaceEntityMuted(_ id: String) throws -> String {
        "lasa.space.entity.muted.\(try ident(id, "entity id"))"
    }
    public static func clientBlocked(_ id: String) throws -> String {
        "lasa.space.client.blocked.\(try ident(id, "client id"))"
    }
    public static func roleBlocked(_ role: String) throws -> String {
        "lasa.space.role.blocked.\(try ident(role, "role"))"
    }
    public static func channelMuted(_ ch: String) throws -> String {
        "lasa.space.channel.muted.\(try ident(ch, "channel"))"
    }
    public static func channelGain(_ ch: String) throws -> String {
        "lasa.space.channel.gain.\(try ident(ch, "channel"))"
    }
    public static func channelAttenuation(_ ch: String) throws -> String {
        "lasa.space.channel.attenuation.\(try ident(ch, "channel"))"
    }
}

// MARK: - Op construction

private func set(_ key: String, _ value: BaseValue) throws -> Lasa.UpstreamState {
    .set(key: key, value: try encodeValue(value))
}
private func clear(_ key: String) -> Lasa.UpstreamState {
    .clear(key: key)
}

/// One op stays a bare op; several are meant to become a group, a hint
/// that they be applied together (lasa-core.md §6: no consistency
/// guarantee, and an over-cap group is dropped whole). Until
/// Lasa.UpstreamState grows a group case this returns the ops as given,
/// to go out in one writeState call; the lead changes this one function
/// to wrap `ops.count > 1` in the group message.
func oneOrGroup(_ ops: [Lasa.UpstreamState]) -> [Lasa.UpstreamState] {
    if ops.count <= 1 { return ops }
    return [.group(ops)]
}

private func range(_ name: String, _ v: Double, _ lo: Double, _ hi: Double) throws -> Double {
    guard v.isFinite, v >= lo, v <= hi else {
        throw MalformedError("\(name) must be in \(lo)–\(hi), got \(v)")
    }
    return v
}

/// Converts a block expiry to the profile's wire value: 0 for forever,
/// otherwise unix seconds. A Date in the past is still sent as given;
/// the server's clock decides expiry, not ours.
private func blockedValue(_ until: Date?) throws -> Double {
    guard let until else { return 0 }
    let secs = until.timeIntervalSince1970.rounded(.down)
    guard secs.isFinite, secs > 0 else { throw MalformedError("invalid block expiry \(until)") }
    return secs
}

/// Anything that can publish upstream state ops: a LasaClient, or a test
/// double. LasaClient.writeState has this exact signature.
public protocol StateWriter: Sendable {
    func writeState(_ ops: [Lasa.UpstreamState]) async throws
}

// MARK: - Owner-scope operations (profile §6: attrs, mute.*, solo.*)

/// Render parameters (profile §6 `render.*`) as the read view reports
/// them: nil fields are unset and take the documented defaults.
public struct RenderParams: Sendable, Equatable {
    /// Amplitude multiplier 0.0 to 3.0; absent = 1.0.
    public var gain: Double?
    /// Distance-attenuation exponent 0.0 to 3.0; absent = 2.0 (inverse-square).
    public var attenuation: Double?
    /// Source size in metres, at least 0; absent = point source.
    public var size: Double?
    /// 0.0 omnidirectional to 1.0 maximally directional.
    public var directivity: Double?

    public init(gain: Double? = nil, attenuation: Double? = nil, size: Double? = nil, directivity: Double? = nil) {
        self.gain = gain; self.attenuation = attenuation; self.size = size; self.directivity = directivity
    }
}

/// One `render.*` field, in the order SpaceControls.setRender emits them.
public enum RenderField: Sendable, CaseIterable, Hashable {
    case gain, attenuation, size, directivity
}

/// Degrees of freedom the space enforces at ingest (profile §6): 6 free,
/// 3 turn in place, 0 fixed.
public enum Dof: Int, Sendable {
    case fixed = 0
    case turn = 3
    case free = 6
}

/// The entity's reference frame (profile §6).
public enum Frame: String, Sendable {
    case world, head
}

/// The operations an entity's owner may perform on it: personal mutes
/// and solos, and runtime attrs. Reached as methods on EntityPublisher,
/// or constructed directly when the publisher is not needed.
///
/// Mute is bidirectional (§6): muting `other` silences the pair both
/// ways. Solo silences everyone but the solo'd set for this listener
/// only, and wins over mutes. Both are connection-scoped and reset on
/// reconnect; a client rewrites what it knows.
public struct EntityControls: Sendable {
    private let writer: any StateWriter
    /// The owned entity these controls act for.
    public let entityId: String

    public init(_ writer: any StateWriter, entityId: String) throws {
        try ident(entityId, "entity id")
        self.writer = writer
        self.entityId = entityId
    }

    /// Silences the pair (this entity, `other`) in both directions.
    public func mute(_ other: String) async throws {
        try await writer.writeState([try set(BaseKeys.personalMute(entityId, other), true)])
    }
    public func unmute(_ other: String) async throws {
        try await writer.writeState([clear(try BaseKeys.personalMute(entityId, other))])
    }
    /// Hear `other` and the other solo'd entities only, overriding mutes.
    public func solo(_ other: String) async throws {
        try await writer.writeState([try set(BaseKeys.personalSolo(entityId, other), true)])
    }
    public func unsolo(_ other: String) async throws {
        try await writer.writeState([clear(try BaseKeys.personalSolo(entityId, other))])
    }

    /// Sets one runtime attribute, `path` dotted per §1 (`colour`, `avatar.hat`).
    public func setAttr(_ path: String, _ value: BaseValue) async throws {
        try await writer.writeState([try set(BaseKeys.attr(entityId, path), value)])
    }
    public func clearAttr(_ path: String) async throws {
        try await writer.writeState([clear(try BaseKeys.attr(entityId, path))])
    }
    /// Sets several attributes as one group (flat: one entry per leaf
    /// path), in bytewise path order since a dictionary has none.
    public func setAttrs(_ attrs: [String: BaseValue]) async throws {
        let ops = try attrs.keys.sorted().map { try set(BaseKeys.attr(entityId, $0), attrs[$0]!) }
        try await writer.writeState(oneOrGroup(ops))
    }
}

// MARK: - Space-scope operations (profile §4 channels, §5 moderation, §6 render)

/// An entity's channel memberships as the store holds them.
public struct ChannelMemberships: Sendable, Equatable {
    /// Channels in which the source is heard.
    public var heardIn: [String]
    /// Channels the sink listens to.
    public var hears: [String]
    public init(heardIn: [String], hears: [String]) { self.heardIn = heardIn; self.hears = hears }
}

/// Space-wide operations, reached as `client.spaceControls`. Each is
/// gated by role on the server (`moderator` for entity mutes and client
/// blocks, `producer` for channels, rendering and role blocks; profile
/// §2) and silently dropped when the caller lacks it.
///
/// Grouped by concern: hearing is channel membership and channel policy;
/// moderation is blocks, which act on the connection; the space entity
/// mute is the one moderation act on hearing.
public struct SpaceControls: Sendable {
    private let writer: any StateWriter

    public init(_ writer: any StateWriter) { self.writer = writer }

    // moderation (§5)

    /// Silences the entity's source in every render. Rendering only; the connection stays.
    public func muteEntity(_ entityId: String) async throws {
        try await writer.writeState([try set(BaseKeys.spaceEntityMuted(entityId), true)])
    }
    public func unmuteEntity(_ entityId: String) async throws {
        try await writer.writeState([clear(try BaseKeys.spaceEntityMuted(entityId))])
    }

    /// Terminates the client's live connection and refuses readmission
    /// until `until` (forever when nil). Admin is unblockable.
    public func blockClient(_ clientId: String, until: Date? = nil) async throws {
        try await writer.writeState([try set(BaseKeys.clientBlocked(clientId), .number(try blockedValue(until)))])
    }
    public func unblockClient(_ clientId: String) async throws {
        try await writer.writeState([clear(try BaseKeys.clientBlocked(clientId))])
    }
    /// A block with a short expiry: "a kick is a block with a short expiry" (§5).
    public func kickClient(_ clientId: String, forMs: Double) async throws {
        guard forMs > 0 else { throw MalformedError("kick duration must be positive, got \(forMs)") }
        try await blockClient(clientId, until: Date(timeIntervalSinceNow: forMs / 1000))
    }

    /// Blocks every connection bearing the role (except admin).
    public func blockRole(_ role: String, until: Date? = nil) async throws {
        try await writer.writeState([try set(BaseKeys.roleBlocked(role), .number(try blockedValue(until)))])
    }
    public func unblockRole(_ role: String) async throws {
        try await writer.writeState([clear(try BaseKeys.roleBlocked(role))])
    }

    // hearing: channel policy (§4)

    /// A muted channel contributes nothing to audibility.
    public func muteChannel(_ channel: String) async throws {
        try await writer.writeState([try set(BaseKeys.channelMuted(channel), true)])
    }
    public func unmuteChannel(_ channel: String) async throws {
        try await writer.writeState([clear(try BaseKeys.channelMuted(channel))])
    }
    /// Channel gain 0 to 3.0 (amplitude); the highest across a pair's shared channels wins. nil clears.
    public func setChannelGain(_ channel: String, _ gain: Double?) async throws {
        let key = try BaseKeys.channelGain(channel)
        let op = try gain.map { try set(key, .number(try range("channel gain", $0, 0, 3))) } ?? clear(key)
        try await writer.writeState([op])
    }
    /// Channel attenuation 0 to 3.0; the lowest set value across a pair's shared channels overrides the source's. nil clears.
    public func setChannelAttenuation(_ channel: String, _ attenuation: Double?) async throws {
        let key = try BaseKeys.channelAttenuation(channel)
        let op = try attenuation.map { try set(key, .number(try range("channel attenuation", $0, 0, 3))) } ?? clear(key)
        try await writer.writeState([op])
    }

    // hearing: entity membership and rendering (§4, §6)

    /// Adds the entity's source to a channel (it is heard there).
    public func addHeardIn(_ entityId: String, _ channel: String) async throws {
        try await writer.writeState([try set(BaseKeys.heardIn(entityId, channel), true)])
    }
    public func removeHeardIn(_ entityId: String, _ channel: String) async throws {
        try await writer.writeState([clear(try BaseKeys.heardIn(entityId, channel))])
    }
    /// Adds the entity's sink to a channel (it hears there).
    public func addHears(_ entityId: String, _ channel: String) async throws {
        try await writer.writeState([try set(BaseKeys.hears(entityId, channel), true)])
    }
    public func removeHears(_ entityId: String, _ channel: String) async throws {
        try await writer.writeState([clear(try BaseKeys.hears(entityId, channel))])
    }
    /// Replaces the entity's memberships as one group: `current` is what
    /// the store holds now (see BaseView.entity), `heardIn` and `hears`
    /// the wanted sets; a nil side is left alone. Emptying `heardIn`
    /// leaves the entity inaudible (§6), a moderation act, so allowed.
    public func setChannels(
        _ entityId: String, current: ChannelMemberships, heardIn: [String]? = nil, hears: [String]? = nil
    ) async throws {
        var ops: [Lasa.UpstreamState] = []
        func diff(_ have: [String], _ want: [String]?, _ key: (String) throws -> String) throws {
            guard let want else { return }
            let wantSet = Set(want)
            for ch in have where !wantSet.contains(ch) { ops.append(clear(try key(ch))) }
            for ch in want where !have.contains(ch) { ops.append(try set(try key(ch), true)) }
        }
        try diff(current.heardIn, heardIn) { try BaseKeys.heardIn(entityId, $0) }
        try diff(current.hears, hears) { try BaseKeys.hears(entityId, $0) }
        try await writer.writeState(oneOrGroup(ops))
    }

    /// Sets the given render parameters as one group, in RenderField
    /// order; an absent field is untouched, a present nil clears to the default.
    public func setRender(_ entityId: String, _ params: [RenderField: Double?]) async throws {
        var ops: [Lasa.UpstreamState] = []
        for field in RenderField.allCases {
            guard let v = params[field] else { continue }
            let key: String, name: String, lo: Double, hi: Double
            switch field {
            case .gain: (key, name, lo, hi) = (try BaseKeys.renderGain(entityId), "gain", 0, 3)
            case .attenuation: (key, name, lo, hi) = (try BaseKeys.renderAttenuation(entityId), "attenuation", 0, 3)
            case .size: (key, name, lo, hi) = (try BaseKeys.renderSize(entityId), "size", 0, .infinity)
            case .directivity: (key, name, lo, hi) = (try BaseKeys.renderDirectivity(entityId), "directivity", 0, 1)
            }
            ops.append(try v.map { try set(key, .number(try range(name, $0, lo, hi))) } ?? clear(key))
        }
        try await writer.writeState(oneOrGroup(ops))
    }

    /// Marks the entity's source as important to render well; sparingly (§6).
    public func setPriority(_ entityId: String, _ priority: Bool) async throws {
        let key = try BaseKeys.priority(entityId)
        try await writer.writeState([priority ? try set(key, true) : clear(key)])
    }

    /// Degrees of freedom the space enforces at ingest (`moderator`). The default, 6, is expressed as clear.
    public func setDof(_ entityId: String, _ dof: Dof) async throws {
        let key = try BaseKeys.dof(entityId)
        try await writer.writeState([dof == .free ? clear(key) : try set(key, .number(Double(dof.rawValue)))])
    }
}

// MARK: - Read view (profile §6, over a store subscribed to `lasa.`)

/// What BaseView needs of the state store: one key's value and the keys
/// under a prefix. The lead conforms Store; a test double is a dictionary.
public protocol StateReadable: Sendable {
    func get(_ key: String) -> [UInt8]?
    func keys(withPrefix prefix: String) -> [String]
}

/// One live entity as the store describes it.
public struct EntityView: Sendable, Equatable {
    public var id: String
    /// The owning client id (the existence marker's value).
    public var owner: String
    public var name: String = ""
    /// Runtime attributes, flat by dotted path.
    public var attrs: [String: BaseValue] = [:]
    /// Attributes from inside the signed ticket, immutable.
    public var signedAttrs: [String: BaseValue] = [:]
    /// Channels in which the source is heard.
    public var heardIn: [String] = []
    /// Channels the sink listens to.
    public var hears: [String] = []
    public var priority: Bool = false
    /// Set render parameters only; absent fields take the §6 defaults.
    public var render = RenderParams()
    public var frame: Frame = .world
    public var dof: Dof = .free
    /// Entities this entity has personally muted / solo'd (readable by
    /// every role, §2: a muted user can see it).
    public var mutes: [String] = []
    public var solos: [String] = []

    public init(id: String, owner: String) { self.id = id; self.owner = owner }

    public var memberships: ChannelMemberships { ChannelMemberships(heardIn: heardIn, hears: hears) }
}

/// A block entry: `until` is nil for forever, else the expiry.
public struct BlockView: Sendable, Equatable {
    public var id: String
    public var until: Date?
    public init(id: String, until: Date?) { self.id = id; self.until = until }
}

/// Channel policy: the muted flag and any set gain or attenuation override.
public struct ChannelPolicy: Sendable, Equatable {
    public var muted: Bool
    public var gain: Double?
    public var attenuation: Double?
    public init(muted: Bool, gain: Double? = nil, attenuation: Double? = nil) {
        self.muted = muted; self.gain = gain; self.attenuation = attenuation
    }
}

/// A typed read view over a store whose prefixes include `lasa.`. Every
/// call scans the store's `lasa.` keys, which is the right shape for a
/// few hundred keys; an application with more keeps its own index. Read
/// after the sync has settled.
///
/// Keys under an entity whose existence marker is absent are ignored,
/// as the profile requires (§6): a departing entity's subtree can be
/// mid-sweep.
public struct BaseView: Sendable {
    private let store: any StateReadable

    public init(_ store: any StateReadable) { self.store = store }

    private static let entityPrefix = "lasa.entity."

    /// Splits `lasa.entity.{id}` or `lasa.entity.{id}.{suffix}` into
    /// (id, suffix), nil for any other key. The TypeScript ENTITY_RE.
    private static func parseEntityKey(_ key: String) -> (id: String, suffix: String?)? {
        guard key.hasPrefix(entityPrefix) else { return nil }
        let rest = key.dropFirst(entityPrefix.count)
        guard let dot = rest.firstIndex(of: ".") else {
            return isIdentifier(String(rest)) ? (String(rest), nil) : nil
        }
        let id = String(rest[..<dot])
        let suffix = rest[rest.index(after: dot)...]
        guard isIdentifier(id), !suffix.isEmpty else { return nil }
        return (id, String(suffix))
    }

    /// Every live entity (marker present), in id order.
    public func entities() -> [EntityView] {
        let keys = store.keys(withPrefix: Self.entityPrefix).sorted()
        var views: [String: EntityView] = [:]
        // Pass 1: markers, so we know which subtrees are live.
        for key in keys {
            guard let (id, suffix) = Self.parseEntityKey(key), suffix == nil else { continue }
            guard case .string(let owner)? = decodeValue(store.get(key)) else { continue }
            views[id] = EntityView(id: id, owner: owner)
        }
        // Pass 2: everything under a live marker.
        for key in keys {
            guard let (id, suffix) = Self.parseEntityKey(key), let suffix, views[id] != nil else { continue }
            applyEntityKey(&views[id]!, suffix, decodeValue(store.get(key)))
        }
        return views.keys.sorted().map { views[$0]! }
    }

    /// One entity, or nil if its marker is absent.
    public func entity(_ id: String) -> EntityView? {
        guard let marker = try? BaseKeys.entityMarker(id),
              case .string(let owner)? = decodeValue(store.get(marker))
        else { return nil }
        var v = EntityView(id: id, owner: owner)
        let prefix = marker + "."
        for key in store.keys(withPrefix: prefix).sorted() {
            applyEntityKey(&v, String(key.dropFirst(prefix.count)), decodeValue(store.get(key)))
        }
        return v
    }

    /// Whether the space has muted the entity's source (§5).
    public func isEntityMuted(_ entityId: String) -> Bool {
        flag(try? BaseKeys.spaceEntityMuted(entityId))
    }

    /// The client's block, or nil when not blocked. Expiry is not
    /// evaluated here; the server's clock decides.
    public func clientBlock(_ clientId: String) -> BlockView? {
        blockView(clientId, value(try? BaseKeys.clientBlocked(clientId)))
    }
    public func roleBlock(_ role: String) -> BlockView? {
        blockView(role, value(try? BaseKeys.roleBlocked(role)))
    }
    /// Every blocked client, in id order.
    public func blockedClients() -> [BlockView] {
        collectBlocks("lasa.space.client.blocked.")
    }
    public func blockedRoles() -> [BlockView] {
        collectBlocks("lasa.space.role.blocked.")
    }

    /// Channel policy: muted flag and any set gain or attenuation override.
    public func channel(_ channel: String) -> ChannelPolicy {
        ChannelPolicy(
            muted: flag(try? BaseKeys.channelMuted(channel)),
            gain: value(try? BaseKeys.channelGain(channel))?.numberValue,
            attenuation: value(try? BaseKeys.channelAttenuation(channel))?.numberValue)
    }

    /// Every channel named by a live entity's membership or by channel policy, sorted.
    public func channels() -> [String] {
        var out = Set<String>()
        for e in entities() {
            out.formUnion(e.heardIn)
            out.formUnion(e.hears)
        }
        let prefix = "lasa.space.channel."
        for key in store.keys(withPrefix: prefix) {
            let rest = key.dropFirst(prefix.count)
            guard let dot = rest.firstIndex(of: ".") else { continue }
            let kind = rest[..<dot]
            let ch = String(rest[rest.index(after: dot)...])
            guard kind == "muted" || kind == "gain" || kind == "attenuation", isIdentifier(ch) else { continue }
            out.insert(ch)
        }
        return out.sorted()
    }

    private func value(_ key: String?) -> BaseValue? {
        key.flatMap { decodeValue(store.get($0)) }
    }
    private func flag(_ key: String?) -> Bool {
        value(key) == .bool(true)
    }

    private func collectBlocks(_ prefix: String) -> [BlockView] {
        var out: [BlockView] = []
        for key in store.keys(withPrefix: prefix) {
            let id = String(key.dropFirst(prefix.count))
            guard isIdentifier(id), let b = blockView(id, decodeValue(store.get(key))) else { continue }
            out.append(b)
        }
        return out.sorted { $0.id < $1.id }
    }
}

/// Builds a BaseView over a store.
public func baseView(store: any StateReadable) -> BaseView {
    BaseView(store)
}

private func blockView(_ id: String, _ v: BaseValue?) -> BlockView? {
    guard case .number(let n)? = v, n >= 0 else { return nil }
    return BlockView(id: id, until: n == 0 ? nil : Date(timeIntervalSince1970: n))
}

private func applyEntityKey(_ v: inout EntityView, _ suffix: String, _ value: BaseValue?) {
    guard let value else { return }
    let head: Substring, rest: String
    if let dot = suffix.firstIndex(of: ".") {
        head = suffix[..<dot]
        rest = String(suffix[suffix.index(after: dot)...])
    } else {
        head = Substring(suffix)
        rest = ""
    }
    switch head {
    case "name":
        if case .string(let s) = value { v.name = s }
    case "attrs":
        if !rest.isEmpty { v.attrs[rest] = value }
    case "signed-attrs":
        if !rest.isEmpty { v.signedAttrs[rest] = value }
    case "heard-in":
        if !rest.isEmpty, value == .bool(true) { v.heardIn.append(rest) }
    case "hears":
        if !rest.isEmpty, value == .bool(true) { v.hears.append(rest) }
    case "priority":
        v.priority = value == .bool(true)
    case "render":
        guard case .number(let n) = value else { break }
        switch rest {
        case "gain": v.render.gain = n
        case "attenuation": v.render.attenuation = n
        case "size": v.render.size = n
        case "directivity": v.render.directivity = n
        default: break
        }
    case "frame":
        if case .string(let s) = value, let f = Frame(rawValue: s) { v.frame = f }
    case "dof":
        if case .number(let n) = value, n == n.rounded(), let d = Dof(rawValue: Int(n)) { v.dof = d }
    case "mute":
        if !rest.isEmpty, value == .bool(true) { v.mutes.append(rest) }
    case "solo":
        if !rest.isEmpty, value == .bool(true) { v.solos.append(rest) }
    default:
        break
    }
}
