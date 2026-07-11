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
        .health: "daemon.health",
        .catalog: "daemon.catalog",
        .linuxOnboardingSnapshot: "daemon.onboarding.snapshot",
        .linuxOnboardingAction: "daemon.onboarding.action",
        .linuxOnboardingReset: "daemon.onboarding.reset",
        .configGet: "daemon.config.get",
        .configUpdate: "daemon.config.update",
        .providerCredentialSlotUpsert: "daemon.provider.credential_slot.upsert",
        .providerCredentialSlotRemove: "daemon.provider.credential_slot.remove",
        .providerExternalAuthStart: "daemon.provider.external_auth.start",
        .providerExternalAuthStatus: "daemon.provider.external_auth.status",
        .providerExternalAuthCancel: "daemon.provider.external_auth.cancel",
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
        .proxyRouteLogRecent: "daemon.proxy.route_log.recent",
        .proxyRouteLogClear: "daemon.proxy.route_log.clear",
        .quotaSignalsRecent: "daemon.quota.signals.recent",
        .quotaSignalsClear: "daemon.quota.signals.clear",
        .accountStatus: "daemon.account.status",
        .linuxAppCheckStatus: "daemon.cloud.app_check.status",
        .accountDeviceAuthStart: "daemon.account.device_auth.start",
        .accountDeviceAuthPoll: "daemon.account.device_auth.poll",
        .accountDeviceAuthCancel: "daemon.account.device_auth.cancel",
        .accountSignOut: "daemon.account.sign_out",
        .connectorPlaneGet: "daemon.connector.plane.get",
        .connectorConfigUpdate: "daemon.connector.config.update",
        .connectorAction: "daemon.connector.action",
        .browserToolingGet: "daemon.browser.tooling.get",
        .browserToolingUpdate: "daemon.browser.tooling.update",
        .browserAction: "daemon.browser.action",
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
        .memoryRemember: "daemon.memory.remember",
        .memoryRecall: "daemon.memory.recall",
        .memoryForget: "daemon.memory.forget",
        .memoryAuditTrail: "daemon.memory.audit_trail",
        .memoryAnalytics: "daemon.memory.analytics",
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
        .membershipRestore: "daemon.membership.restore",
        .subscriptionStart: "subscription.start",
        .subscriptionResume: "subscription.resume",
        .subscriptionStop: "subscription.stop",
        .perfMeasure: "perf.measure"
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

    func testAccountSnapshotUsesRedactedStableWireKeys() throws {
        let session = BurnBarAccountDeviceAuthSession(
            flowID: "123E4567-E89B-12D3-A456-426614174000",
            userCode: "ABCD-EFGH",
            verificationURL: "https://burnbar.ai/link?code=ABCD-EFGH&flow=desktop_auth",
            expiresAt: "2030-01-01T00:00:00Z",
            pollIntervalSeconds: 5
        )
        let response = BurnBarAccountStatusResponse(account: BurnBarAccountSnapshot(
            state: .authorizationPending,
            trustClass: "linux_lower_trust",
            syncState: "local_only",
            credentialBackend: "org.freedesktop.secrets",
            session: session,
            updatedAt: "2030-01-01T00:00:00Z"
        ))
        let encoded = try JSONEncoder().encode(response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let account = try XCTUnwrap(json["account"] as? [String: Any])
        let encodedSession = try XCTUnwrap(account["session"] as? [String: Any])

        XCTAssertEqual(account["state"] as? String, "authorization_pending")
        XCTAssertEqual(account["credential_backend"] as? String, "org.freedesktop.secrets")
        XCTAssertEqual(encodedSession["flow_id"] as? String, session.flowID)
        XCTAssertNil(account["refresh_token"])
        XCTAssertNil(account["id_token"])
        XCTAssertNil(encodedSession["device_code"])
        XCTAssertNil(encodedSession["device_secret"])
    }

    func testProviderExternalAuthContractsUseStableRedactedCamelCaseWireKeys() throws {
        let start = BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        )
        let status = BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth",
            flowID: "123E4567-E89B-12D3-A456-426614174000"
        )
        let cancel = BurnBarProviderExternalAuthFlowRequest(
            flowID: "123E4567-E89B-12D3-A456-426614174000"
        )
        let response = BurnBarProviderExternalAuthResponse(flow: BurnBarProviderExternalAuthFlowSnapshot(
            flowID: cancel.flowID,
            providerID: "openai",
            providerDisplayName: "OpenAI",
            authMethodID: "openai-codex-oauth",
            authMethodDisplayName: "Sign in with OpenAI / Codex",
            cliDisplayName: "Codex",
            state: .awaitingUser,
            availability: .available,
            cliInstalled: true,
            connected: false,
            accountDescription: "OpenAI account",
            startedAt: "2030-01-01T00:00:00Z",
            expiresAt: "2030-01-01T00:05:00Z",
            updatedAt: "2030-01-01T00:00:01Z"
        ))

        let encoder = JSONEncoder()
        let startJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(start)) as? [String: Any]
        )
        let statusJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(status)) as? [String: Any]
        )
        let cancelJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(cancel)) as? [String: Any]
        )
        let responseJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(response)) as? [String: Any]
        )
        let flowJSON = try XCTUnwrap(responseJSON["flow"] as? [String: Any])

        XCTAssertEqual(startJSON["providerID"] as? String, "openai")
        XCTAssertEqual(startJSON["authMethodID"] as? String, "openai-codex-oauth")
        XCTAssertEqual(statusJSON["flowID"] as? String, cancel.flowID)
        XCTAssertEqual(cancelJSON["flowID"] as? String, cancel.flowID)
        XCTAssertEqual(flowJSON["state"] as? String, "awaiting_user")
        XCTAssertEqual(flowJSON["availability"] as? String, "available")
        XCTAssertEqual(flowJSON["cliInstalled"] as? Bool, true)
        XCTAssertEqual(flowJSON["connected"] as? Bool, false)
        XCTAssertEqual(flowJSON["updatedAt"] as? String, "2030-01-01T00:00:01Z")

        let encodedText = String(decoding: try encoder.encode(response), as: UTF8.self).lowercased()
        for forbidden in ["accesstoken", "refreshtoken", "secret", "executablepath", "configdirectory", "stdout", "stderr", "command", "arguments"] {
            XCTAssertFalse(encodedText.contains(forbidden), "External-auth wire response leaked forbidden field: \(forbidden)")
        }
    }

    func testProviderExternalAuthStatusOmitsAbsentSelectorsAndEnumsRejectUnknownValues() throws {
        let status = BurnBarProviderExternalAuthStatusRequest(providerID: "anthropic")
        let data = try JSONEncoder().encode(status)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["providerID"] as? String, "anthropic")
        XCTAssertNil(json["authMethodID"])
        XCTAssertNil(json["flowID"])
        XCTAssertEqual(
            BurnBarProviderExternalAuthState.allCases.map(\.rawValue),
            ["idle", "launching", "awaiting_user", "verifying", "succeeded", "failed", "cancelled", "timed_out"]
        )
        XCTAssertEqual(
            BurnBarProviderExternalAuthAvailability.allCases.map(\.rawValue),
            ["available", "unavailable"]
        )
        XCTAssertEqual(
            BurnBarProviderExternalAuthProblemCode.allCases.map(\.rawValue),
            [
                "unsupported_provider",
                "unsupported_auth_method",
                "executable_not_found",
                "terminal_unavailable",
                "launch_failed",
                "process_failed",
                "verification_failed",
                "timeout",
                "cancelled",
                "another_flow_active",
                "daemon_restarted"
            ]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BurnBarProviderExternalAuthState.self,
                from: Data(#""future_state""#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BurnBarProviderExternalAuthProblemCode.self,
                from: Data(#""future_problem""#.utf8)
            )
        )
    }

    func testProviderExternalAuthCanonPinsTypedConfigOwnedMethods() throws {
        let expected: [String: (String, String)] = [
            "daemon.provider.external_auth.start": (
                "BurnBarProviderExternalAuthStartRequest",
                "BurnBarProviderExternalAuthResponse"
            ),
            "daemon.provider.external_auth.status": (
                "BurnBarProviderExternalAuthStatusRequest",
                "BurnBarProviderExternalAuthResponse"
            ),
            "daemon.provider.external_auth.cancel": (
                "BurnBarProviderExternalAuthFlowRequest",
                "BurnBarProviderExternalAuthResponse"
            )
        ]

        for (id, types) in expected {
            let entry = try XCTUnwrap(BurnBarRPCIPCCanon.methods.first(where: { $0.id == id }))
            XCTAssertEqual(entry.domain, "config")
            XCTAssertEqual(entry.capability, "config")
            XCTAssertEqual(entry.params, types.0)
            XCTAssertEqual(entry.result, types.1)
        }
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

    func testLinuxAppCheckStatusContractAndCanonAreRedactedAndTyped() throws {
        XCTAssertEqual(BurnBarRPCMethod.linuxAppCheckStatus.rawValue, "daemon.cloud.app_check.status")
        let status = BurnBarLinuxAppCheckStatusResponse(
            state: .ready,
            expiresAt: "2030-03-17T18:16:40Z"
        )
        let data = try JSONEncoder().encode(status)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("linux_lower_trust"))
        XCTAssertFalse(json.lowercased().contains("token"))

        let decoded = try JSONDecoder().decode(BurnBarLinuxAppCheckStatusResponse.self, from: data)
        XCTAssertEqual(decoded, status)

        let entry = try XCTUnwrap(
            BurnBarRPCIPCCanon.methods.first(where: { $0.id == "daemon.cloud.app_check.status" })
        )
        XCTAssertEqual(entry.domain, "account")
        XCTAssertEqual(entry.capability, "account")
        XCTAssertEqual(entry.params, "BurnBarRPCRequestEnvelope")
        XCTAssertEqual(entry.result, "BurnBarLinuxAppCheckStatusResponse")
    }
}
