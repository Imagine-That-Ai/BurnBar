#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarComputerUseCore
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
}
#endif
