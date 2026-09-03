import XCTest
@testable import OpenBurnBarCore

/// Wire-contract tests for `BurnBarRPCContracts.swift`. Complements
/// `BurnBarMissionControlContractsTests` (which spot-checks the controller
/// surface) by pinning the FULL `BurnBarRPCMethod` wire-name table — so any
/// rename or removal of an RPC method (including the perf-round-2
/// `controllerRuntimeSnapshot` aggregate) breaks loudly — and by exercising
/// the request/response envelopes that carry the new method across the
/// daemon socket.
final class BurnBarRPCContractsTests: XCTestCase {
    /// One entry per `BurnBarRPCMethod` case. These strings are the daemon's
    /// wire protocol: changing any of them breaks every shipped client, so a
    /// mismatch here must be treated as a protocol break, not a test update.
    private static let expectedWireNames: [BurnBarRPCMethod: String] = [
        .authBootstrap: "auth.bootstrap",
        .linuxAuthStatus: "daemon.auth.status",
        .linuxAuthBegin: "daemon.auth.begin",
        .linuxAuthCancel: "daemon.auth.cancel",
        .linuxAuthRotateIdentity: "daemon.auth.rotate_identity",
        .linuxAuthSignOut: "daemon.auth.sign_out",
        .linuxAccountCloudDataDelete: "daemon.account.cloud_data.delete",
        .linuxAccountCloudDataExport: "daemon.account.cloud_data.export",
        .linuxTrustedDeviceList: "daemon.account.trusted_devices.list",
        .linuxTrustedDeviceApprove: "daemon.account.trusted_device.approve",
        .linuxTrustedDeviceRevoke: "daemon.account.trusted_device.revoke",
        .linuxCloudSyncStatus: "daemon.cloud_sync.status",
        .linuxCloudSyncPolicyUpdate: "daemon.cloud_sync.policy.update",
        .linuxCloudSyncRun: "daemon.cloud_sync.run",
        .health: "daemon.health",
        .catalog: "daemon.catalog",
        .linuxOnboardingSnapshot: "daemon.onboarding.snapshot",
        .linuxOnboardingAction: "daemon.onboarding.action",
        .linuxOnboardingReset: "daemon.onboarding.reset",
        .configGet: "daemon.config.get",
        .configUpdate: "daemon.config.update",
        .textExpansionGet: "daemon.text_expansion.get",
        .textExpansionUpsert: "daemon.text_expansion.upsert",
        .textExpansionDelete: "daemon.text_expansion.delete",
        .textExpansionConsentUpdate: "daemon.text_expansion.consent.update",
        .textExpansionEngineStatus: "daemon.text_expansion.engine.status",
        .textExpansionEngineStart: "daemon.text_expansion.engine.start",
        .textExpansionEngineStop: "daemon.text_expansion.engine.stop",
        .textExpansionEngineExpand: "daemon.text_expansion.engine.expand",
        .linuxPrivacyInventory: "daemon.privacy.inventory",
        .linuxPrivacyDeletionPreview: "daemon.privacy.deletion.preview",
        .linuxPrivacyDeletionExecute: "daemon.privacy.deletion.execute",
        .linuxPrivacyExport: "daemon.privacy.export",
        .linuxPrivacyRetentionStatus: "daemon.privacy.retention.status",
        .linuxPrivacyRetentionApply: "daemon.privacy.retention.apply",
        .providerCredentialSlotUpsert: "daemon.provider.credential_slot.upsert",
        .providerCredentialSlotRemove: "daemon.provider.credential_slot.remove",
        .providerModelVariantUpsert: "daemon.provider.model_variant.upsert",
        .providerModelVariantRemove: "daemon.provider.model_variant.remove",
        .providerModelAliasUpsert: "daemon.provider.model_alias.upsert",
        .providerModelAliasRemove: "daemon.provider.model_alias.remove",
        .providerCustomModelUpsert: "daemon.provider.custom_model.upsert",
        .providerCustomModelRemove: "daemon.provider.custom_model.remove",
        .providerModelDisplayNameSet: "daemon.provider.model_display_name.set",
        .providerModelDisplayNameClear: "daemon.provider.model_display_name.clear",
        .usageRecord: "daemon.usage.record",
        .usageRecent: "daemon.usage.recent",
        .usageHistory: "daemon.usage.history",
        .usageInsights: "daemon.usage.insights",
        .usageProjection: "daemon.usage.projection",
        .usageRecount: "daemon.usage.recount",
        .chatThreadList: "daemon.chat.thread.list",
        .chatThreadGet: "daemon.chat.thread.get",
        .chatMessageAppend: "daemon.chat.message.append",
        .proxyRouteLogRecent: "daemon.proxy.route_log.recent",
        .proxyRouteLogClear: "daemon.proxy.route_log.clear",
        .quotaSignalsRecent: "daemon.quota.signals.recent",
        .quotaSignalsClear: "daemon.quota.signals.clear",
        .connectorPlaneGet: "daemon.connector.plane.get",
        .connectorConfigUpdate: "daemon.connector.config.update",
        .connectorAction: "daemon.connector.action",
        .browserToolingGet: "daemon.browser.tooling.get",
        .browserToolingUpdate: "daemon.browser.tooling.update",
        .browserAction: "daemon.browser.action",
        .computerUseCapabilityStateUpdate: "daemon.computer_use.capability_state.update",
        .computerUseSessionGrantReadiness: "daemon.computer_use.session_grant.readiness",
        .computerUseSessionGrantAcquire: "daemon.computer_use.session_grant.acquire",
        .computerUseSessionGrantStatus: "daemon.computer_use.session_grant.status",
        .computerUseSessionStart: "daemon.computer_use.session.start",
        .computerUseInvoke: "daemon.computer_use.invoke",
        .computerUseApprovalPending: "daemon.computer_use.approval.pending",
        .computerUseApprovalRespond: "daemon.computer_use.approval.respond",
        .computerUsePanicHalt: "daemon.computer_use.panic_halt",
        .computerUseAuditExport: "daemon.computer_use.audit_export",
        .phoneControlPinProvision: "daemon.phone_control.pin.provision",
        .controllerSummary: "daemon.controller.summary",
        .controllerRuntimeSnapshot: "daemon.controller.runtime_snapshot",
        .controllerProjectsList: "daemon.controller.project.list",
        .controllerProjectGet: "daemon.controller.project.get",
        .controllerProjectUpsert: "daemon.controller.project.upsert",
        .controllerProjectDelete: "daemon.controller.project.delete",
        .controllerProjectReassign: "daemon.controller.project.reassign",
        .reviewRunRecord: "daemon.controller.review.record",
        .questionCreate: "daemon.question.create",
        .questionGet: "daemon.question.get",
        .questionsList: "daemon.question.list",
        .questionAnswer: "daemon.question.answer",
        .followupCreate: "daemon.followup.create",
        .followupsList: "daemon.followup.list",
        .followupDone: "daemon.followup.done",
        .followupSnooze: "daemon.followup.snooze",
        .followupCalendar: "daemon.followup.calendar",
        .missionCreate: "daemon.mission.create",
        .missionsList: "daemon.mission.list",
        .missionGet: "daemon.mission.get",
        .missionHealth: "daemon.mission.health",
        .missionApprove: "daemon.mission.approve",
        .missionCancel: "daemon.mission.cancel",
        .missionDispatchPacket: "daemon.mission.packet.dispatch",
        .missionRecordResult: "daemon.mission.result.record",
        // Added with M2 of the split-brain remediation (Phase 2): daemon-side
        // remote-mission authorization. Additive; the GUI wires it in M3.
        .missionAuthorizeRemote: "daemon.mission.authorizeRemote",
        .notificationConfigGet: "daemon.notification.config.get",
        .notificationConfigUpdate: "daemon.notification.config.update",
        .notificationHealth: "daemon.notification.health",
        .notificationCommand: "daemon.notification.command",
        .simulatorRun: "daemon.simulator.run",
        .simulatorList: "daemon.simulator.list",
        .simulatorReplay: "daemon.simulator.replay",
        .projectionRebuild: "daemon.projection.rebuild",
        .runCreate: "run.create",
        .runList: "run.list",
        .runGet: "run.get",
        .runPoll: "run.poll",
        .runCancel: "run.cancel",
        .runRetry: "run.retry",
        .workspaceExecuteTool: "workspace.executeTool",
        .workspaceToolResult: "workspace.toolResult",
        .approvalRespond: "approval.respond",
        .clientAttach: "client.attach",
        .clientClaimControl: "client.claimControl",
        .clientDetach: "client.detach",
        .searchQuery: "daemon.search.query",
        .searchSQL: "daemon.search.sql",
        .memoryRemember: "daemon.memory.remember",
        .memoryRecall: "daemon.memory.recall",
        .memoryReviewStatus: "daemon.memory.review_status",
        .memoryForget: "daemon.memory.forget",
        .memoryAuditTrail: "daemon.memory.audit_trail",
        .memoryAnalytics: "daemon.memory.analytics",

        .memoryModelPolicy: "daemon.memory.model_policy",
        .codeIndexProject: "daemon.code.index_project",
        .codeWatchProject: "daemon.code.watch_project",
        .codeSearch: "daemon.code.search",
        .codeContextPack: "daemon.code.context_pack",
        .codeGetSymbol: "daemon.code.get_symbol",
        .codeFindReferences: "daemon.code.find_references",
        .codeCallGraph: "daemon.code.call_graph",
        .codeDiagnostics: "daemon.code.diagnostics",
        .codeIndexStatus: "daemon.code.index_status",
        .codeExplore: "daemon.code.explore",
        .codeOpsDiagnostics: "daemon.code.ops_diagnostics",
        .codeDatabaseSnapshot: "daemon.code.database_snapshot",
        .codeDatabaseRestore: "daemon.code.database_restore",
        .databaseRecoveryStatus: "daemon.database.recovery.status",
        .databaseRecoveryBundleExport: "daemon.database.recovery_bundle.export",
        .databaseRecoveryBundleImport: "daemon.database.recovery_bundle.import",
        // AI Inbox — daemon-resident proactive analyst (see BurnBarRPCContracts).
        .inboxList: "daemon.inbox.list",
        .inboxGet: "daemon.inbox.get",
        .inboxRunsRecent: "daemon.inbox.runs.recent",
        .inboxConfigGet: "daemon.inbox.config.get",
        .inboxConfigUpdate: "daemon.inbox.config.update",
        .inboxRunNow: "daemon.inbox.run_now",
        .inboxThreadGet: "daemon.inbox.thread.get",
        .inboxReply: "daemon.inbox.reply",
        .inboxPlansList: "daemon.inbox.plans.list",
        .inboxPlansGet: "daemon.inbox.plans.get",
        .inboxPlansAccept: "daemon.inbox.plans.accept",
        .inboxPlansUpdateStep: "daemon.inbox.plans.update_step",
        .inboxPlansGrade: "daemon.inbox.plans.grade",
        .inboxMemoryExport: "daemon.inbox.memory.export",
        .runResume: "run.resume",
        .daemonMediaSessionState: "daemon.media.session.state",
        .daemonMediaCallAccept: "daemon.media.call.accept",
        .daemonMediaCallDecline: "daemon.media.call.decline",
        .daemonMediaCallEnd: "daemon.media.call.end",
        .daemonMediaCapabilityGet: "daemon.media.capability.get",
        .daemonMediaStatus: "daemon.media.status",
        .daemonMediaFileOfferList: "daemon.media.file.offer.list",
        .daemonMediaFileAccept: "daemon.media.file.accept",
        .daemonMediaFileDecline: "daemon.media.file.decline",
        .daemonMediaFileSend: "daemon.media.file.send",
        // Added with the 98-method canon regen (main 69e2a41deb): membership +
        // subscription lifecycle + perf.measure. Wire names pinned to the enum rawValues.
        .membershipStatus: "daemon.membership.status",
        .membershipCheckoutURL: "daemon.membership.checkoutUrl",
        .membershipPortalURL: "daemon.membership.portalUrl",
        .membershipRestore: "daemon.membership.restore",
        .subscriptionStart: "subscription.start",
        .subscriptionResume: "subscription.resume",
        .subscriptionStop: "subscription.stop",
        .perfMeasure: "perf.measure",
        .fleetSnapshot: "daemon.fleet.snapshot",
        .fleetOrchestratorGet: "daemon.fleet.orchestrator.get",
        .fleetOrchestratorSet: "daemon.fleet.orchestrator.set",
        .fleetDirectiveRecord: "daemon.fleet.directive.record",
        // War Room: the Flame's three RPCs (route, and the distill log it
        // archives every decision into).
        .warFlameRoute: "daemon.war.flame.route",
        .warFlameDistillList: "daemon.war.flame.distill.list",
        .warFlameDistillSettle: "daemon.war.flame.distill.settle"
    ]

