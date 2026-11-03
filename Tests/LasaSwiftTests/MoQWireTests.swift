import XCTest
@testable import LasaSwift

final class MoQWireTests: XCTestCase {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testParamsDeltaEncoding() throws {
        // Sorted ascending, delta-typed, odd types length-prefixed.
        let params = [KVP(Lasa.setupParamConnectionConfig, bytes: Array("{}".utf8)),
                      KVP(MoQ.setupParamMaxRequestID, varint: 100)]
        var w = ByteWriter()
        MoQ.encodeParams(params, into: &w)
        // count 2; type 2, 100 (0x4064); delta 0x1A5A1-2 = 0x1A59F (0x8001a59f); len 2; "{}"
        XCTAssertEqual(hex(w.bytes), "02" + "02" + "4064" + "8001a59f" + "02" + "7b7d")
        var r = ByteReader(w.bytes)
        let decoded = try MoQ.decodeParams(&r)
        XCTAssertEqual(decoded[MoQ.setupParamMaxRequestID], .varint(100))
        XCTAssertEqual(decoded[Lasa.setupParamConnectionConfig], .bytes(Array("{}".utf8)))
        XCTAssertTrue(r.isAtEnd)
    }

    func testControlFrame() throws {
        let msg = try MoQ.clientSetup(maxRequestID: 100, path: nil, extra: [])
        // type 0x20, length 0x0004, body: count 1, delta 2, 100
        XCTAssertEqual(hex(msg), "20" + "0004" + "01024064")
        let (f, n) = try XCTUnwrap(try MoQ.parseFrame(msg))
        XCTAssertEqual(f.type, 0x20)
        XCTAssertEqual(n, msg.count)
        XCTAssertEqual(f.body, [0x01, 0x02, 0x40, 0x64])
        // With the PATH parameter the server requires over raw QUIC:
        // count 2; type 1 (PATH, odd) len 1 "/"; delta 1 -> type 2, 100.
        let withPath = try MoQ.clientSetup(maxRequestID: 100, path: "/", extra: [])
        XCTAssertEqual(hex(withPath), "20" + "0007" + "02" + "01012f" + "014064")
        // A partial frame parses to nil, not an error.
        XCTAssertNil(try MoQ.parseFrame(Array(msg.prefix(5))))
        // The 16-bit bound.
        XCTAssertThrowsError(try MoQ.frame(.clientSetup, body: [UInt8](repeating: 0, count: 65536)))
        XCTAssertEqual(MoQ.frameUnchecked(.clientSetup, body: [UInt8](repeating: 0, count: 65536)).count, 65539)
    }

    func testSubscribeAndReplies() throws {
        let msg = try MoQ.subscribe(requestID: 4, namespace: ["main", "entity", "e1", "sink"], track: "binaural")
        let (f, _) = try XCTUnwrap(try MoQ.parseFrame(msg))
        XCTAssertEqual(f.type, 0x03)
        // An incoming SUBSCRIBE has the same body shape.
        let sub = try MoQ.parseIncomingSubscribe(f.body)
        XCTAssertEqual(sub.requestID, 4)
        XCTAssertEqual(sub.namespace, ["main", "entity", "e1", "sink"])
        XCTAssertEqual(sub.track, "binaural")
        XCTAssertEqual(sub.params[MoQ.subParamPriority], .varint(128))
        XCTAssertEqual(sub.params[MoQ.subParamGroupOrder], .varint(1))
        XCTAssertEqual(sub.params[MoQ.subParamForward], .varint(1))
        XCTAssertEqual(sub.params[MoQ.subParamFilter], .bytes([0x01]))

        var w = ByteWriter()
        w.varint(4); w.varint(7)
        MoQ.encodeParams([KVP(MoQ.subOkParamExpires, varint: 0), KVP(MoQ.subOkParamLargest, bytes: [0x05, 0x00])], into: &w)
        let ok = try MoQ.parseSubscribeOk(w.bytes)
        XCTAssertEqual(ok.requestID, 4)
        XCTAssertEqual(ok.trackAlias, 7)
        XCTAssertEqual(ok.params[MoQ.subOkParamLargest], .bytes([0x05, 0x00]))

        var e = ByteWriter()
        e.varint(4); e.varint(0x05); e.varint(0); e.string("nope")
        let err = try MoQ.parseSubscribeError(e.bytes)
        XCTAssertEqual(err.code, 5)
        XCTAssertEqual(err.reason, "nope")

        XCTAssertEqual(hex(try MoQ.subscribeOk(requestID: 9, trackAlias: 2)), "04" + "0003" + "090200")
    }

