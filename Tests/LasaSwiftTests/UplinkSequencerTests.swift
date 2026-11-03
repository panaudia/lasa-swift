// Port of lasa/typescript/tests/uplink-sequencer.test.ts (every case)
// with lasa/client/redundancy_test.go's cases as the fixtures the port
// map names. Every case round-trips the stamped bytes through the wire
// parser, so a record attached to an audio-less packet (which the wire
// rejects) would surface as a throw, and the offset and payload are
// checked on the decoded bytes. 2026-11-03.
//
// The two TypeScript cases about a caller-supplied redundancy record
// (pass-through at offset 0, replacement above it) have no caller
// record here: the Swift API takes audio and pose only, so they become
// the offset-0 case below. The fractional-offset clamp (2.9 to 2) is a
// JavaScript concern with no Int counterpart.

import XCTest
@testable import LasaSwift

final class UplinkSequencerTests: XCTestCase {
    func audioOf(_ seq: Int) -> [UInt8] {
        [0xa0, UInt8(seq & 0xff), 0xc0, UInt8((seq >> 8) & 0xff)]
    }
    let pose = Pose(x: 1, y: 2, z: 3, yaw: 0.5, pitch: 0, roll: 0)

    func roundTrip(_ s: UplinkSequencer.Stamped, file: StaticString = #filePath, line: UInt = #line) throws -> MonoObjectPacket {
        let parsed = try MonoObjectPacket.parse(s.bytes)
        // The pose compares by its encoding: parse quantises the angles.
        XCTAssertEqual(parsed.pose?.encoded, s.packet.pose?.encoded, "the stamped packet and its bytes agree", file: file, line: line)
        XCTAssertEqual(parsed.audio, s.packet.audio, file: file, line: line)
        XCTAssertEqual(parsed.redundancy, s.packet.redundancy, file: file, line: line)
        XCTAssertEqual(try s.packet.encoded(), s.bytes, file: file, line: line)
        return parsed
    }

    func testHandsOutAGaplessSeqFrom0AndAttachesNothingAtOffset0() throws {
        var s = UplinkSequencer(declared: 0)
        for i in 0..<5 {
            let st = s.next(audio: audioOf(i), pose: pose)
            XCTAssertEqual(st.seq, UInt64(i))
            let out = try roundTrip(st)
            XCTAssertNil(out.redundancy)
            XCTAssertEqual(out.audio, audioOf(i))
            XCTAssertEqual(out.pose?.x, 1)
        }
        XCTAssertEqual(s.nextSeq, 5)
        XCTAssertEqual(s.redundancy, 0)
        XCTAssertEqual(s.declared, 0)
        // Pose-only and empty packets take a seq too (C-5.1-1).
        XCTAssertEqual(s.next(audio: nil, pose: pose).seq, 5)
        XCTAssertEqual(s.next(audio: nil, pose: nil).bytes, [0x00])
        XCTAssertEqual(s.nextSeq, 7)
    }

    func testAttachesACopyOfTheFrameOffsetPacketsBackFromTheFirstSeqWhoseReferenceExists() throws {
        var s = UplinkSequencer(declared: 3)
        var scratch = [UInt8](repeating: 0, count: 4) // reused like a real encoder buffer
        for i in 0..<20 {
            scratch.replaceSubrange(0..<4, with: audioOf(i))
            let st = s.next(audio: scratch, pose: pose)
            XCTAssertEqual(st.seq, UInt64(i))
            let out = try roundTrip(st)
            if i < 3 {
                XCTAssertNil(out.redundancy, "seq \(i)")
                continue
            }
            XCTAssertEqual(out.redundancy?.offset, 3, "seq \(i)")
            XCTAssertEqual(out.redundancy?.audio, audioOf(i - 3), "seq \(i): a copy, not the reused scratch")
            XCTAssertEqual(out.audio, audioOf(i))
        }
    }

    func testOmitsTheRecordWhenTheReferencedPacketWasPoseOnlyNeverSubstitutingAnotherOffset() throws {
        var s = UplinkSequencer(declared: 2)
        func send(_ i: Int, _ audio: Bool) throws -> MonoObjectPacket {
            let st = s.next(audio: audio ? audioOf(i) : nil, pose: pose)
            XCTAssertEqual(st.seq, UInt64(i))
            return try roundTrip(st)
        }
        _ = try send(0, true)
        _ = try send(1, true)
        let poseOnly = try send(2, false)
        XCTAssertNil(poseOnly.audio)
        XCTAssertNil(poseOnly.redundancy)
        XCTAssertEqual(poseOnly.pose?.x, 1)
        XCTAssertEqual(try send(3, true).redundancy?.audio, audioOf(1))
        XCTAssertNil(try send(4, true).redundancy, "references pose-only seq 2")
        XCTAssertEqual(try send(5, true).redundancy?.audio, audioOf(3))
        XCTAssertEqual(try send(5 + 1, true).redundancy?.offset, 2)
    }