    func testRPCMethodWireNames_areStableForEveryCase() {
        XCTAssertEqual(
            Self.expectedWireNames.count,
            BurnBarRPCMethod.allCases.count,
            "BurnBarRPCMethod gained or lost a case without updating the wire-name table — add the new case here so its wire name is pinned."
        )
        for method in BurnBarRPCMethod.allCases {
            XCTAssertEqual(
                method.rawValue,
                Self.expectedWireNames[method],
                "Wire name drifted for \(method) — this is a daemon protocol break."
            )
        }
    }

    func testRPCMethodWireNames_areUniqueWireIdentifiers() {
        let rawValues = BurnBarRPCMethod.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(rawValues).count,
            rawValues.count,
            "Two BurnBarRPCMethod cases share a wire name; the daemon dispatcher cannot disambiguate them."
        )
    }

    func testRPCMethod_roundTripsThroughJSONAndRejectsUnknownWireName() throws {
        // Every case must survive a JSON round trip as its wire string.
        let encoded = try JSONEncoder().encode(BurnBarRPCMethod.allCases)
        let decoded = try JSONDecoder().decode([BurnBarRPCMethod].self, from: encoded)
        XCTAssertEqual(decoded, BurnBarRPCMethod.allCases)

        // Unknown methods must fail decoding (the daemon-side rejection an
        // old daemon gives the new aggregate method, mirrored client-side).
        let unknown = Data(#"["daemon.controller.runtime_snapshot.v2"]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([BurnBarRPCMethod].self, from: unknown)) { error in
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(error)")
        }
    }

    func testLinuxAuthResponsesExposeOnlyRedactedState() throws {
        let status = BurnBarLinuxAuthStatusResponse(
            state: .awaitingDeviceApproval,
            signedIn: false,
            authorizationOperationID: "operation-1",
            authorizationExpiresAt: "2026-07-11T22:00:00Z",
            deviceApprovalRequired: true,
            installationDeviceID: "linux_0123456789abcdef",
            installationSafetyFingerprint: "0123 4567 89AB CDEF",
            detail: "Approval required on a trusted device."
        )
        let encoded = try JSONEncoder().encode(status)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(json.contains("awaiting_device_approval"))
        XCTAssertTrue(json.contains("linux_0123456789abcdef"))
        XCTAssertTrue(json.contains("0123 4567 89AB CDEF"))
        XCTAssertFalse(json.contains("refreshToken"))
        XCTAssertFalse(json.contains("idToken"))
        XCTAssertFalse(json.contains("appCheckToken"))
        XCTAssertFalse(json.contains("publicKey"))
        XCTAssertFalse(json.contains("sessionGeneration"))
    }

    func testControllerRuntimeSnapshotMethod_isAdditiveControllerNamespaceExtension() throws {
        XCTAssertTrue(BurnBarRPCMethod.allCases.contains(.controllerRuntimeSnapshot))
        XCTAssertEqual(BurnBarRPCMethod.controllerRuntimeSnapshot.rawValue, "daemon.controller.runtime_snapshot")
        XCTAssertTrue(
            BurnBarRPCMethod.controllerRuntimeSnapshot.rawValue.hasPrefix("daemon.controller."),
            "The aggregate snapshot must live in the controller namespace so daemon auth/dispatch policy applies uniformly."
        )

        // The wire string decodes back to the case, proving an updated client
        // can name the method to an updated daemon.
        let decoded = try JSONDecoder().decode(
            [BurnBarRPCMethod].self,
            from: Data(#"["daemon.controller.runtime_snapshot"]"#.utf8)
        )
        XCTAssertEqual(decoded, [.controllerRuntimeSnapshot])
    }

    func testRequestEnvelope_carriesRuntimeSnapshotMethodAndOmitsNilAuthToken() throws {
        let envelope = BurnBarRPCRequestEnvelope(id: "req-1", method: .controllerRuntimeSnapshot)

        let data = try JSONEncoder().encode(envelope)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"daemon.controller.runtime_snapshot\""))
        XCTAssertFalse(json.contains("authToken"), "nil authToken must stay off the wire")

        let decoded = try JSONDecoder().decode(BurnBarRPCRequestEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)

        // Raw wire JSON without an authToken key (pre-auth bootstrap shape)
        // must decode, with the token absent rather than failing.
        let rawWire = Data(#"{"id":"req-2","method":"daemon.controller.runtime_snapshot"}"#.utf8)
        let fromWire = try JSONDecoder().decode(BurnBarRPCRequestEnvelope.self, from: rawWire)
        XCTAssertEqual(fromWire.id, "req-2")
        XCTAssertEqual(fromWire.method, .controllerRuntimeSnapshot)
        XCTAssertNil(fromWire.authToken)
    }

    func testRequestEnvelopeWithParams_carriesEmptyRuntimeSnapshotRequest() throws {
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "snapshot-1",
            method: .controllerRuntimeSnapshot,
            authToken: "session-token",
            params: BurnBarControllerRuntimeSnapshotRequest()
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerRuntimeSnapshotRequest>.self,
            from: data
        )

        XCTAssertEqual(decoded.id, "snapshot-1")
        XCTAssertEqual(decoded.method, .controllerRuntimeSnapshot)
        XCTAssertEqual(decoded.authToken, "session-token")
        XCTAssertEqual(decoded.params, BurnBarControllerRuntimeSnapshotRequest())
    }

    func testResponseEnvelope_errorLaneModelsOldDaemonRejectingNewMethod() throws {
        // An older daemon answers the new aggregate method with an error
        // envelope; the client must read the error and fall back to the
        // per-list RPCs. The error lane must round-trip with a nil result.
        let rejection = BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse>(
            id: "snapshot-1",
            error: BurnBarRPCError(code: -32601, message: "unsupported method: daemon.controller.runtime_snapshot")
        )

        let data = try JSONEncoder().encode(rejection)
        let decoded = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse>.self,
            from: data
        )

        XCTAssertEqual(decoded.id, "snapshot-1")
        XCTAssertEqual(decoded.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error?.code, -32601)
        XCTAssertEqual(decoded.error?.message, "unsupported method: daemon.controller.runtime_snapshot")

        // A minimal wire envelope with neither result nor error must still
        // decode (both lanes are optional on the wire).
        let bare = Data(#"{"id":"snapshot-2","protocolVersion":1}"#.utf8)
        let bareDecoded = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse>.self,
            from: bare
        )
        XCTAssertNil(bareDecoded.result)
        XCTAssertNil(bareDecoded.error)
    }
}
