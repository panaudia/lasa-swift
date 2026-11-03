// Base-profile helper tests: key builders and the value codec against
// the literals Go profile/base writes and reads, the ops each control
// emits, and the read view over a populated store. Ported from
// lasa/typescript/tests/base.test.ts on 2026-11-03.
//
// Divergences: a multi-op write is asserted as its ops in order within
// one writeState call (the TypeScript asserts a `group(` ... `)` frame;
// see Base.swift's header on the pending group case); the invalid-dof
// case asserts the Dof enum rejects 4; extra encode cases cover the
// JSON number grammar's exponent thresholds, which the Swift formatter
// implements by hand.

import Foundation
import XCTest
@testable import LasaSwift

/// Captures writes; `last` is the most recent call's ops.
final class FakeWriter: StateWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[Lasa.UpstreamState]] = []
    var calls: [[Lasa.UpstreamState]] { lock.withLock { _calls } }
    var last: [Lasa.UpstreamState] { calls.last! }
    func writeState(_ ops: [Lasa.UpstreamState]) async throws {
        lock.withLock { _calls.append(ops) }
    }
}

/// A dictionary-backed store for the read view.
final class DictStore: StateReadable, @unchecked Sendable {
    private let lock = NSLock()
    private var kv: [String: [UInt8]] = [:]
    func put(_ key: String, _ value: String) { lock.withLock { kv[key] = Array(value.utf8) } }
    func clear(_ key: String) { lock.withLock { kv[key] = nil } }
    func get(_ key: String) -> [UInt8]? { lock.withLock { kv[key] } }
    func keys(withPrefix prefix: String) -> [String] {
        // Deliberately unsorted: the view must not depend on store order.
        lock.withLock { kv.keys.filter { $0.hasPrefix(prefix) } }
    }
}

private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func enc(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Renders ops as `key=value` / `-key` strings for compact assertions;
/// a group renders as its members in order (the TypeScript tests assert
/// the same flat view).
private func flat(_ ops: [Lasa.UpstreamState]) -> [String] {
    ops.flatMap { op -> [String] in
        switch op {
        case .set(let key, let value): return ["\(key)=\(text(value))"]
        case .clear(let key): return ["-\(key)"]
        case .group(let inner): return flat(inner)
        }
    }
}

private func assertMalformed<T>(_ expr: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expr(), file: file, line: line) { err in
        XCTAssertTrue(err is MalformedError, "expected MalformedError, got \(err)", file: file, line: line)
    }
}

private func assertMalformedAsync<T>(_ expr: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expr()
        XCTFail("expected MalformedError", file: file, line: line)
    } catch {
        XCTAssertTrue(error is MalformedError, "expected MalformedError, got \(error)", file: file, line: line)
    }
}

final class BaseTests: XCTestCase {

    // MARK: value codec (§1, parity with Go literals)

    func testEncodesTheThreeTypesAsGoWritesThem() throws {
        XCTAssertEqual(text(try encodeValue(true)), "true")
        XCTAssertEqual(text(try encodeValue(false)), "false")
        XCTAssertEqual(text(try encodeValue("head")), "\"head\"")
        XCTAssertEqual(text(try encodeValue("c-1")), "\"c-1\"")
        XCTAssertEqual(text(try encodeValue(1.5)), "1.5")
        XCTAssertEqual(text(try encodeValue(6)), "6")
        XCTAssertEqual(text(try encodeValue(0)), "0")
        XCTAssertEqual(text(try encodeValue(1700000000)), "1700000000")
    }