    func testEmptyAudioIsPoseOnly() throws {
        var s = UplinkSequencer(declared: 1)
        _ = s.next(audio: audioOf(0), pose: pose)
        let st = s.next(audio: [], pose: pose)
        let out = try roundTrip(st)
        XCTAssertNil(out.audio)
        XCTAssertNil(out.redundancy)
        XCTAssertNil(try roundTrip(s.next(audio: audioOf(2), pose: nil)).redundancy, "references the empty one")
    }

    func testSetRedundancyLowersAndRaisesTheOffsetLiveClampedToTheDeclaration() throws {
        var s = UplinkSequencer(declared: 9)
        XCTAssertEqual(s.declared, 7)
        XCTAssertEqual(s.redundancy, 7)
        s.setRedundancy(-2)
        XCTAssertEqual(s.redundancy, 0)
        s.setRedundancy(2)
        XCTAssertEqual(s.redundancy, 2)
        s.setRedundancy(8)
        XCTAssertEqual(s.redundancy, 7, "clamped to the declaration")
        s.setRedundancy(2)
        for i in 0..<3 { _ = s.next(audio: audioOf(i), pose: pose) }
        s.setRedundancy(0)
        let off = s.next(audio: audioOf(3), pose: pose)
        XCTAssertNil(try roundTrip(off).redundancy)
        // Raised again: the ring kept recording at offset 0, so the
        // reference is there at once.
        s.setRedundancy(1)
        XCTAssertEqual(try roundTrip(s.next(audio: audioOf(4), pose: pose)).redundancy?.audio, audioOf(3))
        XCTAssertEqual(UplinkSequencer(declared: -1).declared, 0)
        var declared3 = UplinkSequencer(declared: 3)
        declared3.setRedundancy(5)
        XCTAssertEqual(declared3.redundancy, 3)
    }

    func testRepeatsAPayloadLargerThanAFrameInFull() throws {
        var s = UplinkSequencer(declared: 1)
        let big = [UInt8](repeating: 7, count: 500)
        _ = s.next(audio: big, pose: pose)
        let st = s.next(audio: audioOf(1), pose: pose)
        let out = try roundTrip(st)
        XCTAssertEqual(out.redundancy?.audio.count, 500)
        XCTAssertEqual(out.redundancy?.audio, big)
        XCTAssertEqual(out.audio, audioOf(1))
    }

    func testContinuousAudioAtOffset7AcrossRingLaps() throws {
        // Go's TestUplinkRedundancyContinuousAudio at the wire maximum:
        // slot (seq - 7) % 8 is never the slot being written at seq.
        var s = UplinkSequencer(declared: 7)
        for i in 0..<40 {
            let out = try roundTrip(s.next(audio: Array("frame-\(i)".utf8), pose: nil))
            if i < 7 {
                XCTAssertNil(out.redundancy)
            } else {
                XCTAssertEqual(out.redundancy?.offset, 7)
                XCTAssertEqual(out.redundancy?.audio, Array("frame-\(i - 7)".utf8), "seq \(i)")
            }
        }
    }

    func testStampedBytesMatchTheVectorLayout() throws {
        // The mono-redundancy vector: pose, 5 audio bytes, offset 3, a
        // 3-byte copy; reproduced by sending the copy's frame three
        // packets earlier.
        let vector = PoseAndPacketTests.bytes("1f0000c03f000010c00000003ebe28a1ebff7f0500f801020304f80908")
        let p = Pose(x: 1.5, y: -2.25, z: 0.125, yaw: 1.0, pitch: -0.5, roll: 3.2)
        var s = UplinkSequencer(declared: 3)
        _ = s.next(audio: [0xf8, 9, 8], pose: p)
        _ = s.next(audio: nil, pose: p)
        _ = s.next(audio: nil, pose: p)
        let st = s.next(audio: [0xf8, 1, 2, 3, 4], pose: p)
        XCTAssertEqual(st.seq, 3)
        XCTAssertEqual(st.bytes, vector)
    }
}
