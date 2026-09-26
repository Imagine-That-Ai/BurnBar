#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
@testable import OpenBurnBar

/// R-L5 (Computer Use safety): the Mac-side authoritative `setTrustMode` is
/// downgrade-only. A running session may lower trust (trusted -> step ->
/// manual) but must never elevate mid-session, because
/// `ComputerUseCapabilityGate` treats `.trusted` as auto-allow for scoped
/// actions — so a silent mid-session elevation would be a privilege
/// escalation. Mirrors the phone-path guard in
/// `AgentWatchReceiver.downgradeTrustMode` ('guard mode <= liveTrustMode').
@MainActor
final class ComputerUseSetTrustModeDowngradeOnlyTests: XCTestCase {

    private func makeCoordinator() -> ComputerUseSessionCoordinator {
        ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-trust-clamp",
                macHostNodeId: "mac-trust-clamp",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsSystem: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-06-30"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-trust-clamp-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "test",
                    respondedAt: Date()
                )
            }
        )
    }

    private func startSession(
        _ coordinator: ComputerUseSessionCoordinator,
        trustMode: ComputerUseTrustMode
    ) async throws {
        _ = try await coordinator.startSession(
            request: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: trustMode.rawValue,
                clientID: BurnBarClientID(rawValue: "agent-session")
            )
        )
    }

    func testCoordinatorOwnsDistinctCollaboratorPipelines() {
        let coordinator = makeCoordinator()
        XCTAssertNotNil(coordinator.inputPipeline)
        XCTAssertNotNil(coordinator.approvalPipeline)
        XCTAssertNotNil(coordinator.auditPipeline)
        XCTAssertNotEqual(
            ObjectIdentifier(coordinator.inputPipeline),
            ObjectIdentifier(coordinator.approvalPipeline)
        )
        XCTAssertNotEqual(
            ObjectIdentifier(coordinator.approvalPipeline),
            ObjectIdentifier(coordinator.auditPipeline)
        )
        XCTAssertNotEqual(
            ObjectIdentifier(coordinator.inputPipeline),
            ObjectIdentifier(coordinator.auditPipeline)
        )
    }

    func testSetTrustModeRejectsElevation() async throws {
        let coordinator = makeCoordinator()
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual)

        // Elevation attempts must be refused and leave live trust unchanged.
        coordinator.setTrustMode(.trusted)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual, "manual -> trusted must be rejected")

        coordinator.setTrustMode(.step)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual, "manual -> step must be rejected")
    }

    func testSetTrustModeAcceptsDowngrade() async throws {
        let coordinator = makeCoordinator()
        try await startSession(coordinator, trustMode: .trusted)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .trusted)

        // The full downgrade ladder is accepted: trusted -> step -> manual.
        coordinator.setTrustMode(.step)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .step, "trusted -> step must be accepted")

        coordinator.setTrustMode(.manual)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual, "step -> manual must be accepted")
    }

    func testSetTrustModeAcceptsEqualAndRejectsReElevation() async throws {
        let coordinator = makeCoordinator()
        try await startSession(coordinator, trustMode: .step)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .step)

        // Equal trust is idempotent (mode <= liveTrustMode holds on equality).
        coordinator.setTrustMode(.step)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .step)

        // Once downgraded, trust cannot be raised back up.
        coordinator.setTrustMode(.manual)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual)

        coordinator.setTrustMode(.trusted)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual, "manual -> trusted must stay rejected after downgrade")
    }

    func testSetTrustModeAllowsElevationWhenNoSessionActive() async throws {
        let coordinator = makeCoordinator()
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual)

        // Ending the session clears the live guard but leaves `state`
        // populated so it can seed the next session's trust. With no live
        // session the downgrade-only clamp must NOT fire: the Mac UI is the
        // legitimate elevation surface and must be able to raise trust for a
        // fresh session (Decision 2: trust is chosen per session, never sticky).
        await coordinator.endSession(reason: .userHalt)
        XCTAssertNotNil(coordinator.state?.endedAt, "the session must be ended")

        coordinator.setTrustMode(.trusted)
        XCTAssertEqual(
            coordinator.state?.liveTrustMode, .trusted,
            "with no active session, trust selection for the next session may elevate"
        )
    }

    func testStartSessionStartsNonNilWatchHUD() async throws {
        let coordinator = makeCoordinator()
        let hud = FakeWatchHUDSession()
        coordinator.watchHUDFactory = { hud }
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(hud.startCount, 1)
        XCTAssertIdentical(coordinator.watchHUDSession, hud)
    }

    func testPanicHaltStopsNonNilWatchHUD() async throws {
        let coordinator = makeCoordinator()
        let hud = FakeWatchHUDSession()
        coordinator.watchHUDFactory = { hud }
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(hud.startCount, 1)
        await coordinator.panicHalt(source: .phoneGesture)
        XCTAssertNil(coordinator.watchHUDSession)
        XCTAssertNil(coordinator.activeSessionId)
        XCTAssertEqual(hud.stopCount, 1, "panic teardown must stop the live HUD session")
    }

    func testStartSessionHoldsComputerUseKeepAwake() async throws {
        let coordinator = makeCoordinator()
        let keepAwake = FakeKeepAwakeController()
        coordinator.keepAwakeController = keepAwake
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(keepAwake.holds, [.computerUse], "a live session must hold idle-sleep")
        XCTAssertTrue(keepAwake.releases.isEmpty)
    }

    func testEndSessionReleasesComputerUseKeepAwake() async throws {
        let coordinator = makeCoordinator()
        let keepAwake = FakeKeepAwakeController()
        coordinator.keepAwakeController = keepAwake
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(keepAwake.holds, [.computerUse])

        // endSessionNow releases on a detached task; the expectation (not a
        // sleep) is what waits for it.
        let released = expectation(description: "keep-awake released on endSession")
        keepAwake.onRelease = { released.fulfill() }
        await coordinator.endSession(reason: .userHalt)
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(keepAwake.releases, [.computerUse])
    }

    func testPanicHaltReleasesComputerUseKeepAwake() async throws {
        let coordinator = makeCoordinator()
        let keepAwake = FakeKeepAwakeController()
        coordinator.keepAwakeController = keepAwake
        try await startSession(coordinator, trustMode: .manual)
        await coordinator.panicHalt(source: .phoneGesture)
        XCTAssertEqual(
            keepAwake.releases, [.computerUse],
            "panic teardown must release the hold or the Mac stays awake after halt"
        )
    }

    func testBudgetHardCapReleasesComputerUseKeepAwake() async throws {
        let coordinator = makeCoordinator()
        let keepAwake = FakeKeepAwakeController()
        coordinator.keepAwakeController = keepAwake
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(keepAwake.holds, [.computerUse])

        let released = expectation(description: "keep-awake released on budget hard cap")
        keepAwake.onRelease = { released.fulfill() }
        coordinator.haltForBudgetHardCap()
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(keepAwake.releases, [.computerUse])
    }

    func testRememberKeepAwakeToggleKey_cachesEd25519KeyOnly() throws {
        let coordinator = makeCoordinator()
        let keepAwake = FakeKeepAwakeController()
        coordinator.keepAwakeController = keepAwake

        let edBytes = Data(repeating: 0x11, count: 32)
        let edKey = try PhoneControlVerifyingKey(kind: .ed25519, publicKeyRepresentation: edBytes)
        coordinator.rememberKeepAwakeToggleKey(nodeId: "node-ed", key: edKey)
        XCTAssertEqual(keepAwake.rememberedKeys["node-ed"], edBytes)

        let p256Bytes = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let p256Key = try PhoneControlVerifyingKey(kind: .secureEnclaveP256, publicKeyRepresentation: p256Bytes)
        coordinator.rememberKeepAwakeToggleKey(nodeId: "node-p256", key: p256Key)
        XCTAssertNil(
            keepAwake.rememberedKeys["node-p256"],
            "non-Ed25519 keys cannot sign toggles and must not be cached"
        )
    }

    func testPhoneSetTrustModeIntentRefusesElevation() async throws {
        let coordinator = makeCoordinator()
        try await startSession(coordinator, trustMode: .manual)
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual)
        coordinator.applyPhoneTrustModeIntent(
            PhoneControlIntent(kind: .setTrustMode, text: ComputerUseTrustMode.trusted.rawValue)
        )
        XCTAssertEqual(
            coordinator.state?.liveTrustMode,
            .manual,
            "phone setTrustMode must go through the coordinator clamp"
        )
    }

    func testPhoneSetTrustModeIntentAcceptsDowngrade() async throws {
        let coordinator = makeCoordinator()
        try await startSession(coordinator, trustMode: .trusted)
        coordinator.applyPhoneTrustModeIntent(
            PhoneControlIntent(kind: .setTrustMode, text: ComputerUseTrustMode.manual.rawValue)
        )
        XCTAssertEqual(coordinator.state?.liveTrustMode, .manual)
    }
}

@MainActor
private final class FakeKeepAwakeController: KeepAwakeControlling {
    var holds: [KeepAwakeReason] = []
    var releases: [KeepAwakeReason] = []
    var rememberedKeys: [String: Data] = [:]
    var onRelease: (() -> Void)?

    func set(_ reason: KeepAwakeReason, held: Bool) {
        if held {
            holds.append(reason)
        } else {
            releases.append(reason)
            onRelease?()
        }
    }

    func rememberTogglePublicKey(_ publicKey: Data, for deviceId: String) {
        rememberedKeys[deviceId] = publicKey
    }
}

private final class FakeWatchHUDSession: AgentWatchHUDControlling {
    var startCount = 0
    var stopCount = 0

    func start() async throws {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
    }
}
#endif
