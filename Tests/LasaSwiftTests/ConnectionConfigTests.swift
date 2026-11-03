// The Connection Config JSON (lasa-core.md §4.1, schemata/connection,
// entity and setup.schema.json). Written 2026-11-03 with the port of
// setup.ts's LasaEntity and LasaSetup into Wire/LasaWire.swift. The
// "before" strings were captured from the pre-port Entity (id, name,
// hears, heard-in, string attrs) by running it, so the probe's bytes
// are pinned; the full-entity fixture is written from the schema with
// JSONEncoder's sorted keys.
import XCTest
@testable import LasaSwift

final class ConnectionConfigTests: XCTestCase {
    func text(_ cfg: Lasa.ConnectionConfig) throws -> String { String(decoding: try cfg.json(), as: UTF8.self) }

    // MARK: Before bytes (captured 2026-11-03 before the port)

    func testMinimalEntityEncodesAsBefore() throws {
        XCTAssertEqual(try text(.init(clientID: "c", entities: [Lasa.Entity(id: "a", name: "A")])),
                       #"{"client_id":"c","entities":[{"id":"a","name":"A"}]}"#)
        XCTAssertEqual(try text(.init(clientID: "c", entities: [Lasa.Entity(id: "a", name: "A", hears: ["main"], heardIn: ["main"], attrs: ["k": "v", "a": "b"])])),
                       #"{"client_id":"c","entities":[{"attrs":{"a":"b","k":"v"},"heard-in":["main"],"hears":["main"],"id":"a","name":"A"}]}"#)
        XCTAssertEqual(try text(.init(clientID: "c", entities: [Lasa.Entity(id: "a", name: "A", hears: [], heardIn: nil, attrs: [:])])),
                       #"{"client_id":"c","entities":[{"attrs":{},"hears":[],"id":"a","name":"A"}]}"#)
        XCTAssertEqual(try text(.init(clientID: "c", ticket: "t", entities: [Lasa.Entity(id: "a", name: "A")], lockstep: true)),
                       #"{"client_id":"c","entities":[{"id":"a","name":"A"}],"lockstep":true,"ticket":"t"}"#)
        XCTAssertEqual(try text(.init(clientID: "c")), #"{"client_id":"c"}"#)
        XCTAssertEqual(try text(.init(clientID: "c", ticket: "", entities: [])), #"{"client_id":"c","entities":[],"ticket":""}"#)
    }

    func testExistingInitialiserShapesStillCompile() throws {
        // The probe passes a [String: String] variable and a nil.
        var a: [String: String] = [:]
        a["pad-000"] = "x"
        let padded = Lasa.Entity(id: "e-pad", name: "pad", hears: nil, attrs: a)
        XCTAssertEqual(padded.attrs, ["pad-000": .string("x")])
        let listener = Lasa.Entity(id: "e", name: "probe-swift", hears: ["main"], attrs: nil)
        XCTAssertNil(listener.attrs)
        let mic = Lasa.Entity(id: "e-mic", name: "s4 mic", heardIn: ["mic"])
        XCTAssertEqual(mic.heardIn, ["mic"])
        XCTAssertEqual(try text(.init(clientID: "c1", entities: [Lasa.Entity(id: "e1", name: "probe", hears: ["main"])])),
                       #"{"client_id":"c1","entities":[{"hears":["main"],"id":"e1","name":"probe"}]}"#)
        // The setup parameter is the same bytes under key 0x1A5A1.
        let p = try Lasa.ConnectionConfig(clientID: "c1", entities: [Lasa.Entity(id: "e1", name: "probe")]).setupParam()
        XCTAssertEqual(p.type, Lasa.setupParamConnectionConfig)
        if case .bytes(let b) = p.value { XCTAssertEqual(String(decoding: b, as: UTF8.self), #"{"client_id":"c1","entities":[{"id":"e1","name":"probe"}]}"#) } else { XCTFail("bytes") }
    }

    // MARK: Every schema field

    static let full = Lasa.Entity(
        id: "e1", name: "Paul",
        hears: ["main"], heardIn: ["main", "stage"],
        attrs: ["colour": .string("00aaff"), "rank": .number(3), "nested": .object(["on": .bool(true), "size": .number(2.5)])],
        priority: true, frame: .head, dof: .six, quality: .resilient, redundancy: 4,
        initialPose: .init(position: .init(x: 1, y: 2.5, z: -3), attitude: .init(yaw: 1.5, pitch: 0.25, roll: -0.5)),
        render: .init(gain: 1.5, attenuation: 2, size: 0.1, directivity: 0.5))

    static let fullJSON = #"{"attrs":{"colour":"00aaff","nested":{"on":true,"size":2.5},"rank":3},"dof":6,"frame":"head","heard-in":["main","stage"],"hears":["main"],"id":"e1","initial-pose":{"attitude":{"pitch":0.25,"roll":-0.5,"yaw":1.5},"position":{"x":1,"y":2.5,"z":-3}},"name":"Paul","priority":true,"quality":1,"redundancy":4,"render":{"attenuation":2,"directivity":0.5,"gain":1.5,"size":0.1}}"#

    func testFullEntityEncodesWithTheSchemaKeys() throws {
        XCTAssertEqual(try text(.init(clientID: "c", entities: [Self.full])), #"{"client_id":"c","entities":[\#(Self.fullJSON)]}"#)
        // Every key the schema names, and no other.
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.fullJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["id", "name", "priority", "heard-in", "hears", "attrs", "frame", "dof", "quality", "redundancy", "initial-pose", "render"])
        let pose = try XCTUnwrap(obj["initial-pose"] as? [String: Any])
        XCTAssertEqual(Set(pose.keys), ["position", "attitude"])
        XCTAssertEqual(Set(try XCTUnwrap(pose["position"] as? [String: Any]).keys), ["x", "y", "z"])
        XCTAssertEqual(Set(try XCTUnwrap(pose["attitude"] as? [String: Any]).keys), ["yaw", "pitch", "roll"])
        XCTAssertEqual(Set(try XCTUnwrap(obj["render"] as? [String: Any]).keys), ["gain", "attenuation", "size", "directivity"])
    }

    func testFullEntityRoundTripsThroughDecoding() throws {
        let back = try JSONDecoder().decode(Lasa.Entity.self, from: Data(Self.fullJSON.utf8))
        XCTAssertEqual(back, Self.full)
        // Absent optionals decode as nil, not defaults.
        let min = try JSONDecoder().decode(Lasa.Entity.self, from: Data(#"{"id":"a","name":"A"}"#.utf8))
        XCTAssertEqual(min, Lasa.Entity(id: "a", name: "A"))
        // A value outside the closed sets is refused.
        XCTAssertThrowsError(try JSONDecoder().decode(Lasa.Entity.self, from: Data(#"{"id":"a","name":"A","dof":2}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Lasa.Entity.self, from: Data(#"{"id":"a","name":"A","frame":"body"}"#.utf8)))
    }

    func testAttrValuesCoverTheSchemaShapes() throws {
        let e = Lasa.Entity(id: "a", name: "A", attrs: ["b": .bool(false), "s": .string("x/y"), "n": .number(-1.25), "o": .object([:])])
        XCTAssertEqual(try text(.init(clientID: "c", entities: [e])),
                       #"{"client_id":"c","entities":[{"attrs":{"b":false,"n":-1.25,"o":{},"s":"x/y"},"id":"a","name":"A"}]}"#)
        let attrs = try JSONDecoder().decode([String: Lasa.AttrValue].self, from: Data(#"{"b":true,"n":7,"o":{"d":"e"},"s":"t"}"#.utf8))
        XCTAssertEqual(attrs, ["b": .bool(true), "n": .number(7), "o": .object(["d": .string("e")]), "s": .string("t")])
        XCTAssertThrowsError(try JSONDecoder().decode([String: Lasa.AttrValue].self, from: Data(#"{"a":[1]}"#.utf8)), "arrays are not attr values")
        XCTAssertThrowsError(try JSONDecoder().decode([String: Lasa.AttrValue].self, from: Data(#"{"a":null}"#.utf8)))
    }

    // MARK: Setups

    func testSetupsEncodeWithTheSchemaKeys() throws {
        let cfg = Lasa.ConnectionConfig(
            clientID: "c", ticket: "t",
            setups: [Lasa.Setup(id: "a"),
                     Lasa.Setup(id: "b", attrs: ["seat": .number(12)], initialPose: .init(position: .init(x: 0, y: 1, z: 2)))])
        XCTAssertEqual(try text(cfg),
                       #"{"client_id":"c","setups":[{"id":"a"},{"attrs":{"seat":12},"id":"b","initial-pose":{"position":{"x":0,"y":1,"z":2}}}],"ticket":"t"}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try cfg.json())) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["client_id", "setups", "ticket"])
        let back = try JSONDecoder().decode([Lasa.Setup].self, from: Data(#"[{"id":"b","attrs":{"seat":12},"initial-pose":{"position":{"x":0,"y":1,"z":2}}}]"#.utf8))
        XCTAssertEqual(back, Array(cfg.setups![1...]))
    }

    func testEntitiesAndSetupsTogether() throws {
        let cfg = Lasa.ConnectionConfig(clientID: "c", ticket: "t", entities: [Lasa.Entity(id: "x", name: "X")], setups: [Lasa.Setup(id: "a")])
        XCTAssertEqual(try text(cfg), #"{"client_id":"c","entities":[{"id":"x","name":"X"}],"setups":[{"id":"a"}],"ticket":"t"}"#)
    }
}