    func testEncodesNumbersInJSONGrammar() throws {
        // JSON.stringify / Go encoding/json forms at the exponent thresholds.
        XCTAssertEqual(text(try encodeValue(.number(-0.0))), "0")
        XCTAssertEqual(text(try encodeValue(-1.5)), "-1.5")
        XCTAssertEqual(text(try encodeValue(1e6)), "1000000")
        XCTAssertEqual(text(try encodeValue(0.1)), "0.1")
        XCTAssertEqual(text(try encodeValue(0.000001)), "0.000001")
        XCTAssertEqual(text(try encodeValue(1e-7)), "1e-7")
        XCTAssertEqual(text(try encodeValue(2.5e-8)), "2.5e-8")
        XCTAssertEqual(text(try encodeValue(1e20)), "100000000000000000000")
        XCTAssertEqual(text(try encodeValue(1e21)), "1e+21")
        XCTAssertEqual(text(try encodeValue(1.2345678901234568e+20)), "123456789012345680000")
        XCTAssertEqual(text(try encodeValue(1.2345678901234567e+19)), "12345678901234567000")
        XCTAssertEqual(text(try encodeValue(1.7976931348623157e+308)), "1.7976931348623157e+308")
        XCTAssertEqual(text(try encodeValue(5e-324)), "5e-324")
        XCTAssertEqual(text(try encodeValue(123.456)), "123.456")
        // Escaping agrees with JSON.stringify for the mandatory escapes.
        XCTAssertEqual(text(try encodeValue("a\"b\\c\n\u{1}")), "\"a\\\"b\\\\c\\n\\u0001\"")
        XCTAssertEqual(text(try encodeValue("héllo")), "\"héllo\"")
    }

    func testRejectsNonFiniteNumbers() {
        assertMalformed(try encodeValue(.number(.nan)))
        assertMalformed(try encodeValue(.number(.infinity)))
    }

    func testDecodesGoWrittenBytesInclAppendFloatGForms() {
        XCTAssertEqual(decodeValue(enc("true")), .bool(true))
        XCTAssertEqual(decodeValue(enc("\"alice\"")), .string("alice"))
        XCTAssertEqual(decodeValue(enc("2.3")), .number(2.3))
        XCTAssertEqual(decodeValue(enc("1e+06")), .number(1_000_000))
        XCTAssertEqual(decodeValue(enc("6")), .number(6))
        XCTAssertEqual(decodeValue(enc("false")), .bool(false))
        XCTAssertEqual(decodeValue(enc("0")), .number(0))
        XCTAssertEqual(decodeValue(enc("1")), .number(1))
    }

    func testTreatsAbsentAndInvalidValuesAsAbsent() {
        XCTAssertNil(decodeValue(nil))
        XCTAssertNil(decodeValue(enc("")))
        XCTAssertNil(decodeValue(enc("not json")))
        XCTAssertNil(decodeValue(enc("[1,2]")))
        XCTAssertNil(decodeValue(enc("{\"a\":1}")))
        XCTAssertNil(decodeValue(enc("null")))
    }

    // MARK: key builders (§6, parity with Go keys.go)

    func testBuildsEveryVocabularyKey() throws {
        XCTAssertEqual(try BaseKeys.entityMarker("e1"), "lasa.entity.e1")
        XCTAssertEqual(try BaseKeys.name("e1"), "lasa.entity.e1.name")
        XCTAssertEqual(try BaseKeys.attr("e1", "colour"), "lasa.entity.e1.attrs.colour")
        XCTAssertEqual(try BaseKeys.attr("e1", "avatar.hat"), "lasa.entity.e1.attrs.avatar.hat")
        XCTAssertEqual(try BaseKeys.signedAttr("e1", "tier"), "lasa.entity.e1.signed-attrs.tier")
        XCTAssertEqual(try BaseKeys.heardIn("e1", "main"), "lasa.entity.e1.heard-in.main")
        XCTAssertEqual(try BaseKeys.hears("e1", "stage"), "lasa.entity.e1.hears.stage")
        XCTAssertEqual(try BaseKeys.priority("e1"), "lasa.entity.e1.priority")
        XCTAssertEqual(try BaseKeys.renderGain("e1"), "lasa.entity.e1.render.gain")
        XCTAssertEqual(try BaseKeys.renderAttenuation("e1"), "lasa.entity.e1.render.attenuation")
        XCTAssertEqual(try BaseKeys.renderSize("e1"), "lasa.entity.e1.render.size")
        XCTAssertEqual(try BaseKeys.renderDirectivity("e1"), "lasa.entity.e1.render.directivity")
        XCTAssertEqual(try BaseKeys.frame("e1"), "lasa.entity.e1.frame")
        XCTAssertEqual(try BaseKeys.dof("e1"), "lasa.entity.e1.dof")
        XCTAssertEqual(try BaseKeys.personalMute("e1", "e2"), "lasa.entity.e1.mute.e2")
        XCTAssertEqual(try BaseKeys.personalSolo("e1", "e2"), "lasa.entity.e1.solo.e2")
        XCTAssertEqual(try BaseKeys.spaceEntityMuted("e1"), "lasa.space.entity.muted.e1")
        XCTAssertEqual(try BaseKeys.clientBlocked("c1"), "lasa.space.client.blocked.c1")
        XCTAssertEqual(try BaseKeys.roleBlocked("noisy"), "lasa.space.role.blocked.noisy")
        XCTAssertEqual(try BaseKeys.channelMuted("stage"), "lasa.space.channel.muted.stage")
        XCTAssertEqual(try BaseKeys.channelGain("stage"), "lasa.space.channel.gain.stage")
        XCTAssertEqual(try BaseKeys.channelAttenuation("stage"), "lasa.space.channel.attenuation.stage")
    }