    func testObjectDatagramRoundTrip() throws {
        var out: [UInt8] = []
        let payload: [UInt8] = [0x40, 1, 2, 3]
        payload.withUnsafeBytes {
            MoQ.encodeObjectDatagram(into: &out, trackAlias: 3, groupID: 70000, objectID: 0, priority: 128, payload: $0)
        }
        XCTAssertEqual(hex(out), "00" + "03" + "80011170" + "00" + "80" + "40010203")
        let d = try XCTUnwrap(out.withUnsafeBytes { MoQ.parseObjectDatagram($0) })
        XCTAssertEqual(d.trackAlias, 3)
        XCTAssertEqual(d.groupID, 70000)
        XCTAssertEqual(d.objectID, 0)
        XCTAssertEqual(d.priority, 128)
        XCTAssertEqual(Array(out[d.payloadOffset...]), payload)
        XCTAssertFalse(d.isStatus)

        // Type 0x01: a 2-byte extension block is skipped.
        let ext: [UInt8] = [0x01, 0x03, 0x05, 0x00, 0x80, 0x02, 0xaa, 0xbb, 0x40, 0x01]
        let de = try XCTUnwrap(ext.withUnsafeBytes { MoQ.parseObjectDatagram($0) })
        XCTAssertEqual(Array(ext[de.payloadOffset...]), [0x40, 0x01])
        // Status datagram.
        let st: [UInt8] = [0x02, 0x03, 0x05, 0x00, 0x80, 0x00]
        XCTAssertTrue(try XCTUnwrap(st.withUnsafeBytes { MoQ.parseObjectDatagram($0) }).isStatus)
    }

    func testSubgroupWriterAndParser() throws {
        let w = MoQ.SubgroupWriter(trackAlias: 2, groupID: 0, subgroupID: 0, priority: 0)
        let first = w.encode(objectID: 0, payload: [0xaa])
        // header 0x15, alias 2, group 0, sid 0, priority 0; object: delta 0, ext len 0, len 1, 0xaa
        XCTAssertEqual(hex(first), "1502000000" + "000001aa")
        let second = w.encode(objectID: 1, payload: [0xbb, 0xcc])
        XCTAssertEqual(hex(second), "000002bbcc")
        let third = w.encode(objectID: 5, payload: [])
        XCTAssertEqual(hex(third), "03000000") // delta 5-1-1, no ext, len 0, status 0

        // Fed byte by byte, the parser emits the same events.
        let all = first + second + third
        let p = MoQ.SubgroupParser()
        var events: [MoQ.SubgroupEvent] = []
        for b in all {
            events += try [b].withUnsafeBytes { try p.feed($0) }
        }
        XCTAssertEqual(events, [
            .header(MoQ.SubgroupHeader(trackAlias: 2, groupID: 0, subgroupID: 0, priority: 0, endOfGroup: false)),
            .object(objectID: 0, payload: [0xaa]),
            .object(objectID: 1, payload: [0xbb, 0xcc]),
            .object(objectID: 5, payload: []),
        ])
        XCTAssertThrowsError(try [0x05, 0x00].withUnsafeBytes { try MoQ.SubgroupParser().feed($0) })
    }
}
