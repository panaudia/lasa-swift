// Golden-vector tests for the state-plane codecs: byte-exact against
// the Go `lasa/wire` (vectors generated from it, copied unchanged from
// lasa/typescript/tests/vectors/lasa-wire.json into Fixtures/wire/).
// Port of lasa/typescript/tests/statewire.test.ts, 2026-11-03. The one
// case not ported is "refuses to encode a seq-less op downstream": a
// Swift op always carries a seq (see StateWire.swift's header).

import XCTest
@testable import LasaSwift

final class StateWireTests: XCTestCase {
    struct Vec: Decodable {
        let name: String
        let hex: String
        let meta: Meta?
        struct Meta: Decodable {
            let sethash: String?
            let seq: UInt64?
            let prefixes: [String]?
        }
    }

    static let vectors: [String: Vec] = {
        let url = Bundle.module.url(forResource: "lasa-wire", withExtension: "json", subdirectory: "Fixtures/wire")!
        let vecs = try! JSONDecoder().decode([Vec].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: vecs.map { ($0.name, $0) })
    }()

    func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    func vec(_ name: String) throws -> Vec { try XCTUnwrap(Self.vectors[name], "missing vector \(name)") }
    func vecBytes(_ name: String) throws -> [UInt8] { bytes(try vec(name).hex) }

