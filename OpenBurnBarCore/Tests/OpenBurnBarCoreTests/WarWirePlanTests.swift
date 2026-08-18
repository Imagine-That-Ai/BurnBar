import XCTest
@testable import OpenBurnBarKernel

/// Who the Wire dials, who it hangs up on, and who it leaves alone.
final class WarWirePlanTests: XCTestCase {

    private let local = "mac-local"

    private func peer(
        _ id: String,
        node: String? = "node-\(UUID().uuidString)",
        online: Bool = true
    ) -> WarWirePeer {
        WarWirePeer(bodyID: id, displayName: id.uppercased(), irohNodeID: node, isOnline: online)
    }

    private func grant(_ other: String, state: WarWireGrant.State = .active) -> WarWireGrant {
        WarWireGrant(bodyIDA: local, bodyIDB: other, state: state)
    }

    private func plan(
        peers: [WarWirePeer],
        tier: CloudTier = .pro,
        killSwitch: Bool = false,
        grants: [WarWireGrant] = [],
        linked: Set<String> = []
    ) -> WarWirePlan {
        WarWirePlanner.plan(
            peers: peers,
            localBodyID: local,
            tier: tier,
            killSwitchEngaged: killSwitch,
            grants: grants,
            linkedBodyIDs: linked
        )
    }

    // MARK: - Dialing

    func test_anAllowedOnlinePeerWithAnEndpointIsDialled() throws {
        let result = plan(peers: [peer("mac-b", node: "node-b")], grants: [grant("mac-b")])
        XCTAssertEqual(result.dials.map(\.bodyID), ["mac-b"])
        XCTAssertEqual(try XCTUnwrap(result.dials.first).nodeID, "node-b")
        XCTAssertTrue(result.drops.isEmpty)
    }

    func test_everyPeerLandsInExactlyOneBucket() {
        let result = plan(
            peers: [peer("mac-b"), peer("mac-c", online: false), peer("mac-d")],
            grants: [grant("mac-b"), grant("mac-c")]
        )
        let accounted = result.dials.map(\.bodyID) + result.drops.map(\.bodyID) + result.skips.map(\.bodyID)
        XCTAssertEqual(Set(accounted).count, 3, "no machine may vanish without a reason")
        XCTAssertEqual(accounted.count, 3, "and none may be reported twice")
    }

    func test_theOrderIsDeterministic() {
        let forward = plan(peers: [peer("mac-b"), peer("mac-c")], grants: [grant("mac-b"), grant("mac-c")])
        let reversed = plan(peers: [peer("mac-c"), peer("mac-b")], grants: [grant("mac-c"), grant("mac-b")])
        XCTAssertEqual(forward.dials.map(\.bodyID), reversed.dials.map(\.bodyID))
    }

    // MARK: - Fail closed

    func test_noGrantMeansNoDial() {
        let result = plan(peers: [peer("mac-b")])
        XCTAssertTrue(result.dials.isEmpty)
        XCTAssertEqual(result.skips.first?.reason, .denied(.noGrant))
    }

    func test_theKillSwitchStopsEveryDial() {
        let result = plan(
            peers: [peer("mac-b"), peer("mac-c")],
            killSwitch: true,
            grants: [grant("mac-b"), grant("mac-c")]
        )
        XCTAssertTrue(result.dials.isEmpty)
        XCTAssertEqual(result.skips.map(\.reason), [.denied(.killSwitch), .denied(.killSwitch)])
    }

    func test_aFreeAccountNeverOpensTheWire() {
        let result = plan(peers: [peer("mac-b")], tier: .cloud, grants: [grant("mac-b")])
        XCTAssertTrue(result.dials.isEmpty)
        XCTAssertEqual(result.skips.first?.reason, .denied(.entitlement))
    }

    func test_aRevokedGrantRefusesTheDial() {
        let result = plan(peers: [peer("mac-b")], grants: [grant("mac-b", state: .revoked)])
        XCTAssertEqual(result.skips.first?.reason, .denied(.grantRevoked))
    }

    func test_theLocalMachineIsNeverDialled() {
        let result = plan(peers: [peer(local)], grants: [grant(local)])
        XCTAssertTrue(result.dials.isEmpty)
        XCTAssertEqual(result.skips.first?.reason, .denied(.selfDial))
    }

    // MARK: - Revocation reaches open lanes

    /// Revoking consent has to close a lane that is already up. Otherwise
    /// "revoke" quietly means "do not dial again" and the link outlives the
    /// permission that justified it.
    func test_revokingAGrantDropsAnOpenLink() {
        let result = plan(
            peers: [peer("mac-b")],
            grants: [grant("mac-b", state: .revoked)],
            linked: ["mac-b"]
        )
        XCTAssertEqual(result.drops, [WarWireDrop(bodyID: "mac-b", reason: .grantRevoked)])
        XCTAssertTrue(result.dials.isEmpty)
    }

    func test_theKillSwitchDropsOpenLinksToo() {
        let result = plan(
            peers: [peer("mac-b")],
            killSwitch: true,
            grants: [grant("mac-b")],
            linked: ["mac-b"]
        )
        XCTAssertEqual(result.drops.first?.reason, .killSwitch)
    }

    func test_aHealthyLinkIsLeftAloneRatherThanRedialled() {
        let result = plan(peers: [peer("mac-b")], grants: [grant("mac-b")], linked: ["mac-b"])
        XCTAssertTrue(result.dials.isEmpty, "an open lane must not be dialled twice")
        XCTAssertTrue(result.drops.isEmpty)
        XCTAssertEqual(result.skips.first?.reason, .alreadyLinked)
    }

    // MARK: - Reachability is not permission

    /// A peer that is allowed but publishes no endpoint is unreachable, not
    /// refused. Reporting it as a consent problem would send the user hunting
    /// for a grant they already have.
    func test_anAllowedPeerWithNoEndpointIsUnreachableNotDenied() {
        let result = plan(peers: [peer("mac-b", node: nil)], grants: [grant("mac-b")])
        XCTAssertEqual(result.skips.first?.reason, .noEndpoint)
    }

    func test_aBlankEndpointCountsAsNoEndpoint() {
        let result = plan(peers: [peer("mac-b", node: "   ")], grants: [grant("mac-b")])
        XCTAssertEqual(result.skips.first?.reason, .noEndpoint)
    }

    func test_anOfflinePeerIsNotDialled() {
        let result = plan(peers: [peer("mac-b", online: false)], grants: [grant("mac-b")])
        XCTAssertEqual(result.skips.first?.reason, .offline)
    }

    /// Permission is evaluated before reachability, so a peer that is both
    /// offline and ungranted reports the refusal rather than implying it would
    /// connect if only it were awake.
    func test_denialOutranksOfflineInTheExplanation() {
        let result = plan(peers: [peer("mac-b", online: false)])
        XCTAssertEqual(result.skips.first?.reason, .denied(.noGrant))
    }

    func test_anEmptyFleetPlansNothing() {
        XCTAssertTrue(plan(peers: []).isEmpty)
    }
}
