#if os(Linux)
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

/// The Linux executable and the macOS CLI share the Unix-socket contract. A
/// command being present in `OpenBurnBarCLI` is not enough: the signed CLI
/// peer profile must also admit every RPC that command sends.
final class LinuxCLICapabilityTests: XCTestCase {
    func testCliSupportAdmitsEveryLinuxSocketCommandPath() {
        let profile = BurnBarPeerCapabilityProfile.cliSupport
        let commandRPCs: Set<BurnBarRPCMethod> = [
            .health,
            .controllerSummary,
            .questionsList,
            .followupsList,
            .missionsList,
            .missionApprove,
            .simulatorList,
            .simulatorReplay,
            .memoryRecall,
            .codeIndexProject,
            .codeWatchProject,
            .codeSearch,
            .codeIndexStatus,
            .clientAttach,
            .clientClaimControl,
            .runCreate,
            .runList,
            .runGet,
            .runPoll,
            .runCancel,
            .runRetry,
            .approvalRespond,
            .subscriptionStart,
            .subscriptionResume,
            .runResume,
            .computerUsePanicHalt,
            .linuxPrivacyInventory,
            .linuxPrivacyDeletionPreview,
            .linuxPrivacyDeletionExecute,
            .linuxPrivacyExport,
            .linuxPrivacyRetentionStatus,
            .linuxPrivacyRetentionApply
        ]

        for method in commandRPCs {
            XCTAssertTrue(
                profile.permits(method),
                "Linux CLI command path is blocked by cliSupport: (method.rawValue)"
            )
        }
        XCTAssertEqual(profile.permittedMethods, commandRPCs)
    }

    func testCliSupportDoesNotExpandIntoUnrelatedAgency() {
        let profile = BurnBarPeerCapabilityProfile.cliSupport

        for method in [
            BurnBarRPCMethod.configUpdate,
            .providerCredentialSlotUpsert,
            .linuxOnboardingAction,
            .workspaceExecuteTool,
            .computerUseSessionStart,
            .computerUseInvoke,
            .missionCreate,
            .memoryRemember,
            .codeOpsDiagnostics,
            .clientDetach
        ] {
            XCTAssertFalse(profile.permits(method), "CLI unexpectedly gained (method.rawValue)")
        }
    }
}
#endif
