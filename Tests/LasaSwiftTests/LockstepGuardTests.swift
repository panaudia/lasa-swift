// The lockstep guard: port of lasa/typescript/tests/lockstep-guard.test.ts
// on 2026-11-03. The client carries the declaration but cannot honour
// it for more than one entity, so connect refuses that shape before
// dialling.
import XCTest
@testable import LasaSwift

final class LockstepGuardTests: XCTestCase {
    let one = [Lasa.Entity(id: "a", name: "A")]
    let two = [Lasa.Entity(id: "a", name: "A"), Lasa.Entity(id: "b", name: "B")]

    func testPassesWithoutTheFlagAndWithTheFlagOnZeroOrOneEntity() {
        XCTAssertNoThrow(try assertLockstepSupported(Lasa.ConnectionConfig(clientID: "c", entities: two)))
        XCTAssertNoThrow(try assertLockstepSupported(Lasa.ConnectionConfig(clientID: "c", entities: two, lockstep: false)))
        XCTAssertNoThrow(try assertLockstepSupported(Lasa.ConnectionConfig(clientID: "c", entities: one, lockstep: true)))
        XCTAssertNoThrow(try assertLockstepSupported(Lasa.ConnectionConfig(clientID: "c", entities: [], lockstep: true)))
        XCTAssertNoThrow(try assertLockstepSupported(Lasa.ConnectionConfig(clientID: "c", lockstep: true)))
        XCTAssertNoThrow(try Lasa.ConnectionConfig(clientID: "c", ticket: "t", setups: [Lasa.Setup(id: "a")], lockstep: true).assertLockstepSupported())
    }

    func testRefusesTheFlagWithMoreThanOneEntityByEntitiesOrSetups() {
        XCTAssertThrowsError(try assertLockstepSupported(Lasa.ConnectionConfig(clientID: "c", entities: two, lockstep: true))) { e in
            XCTAssertEqual(e as? LockstepUnsupported, LockstepUnsupported(entityCount: 2))
            XCTAssertTrue("\(e)".hasPrefix("lockstep with 2 entities"), "\(e)")
        }
        let setups = Lasa.ConnectionConfig(clientID: "c", ticket: "t", setups: [Lasa.Setup(id: "a"), Lasa.Setup(id: "b")], lockstep: true)
        XCTAssertThrowsError(try setups.assertLockstepSupported()) { e in
            XCTAssertTrue("\(e)".contains("not supported"), "\(e)")
        }
        // One of each counts as two.
        let mixed = Lasa.ConnectionConfig(clientID: "c", ticket: "t", entities: one, setups: [Lasa.Setup(id: "b")], lockstep: true)
        XCTAssertThrowsError(try mixed.assertLockstepSupported()) { e in
            XCTAssertEqual((e as? LockstepUnsupported)?.entityCount, 2)
        }
    }

    func testSerialisesTheFlagOnlyWhenSet() throws {
        let on = try Lasa.ConnectionConfig(clientID: "c", entities: one, lockstep: true).json()
        let off = try Lasa.ConnectionConfig(clientID: "c", entities: one).json()
        let onObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(on)) as? [String: Any])
        let offObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(off)) as? [String: Any])
        XCTAssertEqual(onObj["lockstep"] as? Bool, true)
        XCTAssertNil(offObj["lockstep"])
    }
}
