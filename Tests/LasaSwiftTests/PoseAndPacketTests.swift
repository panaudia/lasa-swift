// Port of lasa/typescript/tests/wire.test.ts (every case), plus the
// discard-rule, malformed and encode-validation tables of
// lasa/wire/audio_test.go, which the TypeScript suite does not carry.
// Byte-exact against Fixtures/wire/lasa-wire.json, the vectors the Go
// generator wrote (lasa/typescript/tests/vectors/generator). 2026-11-03.

import XCTest
@testable import LasaSwift

final class PoseAndPacketTests: XCTestCase {
    // MARK: Vectors

    struct Vec: Decodable { let name: String; let hex: String }

    static let vectors: [String: [UInt8]] = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/wire/lasa-wire.json")
        let data = try! Data(contentsOf: url)
        let vecs = try! JSONDecoder().decode([Vec].self, from: data)
        return Dictionary(uniqueKeysWithValues: vecs.map { ($0.name, bytes($0.hex)) })
    }()

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func vec(_ name: String) throws -> [UInt8] {
        try XCTUnwrap(PoseAndPacketTests.vectors[name], "missing vector \(name)")
    }
    func bytes(_ hex: String) -> [UInt8] { PoseAndPacketTests.bytes(hex) }
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    static let poseBasic = Pose(x: 1.5, y: -2.25, z: 0.125, yaw: 1.0, pitch: -0.5, roll: 3.2)
    static let poseHex = "0000c03f000010c00000003ebe28a1ebff7f"
    let audio: [UInt8] = [0xf8, 1, 2, 3, 4]
    let red: [UInt8] = [0xf8, 9, 8]

    // MARK: Pose

    func testPoseEncodesByteExactly() throws {
        XCTAssertEqual(PoseAndPacketTests.poseBasic.encoded, try vec("pose-basic"))
        let clamp = Pose(x: 0, y: 0, z: 0, yaw: -4.0, pitch: 0, roll: 0)
        XCTAssertEqual(clamp.encoded, try vec("pose-clamp"))
        var w = ByteWriter()
        PoseAndPacketTests.poseBasic.encode(into: &w)
        XCTAssertEqual(w.bytes, try vec("pose-basic"))
    }

    func testPoseRoundTripsThroughParse() throws {
        let p = try Pose.parse(try vec("pose-basic"))
        XCTAssertEqual(p.x, 1.5, accuracy: 1e-6)
        XCTAssertEqual(p.y, -2.25, accuracy: 1e-6)
        XCTAssertEqual(p.z, 0.125, accuracy: 1e-6)
        XCTAssertEqual(p.yaw, 1.0, accuracy: 1e-4)
        XCTAssertEqual(p.pitch, -0.5, accuracy: 1e-4)
        XCTAssertEqual(p.roll, .pi, accuracy: 1e-4) // clamped at +pi
        XCTAssertEqual(p.encoded, try vec("pose-basic"))
        XCTAssertEqual(try Pose.parse(try vec("pose-clamp")).yaw, -.pi, accuracy: 1e-4)
        XCTAssertEqual(Pose.home.encoded, [UInt8](repeating: 0, count: 18))
        XCTAssertThrowsError(try Pose.parse(bytes("0000")))
    }

    func testPoseQuantiserRoundsHalfAwayFromZero() {
        // -0.5 quanta rounds to -1 in Go (math.Round), not to 0 as
        // JavaScript's Math.round would.
        let half = Float(-0.5 * Pose.angleQuantum)
        XCTAssertEqual(Pose.quantize(half), -1)
        XCTAssertEqual(Pose.quantize(-half), 1)
        XCTAssertEqual(Pose.quantize(10), 32767)
        XCTAssertEqual(Pose.quantize(-10), -32767)
        XCTAssertEqual(Pose.quantize(.nan), 0)
    }

    // MARK: Mono-object

    func testMonoObjectEncodesByteExactly() throws {
        let pose = PoseAndPacketTests.poseBasic
        let cases: [(String, MonoObjectPacket)] = [
            ("mono-pose-only", MonoObjectPacket(pose: pose)),
            ("mono-audio-only", MonoObjectPacket(audio: audio)),
            ("mono-both", MonoObjectPacket(pose: pose, audio: audio)),
            ("mono-redundancy", MonoObjectPacket(pose: pose, audio: audio, redundancy: Redundancy(offset: 3, audio: red))),
        ]
        for (name, pkt) in cases {
            XCTAssertEqual(hex(try pkt.encoded()), hex(try vec(name)), name)
            var w = ByteWriter()
            try pkt.encode(into: &w)
            XCTAssertEqual(w.bytes, try vec(name), name)
            // Re-encoding the parse reproduces the vector (Go's golden check).
            XCTAssertEqual(try MonoObjectPacket.parse(try vec(name)).encoded(), try vec(name), name)
        }
        // The Go goldens the TypeScript suite does not carry.
        XCTAssertEqual(hex(try MonoObjectPacket().encoded()), "00")
        XCTAssertEqual(hex(try MonoObjectPacket(audio: Array("abc".utf8),
                                                redundancy: Redundancy(offset: 3, audio: Array("de".utf8))).encoded()),
                       "1e" + "0300" + "616263" + "6465")
    }

    func testMonoObjectParsesTheRedundancyLayout() throws {
        let p = try MonoObjectPacket.parse(try vec("mono-redundancy"))
        XCTAssertEqual(try XCTUnwrap(p.pose).y, -2.25, accuracy: 1e-6)
        XCTAssertEqual(p.audio, audio)
        XCTAssertEqual(p.redundancy?.offset, 3)
        XCTAssertEqual(p.redundancy?.audio, red)
        XCTAssertEqual(p.flags, 0x1f)
        let only = try MonoObjectPacket.parse(try vec("mono-audio-only"))
        XCTAssertNil(only.pose)
        XCTAssertNil(only.redundancy)
        XCTAssertEqual(only.audio, audio)
    }

    func testMonoObjectRejectsSinkFlags() throws {
        XCTAssertThrowsError(try MonoObjectPacket.parse(try vec("sink-ts"))) { e in
            XCTAssertEqual(e as? LasaPacketError, .unknownFlags("mono-object"))
        }
    }

    func testAudioDiscardRule() throws {
        // Unknown flag bits: not this format, discard (ErrUnknownFlags).
        let mono: [(String, String)] = [
            ("mono reserved bit", "80"),
            ("mono ts bit", "40"),
            ("mono offset without redundancy", "0a" + "616263"),
        ]
        for (name, h) in mono {
            XCTAssertThrowsError(try MonoObjectPacket.parse(bytes(h)), name) { e in
                guard case .unknownFlags? = e as? LasaPacketError else { return XCTFail("\(name): \(e)") }
            }
        }
        let sink: [(String, String)] = [
            ("sink reserved bit", "80aabb"),
            ("sink pose bit", "01aabb"),
            ("sink audio bit", "02aabb"),
            ("sink offset without redundancy", "08aabb"),
        ]
        for (name, h) in sink {
            XCTAssertThrowsError(try SinkPacket.parse(bytes(h)), name) { e in
                guard case .unknownFlags? = e as? LasaPacketError else { return XCTFail("\(name): \(e)") }
            }
        }
    }

    func testAudioMalformed() throws {
        let poseHex = PoseAndPacketTests.poseHex
        let mono: [(String, String)] = [
            ("mono redundancy without audio", "05" + poseHex + "0100" + "ff" + "ee"),
            ("mono redundancy offset zero", "06" + "0100" + "ff" + "ee"),
            ("mono audio bit with empty payload", "02"),
            ("mono trailing bytes on pose-only", "01" + poseHex + "ff"),
            ("mono truncated pose", "010000"),
            ("mono truncated length prefix", "0e01"),
            ("mono dup missing", "0e" + "0200" + "aabb"),
            ("mono primary len zero", "0e" + "0000" + "ee"),
            ("empty", ""),
        ]
        for (name, h) in mono {
            XCTAssertThrowsError(try MonoObjectPacket.parse(bytes(h)), name) { e in
                guard case .malformed? = e as? LasaPacketError else { return XCTFail("\(name): \(e)") }
            }
        }
        let sink: [(String, String)] = [
            ("sink no audio", "00"),
            ("sink truncated ts", "40aabb"),
            ("sink dup missing", "0c" + "0200" + "aabb"),
            ("sink redundancy offset zero", "04" + "0100" + "ff" + "ee"),
            ("redundancy primary len zero", "0c" + "0000" + "ee"),
            ("sink truncated length prefix", "0c01"),
            ("empty", ""),
        ]
        for (name, h) in sink {
            XCTAssertThrowsError(try SinkPacket.parse(bytes(h)), name) { e in
                guard case .malformed? = e as? LasaPacketError else { return XCTFail("\(name): \(e)") }
            }
        }
    }

    func testMonoObjectEncodeValidation() {
        XCTAssertThrowsError(try MonoObjectPacket(redundancy: Redundancy(offset: 1, audio: [1])).encoded(),
                             "redundancy without audio must fail to encode")
        XCTAssertThrowsError(try MonoObjectPacket(audio: [1], redundancy: Redundancy(offset: 8, audio: [1])).encoded(),
                             "offset 8 must fail to encode")
        XCTAssertThrowsError(try MonoObjectPacket(audio: [1], redundancy: Redundancy(offset: 0, audio: [1])).encoded(),
                             "offset 0 must fail to encode")
        XCTAssertThrowsError(try MonoObjectPacket(audio: [1], redundancy: Redundancy(offset: 1, audio: [])).encoded(),
                             "empty redundancy payload must fail to encode")
        XCTAssertThrowsError(try MonoObjectPacket(audio: []).encoded(),
                             "empty (non-nil) audio must fail to encode")
    }

    // MARK: Sink

    func testSinkParsesPlainTsAndRedundancyLayouts() throws {
        let plain = try SinkPacket.parse(try vec("sink-plain"))
        XCTAssertNil(plain.timestamp)
        XCTAssertEqual(plain.audio, audio)
        XCTAssertNil(plain.redundancy)

        let ts = try SinkPacket.parse(try vec("sink-ts"))
        XCTAssertEqual(ts.timestamp, 1_722_900_000_123_456)
        XCTAssertEqual(ts.audio.count, 5)
        XCTAssertNil(ts.redundancy)

        let r = try SinkPacket.parse(try vec("sink-ts-redundancy"))
        XCTAssertEqual(r.timestamp, 1_722_900_000_123_456)
        XCTAssertEqual(r.redundancy?.offset, 1)
        XCTAssertEqual(r.audio.count, 5)
        XCTAssertEqual(r.audio, audio)
        XCTAssertEqual(r.redundancy?.audio, red)

        // Go's goldens: a zero-valued timestamp is present, not absent.
        let zero = try SinkPacket.parse(bytes("40" + "0000000000000000" + "aabb"))
        XCTAssertEqual(zero.timestamp, 0)
        XCTAssertEqual(try SinkPacket.parse(bytes("0c" + "0100" + "ff" + "ee")),
                       SinkPacket(audio: [0xff], redundancy: Redundancy(offset: 1, audio: [0xee])))
    }

    // MARK: Presence

    func testPresenceParsesTheKeyframeWithTheHeadFrameFlag() throws {
        guard case .keyframe(let kf) = try PresencePacket.parse(try vec("presence-keyframe")) else {
            return XCTFail("expected keyframe")
        }
        XCTAssertEqual(kf.gen, 7)
        XCTAssertEqual(kf.first, 2)
        XCTAssertEqual(kf.records.map(\.id), ["alice", "angel-1"])
        XCTAssertFalse(kf.records[0].headFrame)
        XCTAssertEqual(kf.records[0].loudness, 46)
        XCTAssertTrue(kf.records[1].headFrame)
        XCTAssertEqual(kf.records[1].loudness, Lasa.loudnessSilent)
        XCTAssertEqual(kf.records[1].pose.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(try PresencePacket.keyframe(kf).encoded(), try vec("presence-keyframe"))
    }

    func testPresenceParsesDeltas() throws {
        let packet = try PresencePacket.parse(try vec("presence-delta"))
        guard case .delta(let d) = packet else { return XCTFail("expected delta") }
        XCTAssertEqual(d.gen, 7)
        XCTAssertEqual(packet.gen, 7)
        XCTAssertEqual(d.records.map(\.index), [2, 3])
        XCTAssertEqual(d.records[0].loudness, 46)
        XCTAssertEqual(d.records[1].loudness, 255)
        XCTAssertEqual(try packet.encoded(), try vec("presence-delta"))
    }

    func testPresenceRejectsInvalidKrecordID() throws {
        // flags=keyframe, gen=0, first=0, then one krecord: kflags=0,
        // id-len=2, id="AB", pose (18 zero bytes), loudness=0.
        let bad: [UInt8] = [1, 0, 0, 0, 0, 2, 0x41, 0x42] + [UInt8](repeating: 0, count: 19)
        XCTAssertThrowsError(try PresencePacket.parse(bad)) { e in
            XCTAssertEqual(e as? LasaPacketError, .malformed("invalid krecord id"))
        }
        let good: [UInt8] = [1, 0, 0, 0, 0, 2, 0x61, 0x62] + [UInt8](repeating: 0, count: 19)
        XCTAssertNoThrow(try PresencePacket.parse(good))
        XCTAssertThrowsError(try PresencePacket.keyframe(
            PresenceKeyframe(gen: 0, first: 0, records: [KeyframeRecord(id: "AB", pose: .home, loudness: 0)])).encoded())
    }

    func testPresenceDiscardAndMalformed() throws {
        // Unknown packet flag bits and unknown krecord flag bits.
        XCTAssertThrowsError(try PresencePacket.parse([0x02, 0])) { e in
            XCTAssertEqual(e as? LasaPacketError, .unknownFlags("presence"))
        }
        let kflag: [UInt8] = [1, 0, 0, 0, 0x02, 1, 0x61] + [UInt8](repeating: 0, count: 19)
        XCTAssertThrowsError(try PresencePacket.parse(kflag)) { e in
            XCTAssertEqual(e as? LasaPacketError, .unknownFlags("krecord"))
        }
        // Too short, a partial delta record, a truncated krecord.
        for h in ["01", "", "0007" + "0200" + "00", "0107" + "0000" + "00"] {
            XCTAssertThrowsError(try PresencePacket.parse(bytes(h)), h) { e in
                guard case .malformed? = e as? LasaPacketError else { return XCTFail("\(h): \(e)") }
            }
        }
        // An empty keyframe is legal: the empty space is representable.
        XCTAssertEqual(try PresencePacket.parse([1, 3, 0, 0]),
                       .keyframe(PresenceKeyframe(gen: 3, first: 0, records: [])))
        XCTAssertEqual(try PresencePacket.parse([0, 3]), .delta(PresenceDelta(gen: 3, records: [])))
    }

    func testLoudnessToDBFS() {
        XCTAssertEqual(Lasa.loudnessToDBFS(0), 0)
        XCTAssertEqual(Lasa.loudnessToDBFS(46), -23)
        XCTAssertEqual(Lasa.loudnessToDBFS(254), -127)
        XCTAssertEqual(Lasa.loudnessToDBFS(Lasa.loudnessSilent), -.infinity)
    }
}
