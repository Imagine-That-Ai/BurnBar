import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// T-DMN-01: per-operation capability attenuation on the main control socket.
/// Each RPC method maps to exactly one capability group, and an attenuated peer
/// profile must refuse — fail closed — any method outside its scoped set.
final class BurnBarRPCCapabilityTests: XCTestCase {
    func test_everyMethodHasACapability() {
        // Totality: the classification switch covers every case, so this simply
        // proves no method resolves to an unexpected group and the map is stable.
        for method in BurnBarRPCMethod.allCases {
            _ = BurnBarRPCCapability.capability(for: method)
        }
    }

    func test_highRiskMethodsMapToExpectedGroups() {
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .computerUseInvoke), .computerUse)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .computerUseSessionStart), .computerUse)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .computerUseCapabilityStateUpdate), .computerUse)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .configUpdate), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .providerCredentialSlotUpsert), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .runCreate), .run)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .subscriptionStart), .run)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .subscriptionResume), .run)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .subscriptionStop), .run)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .health), .lifecycle)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .linuxOnboardingSnapshot), .lifecycle)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .linuxOnboardingAction), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .linuxOnboardingReset), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .searchQuery), .search)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .chatThreadList), .chat)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .chatThreadGet), .chat)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .chatMessageAppend), .chat)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .memoryRecall), .memoryRead)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .memoryRemember), .memoryWrite)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .codeSearch), .codeRead)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .codeIndexProject), .codeWrite)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .fleetSnapshot), .observability)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .fleetOrchestratorGet), .observability)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .fleetOrchestratorSet), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .fleetDirectiveRecord), .config)
    }

    func test_fullProfilePermitsEveryMethod() {
        let profile = BurnBarPeerCapabilityProfile.full
        for method in BurnBarRPCMethod.allCases {
            XCTAssertTrue(profile.permits(method), "full profile must permit \(method.rawValue)")
        }
    }

    func test_readOnlyProfileRefusesWritesAndComputerUse() {
        let profile = BurnBarPeerCapabilityProfile.readOnly
        // Allowed: read posture.
        XCTAssertTrue(profile.permits(.health))
        XCTAssertTrue(profile.permits(.linuxOnboardingSnapshot))
        XCTAssertTrue(profile.permits(.usageRecent))
        XCTAssertTrue(profile.permits(.usageHistory))
        XCTAssertTrue(profile.permits(.searchQuery))
        XCTAssertTrue(profile.permits(.memoryRecall))
        XCTAssertTrue(profile.permits(.codeSearch))
        XCTAssertTrue(profile.permits(.codeIndexStatus))
        // Refused: every agency-bearing surface.
        XCTAssertFalse(profile.permits(.configUpdate))
        XCTAssertFalse(profile.permits(.linuxOnboardingAction))
        XCTAssertFalse(profile.permits(.linuxOnboardingReset))
        XCTAssertFalse(profile.permits(.providerCredentialSlotUpsert))
        XCTAssertFalse(profile.permits(.runCreate))
        XCTAssertFalse(profile.permits(.computerUseInvoke))
        XCTAssertFalse(profile.permits(.computerUseSessionGrantAcquire))
        XCTAssertFalse(profile.permits(.computerUseSessionGrantStatus))
        XCTAssertFalse(profile.permits(.computerUseSessionStart))
        XCTAssertFalse(profile.permits(.computerUseCapabilityStateUpdate))
        XCTAssertFalse(profile.permits(.browserAction))
        XCTAssertFalse(profile.permits(.memoryRemember))
        XCTAssertFalse(profile.permits(.memoryForget))
        XCTAssertFalse(profile.permits(.codeIndexProject))
    }

    func test_runClientProfileIsDeniedComputerUseAndConfig() {
        let profile = BurnBarPeerCapabilityProfile.runClient
        XCTAssertTrue(profile.permits(.runCreate))
        XCTAssertTrue(profile.permits(.clientAttach))
        XCTAssertTrue(profile.permits(.browserAction))
        XCTAssertTrue(profile.permits(.memoryRecall))
        XCTAssertTrue(profile.permits(.codeSearch))
        // A compromised run client must NOT reach the HID-adjacent computer-use
        // surface or rewrite stored provider credentials.
        XCTAssertFalse(profile.permits(.computerUseCapabilityStateUpdate))
        XCTAssertFalse(profile.permits(.computerUseInvoke))
        XCTAssertFalse(profile.permits(.configUpdate))
        XCTAssertFalse(profile.permits(.providerCredentialSlotUpsert))
        XCTAssertFalse(profile.permits(.memoryRemember))
        XCTAssertFalse(profile.permits(.codeIndexProject))
    }

    func test_cliSupportProfileIsExactMethodAllowlist() {
        let profile = BurnBarPeerCapabilityProfile.cliSupport
        // Commands implemented by OpenBurnBarCLI.
        XCTAssertTrue(profile.permits(.health))
        XCTAssertTrue(profile.permits(.controllerSummary))
        XCTAssertTrue(profile.permits(.questionsList))
        XCTAssertTrue(profile.permits(.followupsList))
        XCTAssertTrue(profile.permits(.missionsList))
        XCTAssertTrue(profile.permits(.missionApprove))
        XCTAssertTrue(profile.permits(.simulatorList))
        XCTAssertTrue(profile.permits(.simulatorReplay))
        XCTAssertTrue(profile.permits(.memoryRecall))
        XCTAssertTrue(profile.permits(.codeIndexProject))
        XCTAssertTrue(profile.permits(.codeWatchProject))
        XCTAssertTrue(profile.permits(.codeSearch))
        XCTAssertTrue(profile.permits(.codeIndexStatus))
        XCTAssertTrue(profile.permits(.clientAttach))
        XCTAssertTrue(profile.permits(.clientClaimControl))
        XCTAssertTrue(profile.permits(.runCreate))
        XCTAssertTrue(profile.permits(.runList))
        XCTAssertTrue(profile.permits(.runGet))
        XCTAssertTrue(profile.permits(.runPoll))
        XCTAssertTrue(profile.permits(.runCancel))
        XCTAssertTrue(profile.permits(.runRetry))
        XCTAssertTrue(profile.permits(.approvalRespond))
        XCTAssertTrue(profile.permits(.subscriptionStart))
        XCTAssertTrue(profile.permits(.subscriptionResume))
        XCTAssertTrue(profile.permits(.runResume))
        XCTAssertTrue(profile.permits(.computerUsePanicHalt))
        XCTAssertTrue(profile.permits(.linuxPrivacyInventory))
        XCTAssertTrue(profile.permits(.linuxPrivacyDeletionPreview))
        XCTAssertTrue(profile.permits(.linuxPrivacyDeletionExecute))
        XCTAssertTrue(profile.permits(.linuxPrivacyExport))
        XCTAssertTrue(profile.permits(.linuxPrivacyRetentionStatus))
        XCTAssertTrue(profile.permits(.linuxPrivacyRetentionApply))

        // Keep the security boundary exact: these are the socket RPCs used by
        // the CLI client and its run/subscription/safety commands, not an
        // entire capability group.
        let expected: Set<BurnBarRPCMethod> = [
            .health,
            .searchSQL,
            .memoryRemember,
            .memoryForget,
            .memoryModelPolicy,
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
        XCTAssertEqual(profile.permittedMethods, expected)

        // The CLI must not inherit whole capability groups just because one
        // supported command lives there.
        XCTAssertFalse(profile.permits(.configUpdate))
        XCTAssertFalse(profile.permits(.linuxOnboardingSnapshot))
        XCTAssertFalse(profile.permits(.linuxOnboardingAction))
        XCTAssertFalse(profile.permits(.linuxOnboardingReset))
        XCTAssertFalse(profile.permits(.providerCredentialSlotUpsert))
        XCTAssertFalse(profile.permits(.computerUseSessionStart))
        XCTAssertFalse(profile.permits(.computerUseInvoke))
        XCTAssertFalse(profile.permits(.computerUseCapabilityStateUpdate))
        XCTAssertFalse(profile.permits(.workspaceExecuteTool))
        XCTAssertFalse(profile.permits(.missionCreate))
        XCTAssertFalse(profile.permits(.missionCancel))
        XCTAssertFalse(profile.permits(.codeOpsDiagnostics))
    }

    /// The Python MCP reaches the daemon through the signed CLI courier
    /// (`openburnbar-cli search-sql|memory-remember|memory-forget`). The CLI
    /// client implements those three RPCs, so the CLI peer profile must permit
    /// them or every courier call dies at the capability gate with
    /// `unauthorized` on a signed install.
    func test_cliSupportProfilePermitsTheSignedCourierMethods() {
        let profile = BurnBarPeerCapabilityProfile.cliSupport
        XCTAssertTrue(profile.permits(.searchSQL))
        XCTAssertTrue(profile.permits(.memoryRemember))
        XCTAssertTrue(profile.permits(.memoryForget))
        XCTAssertTrue(profile.permits(.memoryModelPolicy))
        // Minting a spend-capable gateway bearer is write-class: attenuated read
        // peers must never reach it.
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .memoryModelPolicy), .memoryWrite)
        XCTAssertFalse(BurnBarPeerCapabilityProfile.readOnly.permits(.memoryModelPolicy))
        XCTAssertFalse(BurnBarPeerCapabilityProfile.runClient.permits(.memoryModelPolicy))
        // Read-only and run-client peers still may not write memory.
        XCTAssertFalse(BurnBarPeerCapabilityProfile.readOnly.permits(.memoryRemember))
        XCTAssertFalse(BurnBarPeerCapabilityProfile.runClient.permits(.memoryRemember))
    }

    func test_attenuationOnlyNarrows() {
        let narrowed = BurnBarPeerCapabilityProfile.full
            .attenuated(to: .readOnly)
        XCTAssertEqual(narrowed.permittedMethods, BurnBarPeerCapabilityProfile.readOnly.permittedMethods)
        // Intersecting with full cannot widen readOnly.
        let stillNarrow = BurnBarPeerCapabilityProfile.readOnly.attenuated(to: .full)
        XCTAssertEqual(stillNarrow.permittedMethods, BurnBarPeerCapabilityProfile.readOnly.permittedMethods)
    }

    func test_missionAuthorizeRemoteIsMissionControlScopedAndRefusedForAttenuatedPeers() {
        // M2 (split-brain remediation): the new remote-mission authorization
        // verdict is a mission-control-capability surface. Peers outside that
        // group — read-only posture and the exact-allowlist CLI profile — must
        // be refused fail-closed BEFORE the handler runs.
        XCTAssertEqual(
            BurnBarRPCCapability.capability(for: .missionAuthorizeRemote),
            .missionControl
        )
        XCTAssertTrue(BurnBarPeerCapabilityProfile.full.permits(.missionAuthorizeRemote))
        XCTAssertTrue(BurnBarPeerCapabilityProfile.runClient.permits(.missionAuthorizeRemote))
        XCTAssertFalse(
            BurnBarPeerCapabilityProfile.readOnly.permits(.missionAuthorizeRemote),
            "a read-only peer must not obtain mission authorization verdicts"
        )
        XCTAssertFalse(
            BurnBarPeerCapabilityProfile.cliSupport.permits(.missionAuthorizeRemote),
            "the CLI allowlist must not inherit the new method implicitly"
        )
        // Attenuation can only ever narrow away the new method, never add it.
        let narrowed = BurnBarPeerCapabilityProfile.full.attenuated(to: .readOnly)
        XCTAssertFalse(narrowed.permits(.missionAuthorizeRemote))
    }

    func test_attenuationPreservesMethodScopedCLIBoundary() {
        let narrowed = BurnBarPeerCapabilityProfile.full.attenuated(to: .cliSupport)
        XCTAssertEqual(narrowed.permittedMethods, BurnBarPeerCapabilityProfile.cliSupport.permittedMethods)

        let appReadOnly = BurnBarPeerCapabilityProfile.readOnly.attenuated(to: .cliSupport)
        XCTAssertTrue(appReadOnly.permits(.health))
        XCTAssertTrue(appReadOnly.permits(.memoryRecall))
        XCTAssertFalse(appReadOnly.permits(.codeIndexProject))
        XCTAssertFalse(appReadOnly.permits(.runResume))
    }
}
