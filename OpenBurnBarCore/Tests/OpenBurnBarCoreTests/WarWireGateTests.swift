import XCTest
@testable import OpenBurnBarKernel

/// The Wire is fail-closed by construction: every unknown must land on a deny
/// with a truthful reason, and the allow path must require all four of
/// kill-switch-clear, entitled, identified, and mutually granted.
final class WarWireGateTests: XCTestCase {

    private let macA = "relay-host-aaaa-1111"
    private let macB = "relay-host-bbbb-2222"

    private func activeGrant(_ first: String, _ second: String) -> WarWireGrant {
        WarWireGrant(bodyIDA: first, bodyIDB: second, state: .active)
    }

    private func evaluate(
        local: String? = nil,
        remote: String? = nil,
        tier: CloudTier = .pro,
        killSwitchEngaged: Bool = false,
        grant: WarWireGrant?? = nil
    ) -> WarWireDecision {
        WarWireGate.evaluate(
            localBodyID: local ?? macA,
            remoteBodyID: remote ?? macB,
            tier: tier,
            killSwitchEngaged: killSwitchEngaged,
            grant: grant ?? activeGrant(macA, macB)
        )
    }

    // MARK: - Allow

    func test_allowsProWithActiveGrant() {
        XCTAssertEqual(evaluate(), .allow)
    }

    func test_allowsUltraBecauseHigherTiersSubsume() {
        XCTAssertEqual(evaluate(tier: .ultra), .allow)
    }

    func test_allowsGrantStoredInReverseOrder() {
        XCTAssertEqual(evaluate(grant: activeGrant(macB, macA)), .allow)
    }

    // MARK: - Global stop wins

    func test_killSwitchDeniesEvenWhenFullyEntitledAndGranted() {
        XCTAssertEqual(evaluate(killSwitchEngaged: true), .deny(.killSwitch))
    }

    /// The kill switch is the outermost check: an unentitled, ungranted,
    /// self-dialing peer under an engaged kill switch still reports the switch,
    /// because that is the operator-actionable truth.
    func test_killSwitchOutranksEveryOtherDenial() {
        let decision = WarWireGate.evaluate(
            localBodyID: macA,
            remoteBodyID: macA,
            tier: .none,
            killSwitchEngaged: true,
            grant: nil
        )
        XCTAssertEqual(decision, .deny(.killSwitch))
    }

    // MARK: - Entitlement

    func test_deniesFreeTier() {
        XCTAssertEqual(evaluate(tier: .none), .deny(.entitlement))
    }

    func test_deniesCloudTierBecauseTheWireIsProAndAbove() {
        XCTAssertEqual(evaluate(tier: .cloud), .deny(.entitlement))
    }

    func test_requiredTierIsPro() {
        XCTAssertEqual(WarWireGate.requiredTier, .pro)
    }

    // MARK: - Identity

    func test_deniesEmptyLocalBody() {
        XCTAssertEqual(evaluate(local: ""), .deny(.unidentified))
    }

    func test_deniesWhitespaceOnlyRemoteBody() {
        XCTAssertEqual(evaluate(remote: "   "), .deny(.unidentified))
    }

    func test_deniesSelfDial() {
        XCTAssertEqual(evaluate(remote: macA), .deny(.selfDial))
    }

    func test_deniesSelfDialAcrossSurroundingWhitespace() {
        XCTAssertEqual(evaluate(remote: "  \(macA) "), .deny(.selfDial))
    }

    // MARK: - Consent

    func test_deniesWhenNoGrantExists() {
        XCTAssertEqual(evaluate(grant: .some(nil)), .deny(.noGrant))
    }

    func test_deniesRevokedGrant() {
        let revoked = WarWireGrant(bodyIDA: macA, bodyIDB: macB, state: .revoked)
        XCTAssertEqual(evaluate(grant: revoked), .deny(.grantRevoked))
    }

    func test_deniesGrantForADifferentPair() {
        let other = activeGrant(macA, "relay-host-cccc-3333")
        XCTAssertEqual(evaluate(grant: other), .deny(.grantMismatch))
    }

    /// A grant that names the right pair but is revoked must not be rescued by
    /// the mismatch check running first.
    func test_mismatchIsCheckedBeforeRevocation() {
        let revokedOtherPair = WarWireGrant(
            bodyIDA: "relay-host-cccc-3333",
            bodyIDB: "relay-host-dddd-4444",
            state: .revoked
        )
        XCTAssertEqual(evaluate(grant: revokedOtherPair), .deny(.grantMismatch))
    }

    // MARK: - Pair id

    func test_pairIDIsOrderIndependent() {
        XCTAssertEqual(
            WarWireGrant.pairID(macA, macB),
            WarWireGrant.pairID(macB, macA)
        )
    }

    func test_pairIDSortsLexicographicallyAndJoinsWithDoubleUnderscore() {
        XCTAssertEqual(WarWireGrant.pairID(macB, macA), "\(macA)__\(macB)")
    }

    func test_grantPairIDMatchesStaticDerivation() {
        XCTAssertEqual(activeGrant(macB, macA).pairID, WarWireGrant.pairID(macA, macB))
    }

    func test_coversIsSymmetric() {
        let grant = activeGrant(macA, macB)
        XCTAssertTrue(grant.covers(macA, macB))
        XCTAssertTrue(grant.covers(macB, macA))
        XCTAssertFalse(grant.covers(macA, "relay-host-cccc-3333"))
    }

    // MARK: - Decision helpers

    func test_decisionHelpers() {
        XCTAssertTrue(WarWireDecision.allow.isAllowed)
        XCTAssertNil(WarWireDecision.allow.denialReason)
        XCTAssertFalse(WarWireDecision.deny(.noGrant).isAllowed)
        XCTAssertEqual(WarWireDecision.deny(.noGrant).denialReason, .noGrant)
    }

    /// The denial vocabulary is a wire contract (`war.denied` carries it), so a
    /// silent rename would break cross-version reporting.
    func test_denialReasonWireValuesAreStable() {
        XCTAssertEqual(
            Set(WarWireDenialReason.allCases.map(\.rawValue)),
            ["kill_switch", "entitlement", "no_grant", "grant_revoked", "grant_mismatch", "self_dial", "unidentified"]
        )
    }
}
