import XCTest
@testable import LasaSwift

/// Vectors from lasa/typescript/tests/vectors/lasa-wire.json, so the
/// Swift wire agrees with the Go and TypeScript clients byte for byte.
final class LasaWireTests: XCTestCase {
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

    func testSinkSplitVectors() throws {
        let plain = bytes("00f801020304")
        let s = try XCTUnwrap(plain.withUnsafeBytes { Lasa.splitSink($0) })
        XCTAssertEqual(s.timestamp, 0)
        XCTAssertEqual(Array(plain[s.audio]), bytes("f801020304"))

        let ts = bytes("4040aa7deaf71e0600f801020304")
        let t = try XCTUnwrap(ts.withUnsafeBytes { Lasa.splitSink($0) })
        XCTAssertEqual(t.timestamp, 1722900000123456)
        XCTAssertEqual(Array(ts[t.audio]), bytes("f801020304"))

        let red = bytes("4c40aa7deaf71e06000500f801020304f80908")
        let r = try XCTUnwrap(red.withUnsafeBytes { Lasa.splitSink($0) })
        XCTAssertEqual(r.timestamp, 1722900000123456)
        XCTAssertEqual(Array(red[r.audio]), bytes("f801020304"))

        // A mono-object packet (pose bit set) is not a sink packet.
        XCTAssertNil(bytes("010000c03f").withUnsafeBytes { Lasa.splitSink($0) })
        XCTAssertNil([UInt8]().withUnsafeBytes { Lasa.splitSink($0) })
    }

    func testStateVectors() throws {
        let up = Lasa.UpstreamState.set(key: "lasa.entity.e1.mute", value: Array("{\"muted\":true}".utf8)).encode()
        XCTAssertEqual(hex(up), "01136c6173612e656e746974792e65312e6d7574650e7b226d75746564223a747275657d")
        XCTAssertEqual(hex(Lasa.UpstreamState.clear(key: "lasa.entity.e1.mute").encode()), "02136c6173612e656e746974792e65312e6d757465")

        let down = try Lasa.parseDownstream(bytes("01136c6173612e656e746974792e65312e6d7574650e7b226d75746564223a747275657d5092"))
        XCTAssertEqual(down, .set(key: "lasa.entity.e1.mute", value: Array("{\"muted\":true}".utf8), seq: 4242))
        XCTAssertEqual(try Lasa.parseDownstream(bytes("02136c6173612e656e746974792e65312e6d7574655093")), .clear(key: "lasa.entity.e1.mute", seq: 4243))
        let group = try Lasa.parseDownstream(bytes("030201136c6173612e656e746974792e65312e6d7574650e7b226d75746564223a747275657d509202136c6173612e656e746974792e65312e6d7574655093"))
        XCTAssertEqual(group, .group([
            .set(key: "lasa.entity.e1.mute", value: Array("{\"muted\":true}".utf8), seq: 4242),
            .clear(key: "lasa.entity.e1.mute", seq: 4243),
        ]))
        XCTAssertEqual(try Lasa.parseDownstream(bytes("04deadbeef010203048001869f")), .frontier(epoch: bytes("deadbeef01020304"), seq: 99999))
        XCTAssertEqual(try Lasa.parseDownstream(bytes("0501")), .begin(kind: 1))
        XCTAssertEqual(try Lasa.parseDownstream(bytes("0502")), .begin(kind: 2))
        // Trailing bytes are an error: one message per object.
        XCTAssertThrowsError(try Lasa.parseDownstream(bytes("050100")))
    }

    func testStateSubscribeParams() {
        // Deduplicated, sorted bytewise, flags 0, no cursor.
        let p = Lasa.stateSubscribeParams(prefixes: ["lasa.space.", "lasa.entity.", "lasa.space."])
        XCTAssertEqual(hex(p), "00020c6c6173612e656e746974792e0b6c6173612e73706163652e")
    }

    func testNamespacesAndConfig() throws {
        XCTAssertEqual(Lasa.entityNamespace(space: "main", entity: "e1", .sink), ["main", "entity", "e1", "sink"])
        XCTAssertEqual(Lasa.clientNamespace(space: "main", client: "c1", .source), ["main", "client", "c1", "source"])
        XCTAssertEqual(Lasa.presenceNamespace(space: "main"), ["main", "presence"])

        let cfg = Lasa.ConnectionConfig(clientID: "c1", entities: [Lasa.Entity(id: "e1", name: "probe", hears: ["main"])])
        let json = String(decoding: try cfg.json(), as: UTF8.self)
        XCTAssertEqual(json, #"{"client_id":"c1","entities":[{"hears":["main"],"id":"e1","name":"probe"}]}"#)
        XCTAssertEqual(try cfg.setupParam().type, 0x1A5A1)
    }
}
