import XCTest
@testable import LasaSwift

final class OpusPacketTests: XCTestCase {
    /// Parses a code 3 packet's header the way libopus's opus_packet_parse
    /// does and returns (frame data, padding bytes).
    func parseCode3(_ p: [UInt8]) throws -> (data: [UInt8], pad: Int) {
        XCTAssertEqual(p[0] & 0x03, 3, "code 3")
        XCTAssertEqual(p[1] & 0x80, 0, "CBR")
        XCTAssertEqual(p[1] & 0x3f, 1, "one frame")
        XCTAssertEqual(p[1] & 0x40, 0x40, "padding flag")
        var i = 2
        var len = p.count - 2
        var pad = 0
        while true {
            let b = Int(p[i]); i += 1; len -= 1
            let tmp = b == 255 ? 254 : b
            pad += tmp; len -= tmp
            if b != 255 { break }
        }
        XCTAssertGreaterThanOrEqual(len, 0)
        let data = Array(p[i..<i + len])
        let padding = p[(i + len)...]
        XCTAssertEqual(padding.count, pad)
        XCTAssertTrue(padding.allSatisfy { $0 == 0 }, "padding is zero")
        return (data, pad)
    }

    func testPaddedSizesAndContent() throws {
        let frame = Lasa.opusSilenceFrame
        XCTAssertEqual(frame[0] & 0x03, 0)
        for size in [5, 6, 30, 120, 259, 260, 261, 514, 515, 1150, 1275] {
            let p = Lasa.opusPadded(frame, toSize: size)
            XCTAssertEqual(p.count, size, "size \(size)")
            XCTAssertEqual(p[0] & 0xfc, frame[0] & 0xfc, "config and channel bits kept")
            let (data, _) = try parseCode3(p)
            XCTAssertEqual(data, Array(frame.dropFirst()), "frame data intact at \(size)")
        }
        // Under the minimum the frame comes back as is.
        XCTAssertEqual(Lasa.opusPadded(frame, toSize: 4), frame)
    }

    func testPacketShapes() {
        let s = Lasa.silencePacket(size: 120)
        XCTAssertEqual(s.count, 120)
        XCTAssertEqual(s[0], 0x02, "audio flag only")
        XCTAssertEqual(s[1] & 0x03, 3)
        let d = Lasa.discardPacket(size: 200)
        XCTAssertEqual(d.count, 200)
        XCTAssertEqual(d[0] & 0x80, 0x80, "reserved bit set")
        XCTAssertNil(Lasa.splitSink(d.withUnsafeBytes { UnsafeRawBufferPointer($0) }), "not a sink packet either")
    }
}