    func testAcceptsLowercaseUUIDAndRejectsGrammarViolations() throws {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        XCTAssertTrue(isIdentifier(uuid))
        XCTAssertEqual(try BaseKeys.entityMarker(uuid), "lasa.entity.\(uuid)")
        for bad in ["", "Alice", "a.b", "a_b", String(repeating: "a", count: 129), "550E8400-E29B-41D4-A716-446655440000"] {
            XCTAssertFalse(isIdentifier(bad), bad)
            assertMalformed(try BaseKeys.entityMarker(bad))
        }
        XCTAssertTrue(isIdentifier(String(repeating: "a", count: 128)))
        assertMalformed(try BaseKeys.personalMute("e1", "Other"))
        assertMalformed(try BaseKeys.heardIn("e1", "Main"))
        // Attr paths are dotted identifiers, never empty segments.
        assertMalformed(try BaseKeys.attr("e1", "a..b"))
        assertMalformed(try BaseKeys.attr("e1", ".a"))
        assertMalformed(try BaseKeys.attr("e1", "a."))
        assertMalformed(try BaseKeys.attr("e1", ""))
        assertMalformed(try BaseKeys.attr("e1", "Colour"))
    }

    // MARK: EntityControls (owner scope)

    func testEntityControlsEmitOneOpPerCall() async throws {
        let w = FakeWriter()
        let me = try EntityControls(w, entityId: "e1")
        try await me.mute("e2")
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.mute.e2=true"])
        try await me.unmute("e2")
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.mute.e2"])
        try await me.solo("e3")
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.solo.e3=true"])
        try await me.unsolo("e3")
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.solo.e3"])
        try await me.setAttr("colour", "00aaff")
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.attrs.colour=\"00aaff\""])
        try await me.clearAttr("colour")
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.attrs.colour"])
        XCTAssertEqual(w.calls.count, 6)
    }

    func testGroupsSeveralAttrsIntoOneWriteASingleAttrStaysBare() async throws {
        let w = FakeWriter()
        let me = try EntityControls(w, entityId: "e1")
        try await me.setAttrs(["colour": "00aaff", "avatar.hat": true, "score": 3])
        // One write, the attrs in path order (a dictionary has none).
        XCTAssertEqual(flat(w.last), [
            "lasa.entity.e1.attrs.avatar.hat=true",
            "lasa.entity.e1.attrs.colour=\"00aaff\"",
            "lasa.entity.e1.attrs.score=3",
        ])
        try await me.setAttrs(["colour": "ff0000"])
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.attrs.colour=\"ff0000\""])
        try await me.setAttrs([:])
        XCTAssertEqual(flat(w.last), [])
        XCTAssertEqual(w.calls.count, 3)
    }

    func testValidatesIdsAtConstructionAndPerCall() async throws {
        let w = FakeWriter()
        assertMalformed(try EntityControls(w, entityId: "Me"))
        let me = try EntityControls(w, entityId: "e1")
        await assertMalformedAsync { try await me.mute("Bad") }
        await assertMalformedAsync { try await me.setAttr("Bad", true) }
        XCTAssertEqual(w.calls.count, 0)
    }

    // MARK: SpaceControls (moderation, channels, rendering)

    func testModerationEntityMuteAndBlocks() async throws {
        let w = FakeWriter()
        let space = SpaceControls(w)
        try await space.muteEntity("e1")
        XCTAssertEqual(flat(w.last), ["lasa.space.entity.muted.e1=true"])
        try await space.unmuteEntity("e1")
        XCTAssertEqual(flat(w.last), ["-lasa.space.entity.muted.e1"])

        try await space.blockClient("c1")
        XCTAssertEqual(flat(w.last), ["lasa.space.client.blocked.c1=0"])
        try await space.blockClient("c1", until: Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(flat(w.last), ["lasa.space.client.blocked.c1=1700000000"])
        try await space.unblockClient("c1")
        XCTAssertEqual(flat(w.last), ["-lasa.space.client.blocked.c1"])

        try await space.blockRole("noisy", until: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(flat(w.last), ["lasa.space.role.blocked.noisy=1700000000"])
        try await space.unblockRole("noisy")
        XCTAssertEqual(flat(w.last), ["-lasa.space.role.blocked.noisy"])
        await assertMalformedAsync { try await space.blockClient("c1", until: Date(timeIntervalSince1970: -5)) }
    }

    func testKickIsABlockExpiringForMsFromNow() async throws {
        let w = FakeWriter()
        let space = SpaceControls(w)
        let before = Date().timeIntervalSince1970.rounded(.down)
        try await space.kickClient("c1", forMs: 5 * 60_000)
        guard case .set(let key, let value) = w.last[0] else { return XCTFail("expected set") }
        XCTAssertEqual(key, "lasa.space.client.blocked.c1")
        let until = try XCTUnwrap(decodeValue(value)?.numberValue)
        XCTAssertGreaterThanOrEqual(until, before + 300)
        XCTAssertLessThanOrEqual(until, before + 301)
        await assertMalformedAsync { try await space.kickClient("c1", forMs: 0) }
        await assertMalformedAsync { try await space.kickClient("c1", forMs: -1) }
        XCTAssertEqual(w.calls.count, 1)
    }

    func testChannelPolicyMuteGainAttenuation() async throws {
        let w = FakeWriter()
        let space = SpaceControls(w)
        try await space.muteChannel("stage")
        XCTAssertEqual(flat(w.last), ["lasa.space.channel.muted.stage=true"])
        try await space.unmuteChannel("stage")
        XCTAssertEqual(flat(w.last), ["-lasa.space.channel.muted.stage"])
        try await space.setChannelGain("stage", 1.5)
        XCTAssertEqual(flat(w.last), ["lasa.space.channel.gain.stage=1.5"])
        try await space.setChannelGain("stage", nil)
        XCTAssertEqual(flat(w.last), ["-lasa.space.channel.gain.stage"])
        try await space.setChannelAttenuation("whisper", 3)
        XCTAssertEqual(flat(w.last), ["lasa.space.channel.attenuation.whisper=3"])
        try await space.setChannelAttenuation("whisper", nil)
        XCTAssertEqual(flat(w.last), ["-lasa.space.channel.attenuation.whisper"])
        await assertMalformedAsync { try await space.setChannelGain("stage", 3.1) }
        await assertMalformedAsync { try await space.setChannelAttenuation("stage", -0.1) }
        await assertMalformedAsync { try await space.setChannelGain("stage", .nan) }
        XCTAssertEqual(w.calls.count, 6)
    }

    func testMembershipSingleAddsRemovesAndDiffedReplace() async throws {
        let w = FakeWriter()
        let space = SpaceControls(w)
        try await space.addHeardIn("e1", "stage")
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.heard-in.stage=true"])
        try await space.removeHears("e1", "main")
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.hears.main"])
        try await space.addHears("e1", "stage")
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.hears.stage=true"])
        try await space.removeHeardIn("e1", "main")
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.heard-in.main"])

        try await space.setChannels(
            "e1", current: ChannelMemberships(heardIn: ["main"], hears: ["main", "stage"]),
            heardIn: ["stage"], hears: ["stage"])
        XCTAssertEqual(flat(w.last), [
            "-lasa.entity.e1.heard-in.main",
            "lasa.entity.e1.heard-in.stage=true",
            "-lasa.entity.e1.hears.main",
        ])
        // Only the given side changes; identical sets write nothing.
        try await space.setChannels("e1", current: ChannelMemberships(heardIn: ["main"], hears: ["main"]), hears: ["main"])
        XCTAssertEqual(flat(w.last), [])
        // Emptying heard-in is permitted (a moderation act, §6).
        try await space.setChannels("e1", current: ChannelMemberships(heardIn: ["main"], hears: ["main"]), heardIn: [])
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.heard-in.main"])
        await assertMalformedAsync {
            try await space.setChannels("e1", current: ChannelMemberships(heardIn: [], hears: []), heardIn: ["Stage"])
        }
    }

    func testRenderingPartialSetNilClearsRangesEnforced() async throws {
        let w = FakeWriter()
        let space = SpaceControls(w)
        try await space.setRender("e1", [.gain: 1.5, .attenuation: 2.3])
        XCTAssertEqual(flat(w.last), [
            "lasa.entity.e1.render.gain=1.5",
            "lasa.entity.e1.render.attenuation=2.3",
        ])
        try await space.setRender("e1", [.gain: nil])
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.render.gain"])
        try await space.setRender("e1", [.directivity: 0.5, .size: 2])
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.render.size=2", "lasa.entity.e1.render.directivity=0.5"])
        try await space.setRender("e1", [:])
        XCTAssertEqual(flat(w.last), [])
        await assertMalformedAsync { try await space.setRender("e1", [.gain: 4]) }
        await assertMalformedAsync { try await space.setRender("e1", [.directivity: 1.5]) }
        await assertMalformedAsync { try await space.setRender("e1", [.size: -1]) }
        XCTAssertEqual(w.calls.count, 4)
    }

    func testPriorityAndDofDefaultExpressedAsClear() async throws {
        let w = FakeWriter()
        let space = SpaceControls(w)
        try await space.setPriority("e1", true)
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.priority=true"])
        try await space.setPriority("e1", false)
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.priority"])
        try await space.setDof("e1", .turn)
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.dof=3"])
        try await space.setDof("e1", .fixed)
        XCTAssertEqual(flat(w.last), ["lasa.entity.e1.dof=0"])
        try await space.setDof("e1", .free)
        XCTAssertEqual(flat(w.last), ["-lasa.entity.e1.dof"])
        // The TypeScript throws on `4 as 0`; here the enum has no such case.
        XCTAssertNil(Dof(rawValue: 4))
    }

    // MARK: BaseView (read side)

    private func populated() -> DictStore {
        let s = DictStore()
        // e1: a full admission group as the Go server writes it, plus runtime keys.
        s.put("lasa.entity.e1", "\"c1\"")
        s.put("lasa.entity.e1.name", "\"Alice\"")
        s.put("lasa.entity.e1.heard-in.main", "true")
        s.put("lasa.entity.e1.heard-in.stage", "true")
        s.put("lasa.entity.e1.hears.main", "true")
        s.put("lasa.entity.e1.priority", "true")
        s.put("lasa.entity.e1.render.gain", "1.5")
        s.put("lasa.entity.e1.render.attenuation", "2.3")
        s.put("lasa.entity.e1.dof", "3")
        s.put("lasa.entity.e1.attrs.colour", "\"00aaff\"")
        s.put("lasa.entity.e1.attrs.avatar.hat", "true")
        s.put("lasa.entity.e1.signed-attrs.tier", "\"gold\"")
        s.put("lasa.entity.e1.mute.e2", "true")
        s.put("lasa.entity.e1.solo.e3", "true")
        // e2: minimal, head-frame.
        s.put("lasa.entity.e2", "\"c2\"")
        s.put("lasa.entity.e2.name", "\"Bob\"")
        s.put("lasa.entity.e2.heard-in.main", "true")
        s.put("lasa.entity.e2.hears.main", "true")
        s.put("lasa.entity.e2.frame", "\"head\"")
        // e9: keys with NO marker, a departed entity mid-sweep. Must be ignored.
        s.put("lasa.entity.e9.name", "\"Ghost\"")
        s.put("lasa.entity.e9.heard-in.main", "true")
        // Invalid values are ignored by consumers (§2).
        s.put("lasa.entity.e2.render.gain", "loud")
        s.put("lasa.entity.e2.dof", "4")
        // Space keys.
        s.put("lasa.space.entity.muted.e2", "true")
        s.put("lasa.space.client.blocked.c3", "0")
        s.put("lasa.space.client.blocked.c4", "1700000000")
        s.put("lasa.space.role.blocked.noisy", "1700000000")
        s.put("lasa.space.role.blocked.admin", "0")  // stored, no effect; still visible
        s.put("lasa.space.channel.muted.backstage", "true")
        s.put("lasa.space.channel.gain.stage", "1.2")
        s.put("lasa.space.channel.attenuation.whisper", "3")
        return s
    }

    func testListsLiveEntitiesInIdOrderIgnoringMarkerlessSubtreesAndBadValues() {
        let view = baseView(store: populated())
        let all = view.entities()
        XCTAssertEqual(all.map(\.id), ["e1", "e2"])
        var want = EntityView(id: "e1", owner: "c1")
        want.name = "Alice"
        want.attrs = ["colour": "00aaff", "avatar.hat": true]
        want.signedAttrs = ["tier": "gold"]
        want.heardIn = ["main", "stage"]
        want.hears = ["main"]
        want.priority = true
        want.render = RenderParams(gain: 1.5, attenuation: 2.3)
        want.frame = .world
        want.dof = .turn
        want.mutes = ["e2"]
        want.solos = ["e3"]
        XCTAssertEqual(all[0], want)
        let e2 = all[1]
        XCTAssertEqual(e2.frame, .head)
        XCTAssertEqual(e2.render, RenderParams())
        XCTAssertEqual(e2.dof, .free)
        XCTAssertFalse(e2.priority)
        XCTAssertEqual(e2.memberships, ChannelMemberships(heardIn: ["main"], hears: ["main"]))
    }

    func testReadsOneEntityAndNilForAnAbsentMarker() {
        let view = BaseView(populated())
        XCTAssertEqual(view.entity("e1")?.name, "Alice")
        XCTAssertEqual(view.entity("e1"), view.entities()[0])
        XCTAssertNil(view.entity("e9"))
        XCTAssertNil(view.entity("nope"))
        // An id outside the grammar reads as absent rather than throwing.
        XCTAssertNil(view.entity("Nope"))
    }

    func testReadsModerationState() {
        let view = BaseView(populated())
        XCTAssertTrue(view.isEntityMuted("e2"))
        XCTAssertFalse(view.isEntityMuted("e1"))
        XCTAssertEqual(view.clientBlock("c3"), BlockView(id: "c3", until: nil))
        XCTAssertEqual(view.clientBlock("c4"), BlockView(id: "c4", until: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertNil(view.clientBlock("c1"))
        XCTAssertEqual(view.blockedClients().map(\.id), ["c3", "c4"])
        XCTAssertEqual(view.roleBlock("noisy")?.until, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(view.blockedRoles().map(\.id), ["admin", "noisy"])
    }

    func testReadsChannelPolicyAndTheChannelSet() {
        let view = BaseView(populated())
        XCTAssertEqual(view.channel("backstage"), ChannelPolicy(muted: true))
        XCTAssertEqual(view.channel("stage"), ChannelPolicy(muted: false, gain: 1.2))
        XCTAssertEqual(view.channel("whisper"), ChannelPolicy(muted: false, attenuation: 3))
        XCTAssertEqual(view.channel("main"), ChannelPolicy(muted: false))
        XCTAssertEqual(view.channels(), ["backstage", "main", "stage", "whisper"])
    }

    func testReflectsADepartureSweepMarkerClearedEntityGone() {
        let s = populated()
        let view = BaseView(s)
        s.clear("lasa.entity.e1")
        XCTAssertEqual(view.entities().map(\.id), ["e2"])
        XCTAssertNil(view.entity("e1"))
    }
}
