#if os(Linux)
import OpenBurnBarEngine
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
            // Signed CLI courier for the Python MCP on signed installs
            // (`openburnbar-cli search-sql|memory-remember|memory-forget|
            // memory-model-policy`, #2499/#2501), the Memory Blind Sync
            // inbox drain (`memory-sync-inbox-list|memory-sync-inbox-ack`,
            // #2519) and the `code-explore` courier command (#2552).
            .searchSQL,
            .memoryRemember,
            .memoryForget,
            .memoryModelPolicy,
            .memorySyncInboxList,
            .memorySyncInboxAck,
            .codeExplore,
            .controllerSummary,
            .questionsList,
            .followupsList,
            .missionsList,
            .missionHealth,
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
            // A memory write the CLI has no command for stays outside its agency.
            .memoryReviewStatus,
            .codeOpsDiagnostics,
            .clientDetach
        ] {
            XCTAssertFalse(profile.permits(method), "CLI unexpectedly gained (method.rawValue)")
        }
    }
}
#endif
