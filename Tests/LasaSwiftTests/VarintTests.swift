import XCTest
@testable import LasaSwift

final class VarintTests: XCTestCase {
    // RFC 9000 appendix A.1 vectors.
    func testRoundTrip() {
        let cases: [(UInt64, [UInt8])] = [
            (37, [0x25]),
            (15293, [0x7b, 0xbd]),
            (494_878_333, [0x9d, 0x7f, 0x3e, 0x7d]),
            (151_288_809_941_952_652, [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]),
        ]
        for (value, bytes) in cases {
            var out = [UInt8]()
            Varint.encode(value, into: &out)
            XCTAssertEqual(out, bytes)
            var off = 0
            XCTAssertEqual(Varint.decode(bytes, offset: &off), value)
            XCTAssertEqual(off, bytes.count)
        }
    }

    func testTruncated() {
        var off = 0
        XCTAssertNil(Varint.decode([0x7b], offset: &off))
    }

    func testRecordLayout() throws {
        let w = RecordWriter(maxRecords: 2)
        w.append(seq: 7, arrivalNS: 1_000, serverUS: 0, payloadLen: 120)
        w.append(seq: 8, arrivalNS: 2_000, serverUS: 99, payloadLen: 121)
        w.append(seq: 9, arrivalNS: 3_000, serverUS: 0, payloadLen: 122)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w.dropped, 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-test.rec")
        try w.flush(to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 16 + 2 * 32)
        XCTAssertEqual(Array(data[0..<8]), Array("LASAPRB1".utf8))
        // second record's flags carry the server_us bit
        XCTAssertEqual(data[16 + 32 + 28], 1)
    }
}
