import XCTest
@testable import OpenBurnBarKernel

/// Face B's contract: the room's answer to "can I move Hermes there?" is the
/// Wire's answer, never a second opinion.
final class HermesRoomTests: XCTestCase {

    private func body(
        _ id: String,
        name: String? = nil,
        local: Bool = false,
        online: Bool = true
    ) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: name ?? id.uppercased(),
            isLocal: local,
            isOnline: online,
            hermesGatewayReachable: true,
            wireReachable: true,
            capabilities: [],
            activeRunCount: 0
        )
    }

    private func state(
        _ bodies: [FleetBodySnapshot],
        active: String? = nil,
        tier: CloudTier = .pro,
        killSwitch: Bool = false,
        grants: [WarWireGrant] = []
    ) -> HermesRoomState {
        HermesRoom.state(
            fleet: FleetSnapshot(bodies: bodies),
            localBodyID: "mac-a",
            activeBodyID: active,
            tier: tier,
            killSwitchEngaged: killSwitch,
            grants: Dictionary(uniqueKeysWithValues: grants.map { ($0.pairID, $0) })
        )
    }

    private func grant(_ first: String, _ second: String, _ grantState: WarWireGrant.State = .active) -> WarWireGrant {
        WarWireGrant(bodyIDA: first, bodyIDB: second, state: grantState)
    }

    // MARK: - Who is serving

    /// No explicit selection means Hermes is served here, which is the default
    /// and the pre-War Room behaviour.
    func test_noSelectionMeansTheLocalMachineIsServing() throws {
        let room = state([body("mac-a", local: true), body("mac-b")])
        let active = try XCTUnwrap(room.activeRow)
        XCTAssertEqual(active.body.bodyID, "mac-a")
    }

    func test_anExplicitSelectionIsTheActiveRow() throws {
        let room = state([body("mac-a", local: true), body("mac-b")], active: "mac-b", grants: [grant("mac-a", "mac-b")])
        XCTAssertEqual(try XCTUnwrap(room.activeRow).body.bodyID, "mac-b")
        XCTAssertFalse(try XCTUnwrap(room.rows.first).isActive)
    }

    /// A selection pointing at a machine that has left the fleet leaves the
    /// room with no active row rather than silently reassigning one.
    func test_aSelectionOutsideTheFleetLeavesNoActiveRow() {
        let room = state([body("mac-a", local: true)], active: "mac-gone")
        XCTAssertNil(room.activeRow)
    }

    func test_theActiveMachineIsNotOfferedAsASwapTarget() {
        let room = state([body("mac-a", local: true)])
        XCTAssertFalse(room.rows[0].isSelectable, "already serving")
    }

    // MARK: - Reusing the Wire's admission decision

    func test_theLocalMachineIsAlwaysAvailable() {
        // No Wire and no consent needed to serve Hermes here; it is already here.
        let room = state([body("mac-a", local: true)], active: "mac-b", tier: .none, killSwitch: true)
        XCTAssertNil(room.rows[0].blockedReason)
        XCTAssertTrue(room.rows[0].isSelectable)
    }

    func test_aGrantedRemoteMachineIsSelectable() {
        let room = state([body("mac-a", local: true), body("mac-b")], grants: [grant("mac-a", "mac-b")])
        let remote = room.rows[1]
        XCTAssertNil(remote.blockedReason)
        XCTAssertTrue(remote.isSelectable)
        XCTAssertEqual(remote.statusLine, "Ready over the Wire")
    }

    func test_anUngrantedRemoteMachineIsBlocked() {
        let room = state([body("mac-a", local: true), body("mac-b")])
        XCTAssertEqual(room.rows[1].blockedReason, .noGrant)
        XCTAssertFalse(room.rows[1].isSelectable)
    }

    func test_theKillSwitchBlocksEveryRemoteMachine() {
        let room = state(
            [body("mac-a", local: true), body("mac-b")],
            killSwitch: true,
            grants: [grant("mac-a", "mac-b")]
        )
        XCTAssertNil(room.rows[0].blockedReason, "the local machine is unaffected")
        XCTAssertEqual(room.rows[1].blockedReason, .killSwitch)
    }

    func test_aLowerTierBlocksEveryRemoteMachine() {
        let room = state(
            [body("mac-a", local: true), body("mac-b")],
            tier: .cloud,
            grants: [grant("mac-a", "mac-b")]
        )
        XCTAssertEqual(room.rows[1].blockedReason, .entitlement)
    }

    func test_aRevokedGrantBlocksTheMachine() {
        let room = state(
            [body("mac-a", local: true), body("mac-b")],
            grants: [grant("mac-a", "mac-b", .revoked)]
        )
        XCTAssertEqual(room.rows[1].blockedReason, .grantRevoked)
    }

    // MARK: - Status lines

    /// The room never shows a bare "unavailable"; every denial reason has a
    /// sentence a person can act on.
    func test_everyDenialReasonRendersAnExplanation() {
        for reason in WarWireDenialReason.allCases {
            let row = HermesRoomRow(body: body("mac-b"), isActive: false, blockedReason: reason)
            XCTAssertFalse(row.statusLine.isEmpty, "\(reason) needs a sentence")
            XCTAssertFalse(row.statusLine.lowercased().contains("unavailable"), "\(reason) says why")
        }
    }

    func test_theLocalMachineReadsAsHere() {
        let room = state([body("mac-a", local: true)])
        XCTAssertEqual(room.rows[0].statusLine, "Serving Hermes here")
        let idle = state([body("mac-a", local: true), body("mac-b")], active: "mac-b", grants: [grant("mac-a", "mac-b")])
        XCTAssertEqual(idle.rows[0].statusLine, "Ready to serve here")
    }

    func test_theActiveRemoteMachineSaysSoOverTheWire() {
        let room = state([body("mac-a", local: true), body("mac-b")], active: "mac-b", grants: [grant("mac-a", "mac-b")])
        XCTAssertEqual(room.rows[1].statusLine, "Serving Hermes over the Wire")
    }

    // MARK: - Ordering

    /// Read top-down by someone deciding where to put Hermes, so the machines
    /// they can actually pick belong at the top.
    func test_thisMacFirstThenReachableThenByName() {
        let room = state([
            body("mac-z", name: "Zulu"),
            body("mac-off", name: "Attic", online: false),
            body("mac-b", name: "Bravo"),
            body("mac-a", name: "Alpha", local: true)
        ])
        XCTAssertEqual(room.rows.map(\.body.bodyID), ["mac-a", "mac-b", "mac-z", "mac-off"])
    }

    func test_offlineMachinesStayInTheList() {
        // A Mac you cannot currently reach is exactly what you came here to find out.
        let room = state([body("mac-a", local: true), body("mac-off", online: false)])
        XCTAssertEqual(room.rows.count, 2)
        XCTAssertFalse(room.rows[1].body.isOnline)
    }

    /// `activeRow` is derived, so it cannot fall out of step with `rows`.
    func test_activeRowTracksRowsAfterMutation() throws {
        var room = state([body("mac-a", local: true), body("mac-b")], grants: [grant("mac-a", "mac-b")])
        XCTAssertEqual(try XCTUnwrap(room.activeRow).body.bodyID, "mac-a")
        room.rows = room.rows.map {
            HermesRoomRow(body: $0.body, isActive: $0.body.bodyID == "mac-b", blockedReason: $0.blockedReason)
        }
        XCTAssertEqual(try XCTUnwrap(room.activeRow).body.bodyID, "mac-b")
    }

    func test_anEmptyFleetIsAnEmptyRoom() {
        let room = state([])
        XCTAssertTrue(room.isEmpty)
        XCTAssertNil(room.activeRow)
    }
}