    func assertThrows<T>(_ expr: @autoclosure () throws -> T, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) { e in
            XCTAssertTrue("\(e)".contains(text), "error \"\(e)\" does not contain \"\(text)\"", file: file, line: line)
        }
    }

    static let key = "lasa.entity.e1.mute"
    static let value = Array("{\"muted\":true}".utf8)
    static let epoch: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04]

    static let cases: [(String, StateMessage, StateDirection)] = [
        ("state-set-up", .set(key: key, value: value, seq: 0), .upstream),
        ("state-set-down", .set(key: key, value: value, seq: 4242), .downstream),
        ("state-clear-up", .clear(key: key, seq: 0), .upstream),
        ("state-clear-down", .clear(key: key, seq: 4243), .downstream),
        ("state-group-down", .group([
            .set(SetOp(key: key, value: value, seq: 4242)),
            .clear(ClearOp(key: key, seq: 4243)),
        ]), .downstream),
        ("state-frontier", .frontier(epoch: epoch, seq: 99999), .downstream),
        ("state-begin-delta", .begin(.delta), .downstream),
        ("state-begin-snapshot", .begin(.snapshot), .downstream),
    ]

    // MARK: state messages

    func testEncodesByteExactly() throws {
        for (name, msg, dir) in Self.cases {
            XCTAssertEqual(hex(try StateWire.encodeStateMessage(msg, dir)), try vec(name).hex, name)
        }
    }

    func testRoundTripsThroughParse() throws {
        for (name, msg, dir) in Self.cases {
            XCTAssertEqual(try StateWire.parseStateMessage(try vecBytes(name), dir), msg, name)
        }
    }

    func testRejectsTrailingBytes() throws {
        // One message per object.
        let padded = try vecBytes("state-begin-delta") + [0]
        assertThrows(try StateWire.parseStateMessage(padded, .downstream), containing: "trailing")
    }

    func testRejectsDownstreamOnlyMessagesUpstream() throws {
        assertThrows(try StateWire.parseStateMessage(try vecBytes("state-frontier"), .upstream), containing: "downstream-only")
        assertThrows(try StateWire.parseStateMessage(try vecBytes("state-begin-delta"), .upstream), containing: "downstream-only")
    }

    func testParsesPerDirection() throws {
        // Downstream bytes carry a trailing seq the upstream layout lacks.
        XCTAssertNotEqual(try vec("state-set-down").hex, try vec("state-set-up").hex)
    }

    // MARK: subscribe params

    // Same deliberately unsorted, duplicated input as the generator.
    static let prefixes = ["lasa.space.", "lasa.entity.", "lasa.space."]

    func testEncodesFreshFormCanonically() throws {
        XCTAssertEqual(hex(try StateWire.encodeSubscribeParams(Self.prefixes)), try vec("subparams-fresh").hex)
        // And agrees with the partial codec in Wire/LasaWire.swift.
        XCTAssertEqual(try StateWire.encodeSubscribeParams(Self.prefixes), Lasa.stateSubscribeParams(prefixes: Self.prefixes))
    }

    func testEncodesCursorFormAndSetHashMatchesGo() throws {
        let v = try vec("subparams-cursor")
        let hash = try StateWire.setHash(Self.prefixes)
        XCTAssertEqual(hex(hash), try XCTUnwrap(v.meta?.sethash))
        let cursor = Cursor(epoch: Self.epoch, seq: 4242, setHash: hash)
        XCTAssertEqual(hex(try StateWire.encodeSubscribeParams(Self.prefixes, cursor: cursor)), v.hex)
    }

    func testRejectsEmptyPrefixSet() {
        assertThrows(try StateWire.encodeSubscribeParams([]), containing: "empty prefix set")
    }

    // MARK: key and prefix validation

    func enc(_ m: StateMessage) throws -> [UInt8] { try StateWire.encodeStateMessage(m, .upstream) }

    func testRejectsInvalidKeysOnEncode() {
        XCTAssertThrowsError(try enc(.set(key: "Bad Key", value: [], seq: 0)))
        XCTAssertThrowsError(try enc(.clear(key: "", seq: 0)))
        XCTAssertThrowsError(try enc(.set(key: String(repeating: "k", count: StateWire.maxKeyLen + 1), value: [], seq: 0)))
    }

    func testRejectsOverCapAndTruncatedKeysOnParse() {
        // set, key-len varint claiming 513 bytes
        let long: [UInt8] = [1, 0x42, 0x01] + [UInt8](repeating: 0x61, count: 513) + [0]
        assertThrows(try StateWire.parseStateMessage(long, .upstream), containing: "key too long")
        // clear, key-len 5 but only 2 key bytes present
        let truncated: [UInt8] = [2, 5, 0x61, 0x62]
        assertThrows(try StateWire.parseStateMessage(truncated, .upstream), containing: "truncated key")
    }

    func testRejectsKeysOutsideGrammarOnParse() {
        // clear with key "AB"
        let bad: [UInt8] = [2, 2, 0x41, 0x42]
        assertThrows(try StateWire.parseStateMessage(bad, .upstream), containing: "invalid key")
    }

    func testValidatesPrefixesSoSortIsBytewise() throws {
        assertThrows(try StateWire.canonicalPrefixes(["lasa.", "é"]), containing: "invalid prefix")
        XCTAssertEqual(try StateWire.canonicalPrefixes(["lasa.space.", "lasa.entity.", "lasa.entity."]), ["lasa.entity.", "lasa.space."])
        XCTAssertEqual(try StateWire.canonicalPrefixes([""]), [""]) // empty prefix stays legal
    }

    // MARK: upstream ops without seq

    // B10: the upstream layout never carries seq, so a client write must
    // not have to invent one.
    func testEncodesSeqLessSetIdenticallyToDummySeq() throws {
        let key = "lasa.x"
        let value: [UInt8] = [1, 2, 3]
        let a = try enc(.set(SetOp(key: key, value: value)))
        let b = try enc(.set(key: key, value: value, seq: 0))
        XCTAssertEqual(a, b)
        // The seq-less client type encodes to the same bytes.
        XCTAssertEqual(a, Lasa.UpstreamState.set(key: key, value: value).encode())
        XCTAssertEqual(try enc(Lasa.UpstreamState.clear(key: key).stateMessage), Lasa.UpstreamState.clear(key: key).encode())
        let c = try enc(.group([.clear(ClearOp(key: key))]))
        XCTAssertEqual(c[0], 3)
        // A client group encodes to the same bytes through either codec.
        let g = Lasa.UpstreamState.group([.set(key: key, value: value), .clear(key: key)])
        XCTAssertEqual(try enc(g.stateMessage), g.encode())
    }

    // MARK: extra Swift checks on the same vectors

    func testParsesEveryVectorDownstreamAsTheOlderCodecDoes() throws {
        // The partial parser in Wire/LasaWire.swift and this one agree on
        // every downstream vector.
        for (name, _, dir) in Self.cases where dir == .downstream {
            let b = try vecBytes(name)
            let old = try Lasa.parseDownstream(b)
            let new = try StateWire.parseStateMessage(b, .downstream)
            switch (old, new) {
            case (.set(let k, let v, let s), .set(let op)): XCTAssertEqual(SetOp(key: k, value: v, seq: s), op, name)
            case (.clear(let k, let s), .clear(let op)): XCTAssertEqual(ClearOp(key: k, seq: s), op, name)
            case (.group(let a), .group(let b)): XCTAssertEqual(a.count, b.count, name)
            case (.frontier(let e, let s), .frontier(let e2, let s2)): XCTAssertEqual(e, e2, name); XCTAssertEqual(s, s2, name)
            case (.begin(let k), .begin(let k2)): XCTAssertEqual(k, k2.rawValue, name)
            default: XCTFail("shape mismatch on \(name)")
            }
        }
    }

    func testRejectsUnknownBeginKindAndType() throws {
        assertThrows(try StateWire.parseStateMessage([5, 3], .downstream), containing: "unknown begin kind")
        assertThrows(try StateWire.parseStateMessage([9], .downstream), containing: "unknown state message type")
        assertThrows(try StateWire.parseStateMessage([], .downstream), containing: "empty")
    }

    func testRejectsNestedGroupsOnParse() throws {
        // group of one group
        assertThrows(try StateWire.parseStateMessage([3, 1, 3, 0], .downstream), containing: "do not nest")
    }
}
