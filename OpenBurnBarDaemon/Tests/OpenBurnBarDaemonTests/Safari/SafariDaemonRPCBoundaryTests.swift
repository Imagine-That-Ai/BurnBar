import Darwin
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class SafariDaemonRPCBoundaryTests: XCTestCase {
    func testSafariBootstrapCapabilityRequiresTheExactAttachedSession()
        async throws {
        let socketPath = socketPath(name: "bootstrap-attribution")
        let gateway = BurnBarGatewayConfiguration(
            isEnabled: true,
            host: "127.0.0.1",
            port: 8317,
            authToken: "gateway-attribution-test-token"
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: Self.authToken,
                daemonVersion: "safari-rpc-boundary-tests",
                gateway: gateway,
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        let unattached: BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(id: "bootstrap-unattached"),
                socketPath: socketPath
            )
        XCTAssertNil(unattached.error)
        XCTAssertEqual(unattached.result?.gatewayAvailable, true)
        XCTAssertEqual(
            unattached.result?.gatewayBearerToken,
            "gateway-attribution-test-token"
        )
        XCTAssertNil(unattached.result?.gatewayAttributionCapability)
        XCTAssertNil(unattached.result?.gatewayAttributionExpiresAt)

        let attached = try attachSafariSession(
            to: socketPath,
            extensionInstanceID: "bootstrap-attribution-extension",
            page: pageState()
        )
        let attachedBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-attached",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        XCTAssertNil(attachedBootstrap.error)
        let capability = try XCTUnwrap(
            attachedBootstrap.result?.gatewayAttributionCapability
        )
        XCTAssertNotNil(
            capability.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            )
        )
        let expiryRaw = try XCTUnwrap(
            attachedBootstrap.result?.gatewayAttributionExpiresAt
        )
        let expiryFormatter = ISO8601DateFormatter()
        expiryFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let expiry = try XCTUnwrap(expiryFormatter.date(from: expiryRaw))
        XCTAssertGreaterThan(expiry, Date())

        let detached: BurnBarRPCResponseEnvelope<BurnBarSafariCommandCompletionResponse> =
            try sendEnvelope(
                detachEnvelope(
                    id: "bootstrap-detach",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        XCTAssertNil(detached.error)
        XCTAssertEqual(detached.result?.accepted, true)

        let detachedBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-detached",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        assertRPCError(
            detachedBootstrap,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "detached or has been replaced"
        )

        let replacement = try attachSafariSession(
            to: socketPath,
            extensionInstanceID: "bootstrap-attribution-extension",
            page: pageState(url: "https://example.com/replacement")
        )
        XCTAssertNotEqual(replacement.sessionId, attached.sessionId)

        let replacedBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-replaced",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        assertRPCError(
            replacedBootstrap,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "detached or has been replaced"
        )

        let replacementBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-replacement",
                    sessionID: replacement.sessionId
                ),
                socketPath: socketPath
            )
        XCTAssertNil(replacementBootstrap.error)
        XCTAssertNotNil(
            replacementBootstrap.result?.gatewayAttributionCapability
        )
        XCTAssertNotEqual(
            replacementBootstrap.result?.gatewayAttributionCapability,
            capability
        )
    }

    func testSafariPayloadResolutionPreservesLegacyRequestsWithoutParams()
        async throws {
        let socketPath = socketPath(name: "legacy-no-params")
        let server = BurnBarDaemonServer(
            configuration: configuration(socketPath: socketPath)
        )

        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        let health: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelope(
                    id: "legacy-health",
                    method: .health,
                    authToken: Self.authToken
                ),
                socketPath: socketPath
            )

        XCTAssertNil(health.error)
        XCTAssertEqual(health.result?.ok, true)
        XCTAssertEqual(
            health.result?.protocolVersion,
            BurnBarProtocolVersion.current
        )
    }

    func testHandoffSocketRejectsStaleSubstitutedNavigatedAndDetachedPageIdentity()
        async throws {
        let root = temporaryRoot(name: "handoff-boundary")
        let socketPath = socketPath(name: "handoff")
        let packageRoot = root.appendingPathComponent("packages", isDirectory: true)
        let trustedExecutable = root.appendingPathComponent("trusted-codex")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: trustedExecutable,
            options: [.atomic]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: trustedExecutable.path
        )
        let handoffSupervisor = SafariRPCBoundaryHandoffSupervisor()
        let handoffService = BurnBarResumeService(
            logger: BurnBarDaemonLogger(category: "safari-rpc-boundary-tests"),
            safariHandoffRootURL: packageRoot,
            cliExecutableResolver: { cliType in
                cliType == .codex ? trustedExecutable : nil
            }
        )
        let server = BurnBarDaemonServer(
            configuration: configuration(socketPath: socketPath),
            safariHandoffSupervisor: handoffSupervisor,
            safariHandoffRootURL: packageRoot
        )
        await server.installSafariHandoffServiceForRPCBoundaryTests(
            handoffService
        )

        try await server.start()
        addTeardownBlock {
            await server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let livePage = pageState()
        let attached = try attachSafariSession(
            to: socketPath,
            extensionInstanceID: "handoff-extension",
            page: livePage
        )

        let stalePage = pageState(
            capturedAt: Date().addingTimeInterval(-121)
        )
        let stale: BurnBarRPCResponseEnvelope<BurnBarSafariHandoffResponse> =
            try sendEnvelope(
                handoffEnvelope(
                    id: "handoff-stale",
                    safariSessionID: attached.sessionId,
                    page: stalePage
                ),
                socketPath: socketPath
            )
        assertRPCError(
            stale,
            code: BurnBarRPCErrorCode.invalidParams,
            contains: "invalid, stale"
        )

        let crossTab: BurnBarRPCResponseEnvelope<BurnBarSafariHandoffResponse> =
            try sendEnvelope(
                handoffEnvelope(
                    id: "handoff-cross-tab",
                    safariSessionID: attached.sessionId,
                    page: pageState(tabID: livePage.tabId + 1)
                ),
                socketPath: socketPath
            )
        assertRPCError(
            crossTab,
            code: BurnBarRPCErrorCode.conflict,
            contains: "page changed"
        )

        let navigated: BurnBarRPCResponseEnvelope<BurnBarSafariHandoffResponse> =
            try sendEnvelope(
                handoffEnvelope(
                    id: "handoff-navigation-changed",
                    safariSessionID: attached.sessionId,
                    page: pageState(
                        url: "https://example.com/plans?revision=2",
                        navigationEpoch: livePage.navigationEpoch + 1
                    )
                ),
                socketPath: socketPath
            )
        assertRPCError(
            navigated,
            code: BurnBarRPCErrorCode.conflict,
            contains: "page changed"
        )
        let launchCountBeforeExactHandoff =
            await handoffSupervisor.launchCount
        XCTAssertEqual(launchCountBeforeExactHandoff, 0)

        let launched: BurnBarRPCResponseEnvelope<BurnBarSafariHandoffResponse> =
            try sendEnvelope(
                handoffEnvelope(
                    id: "handoff-exact",
                    safariSessionID: attached.sessionId,
                    page: livePage
                ),
                socketPath: socketPath
        )
        XCTAssertNil(launched.error)
        XCTAssertEqual(launched.result?.phase, .waitingOnCompanion)
        XCTAssertEqual(launched.result?.launched, true)
        XCTAssertEqual(launched.result?.running, true)
        let launchCountAfterExactHandoff =
            await handoffSupervisor.launchCount
        XCTAssertEqual(launchCountAfterExactHandoff, 1)
        let launch = await handoffSupervisor.firstLaunch
        XCTAssertEqual(launch?.executableURL.path, trustedExecutable.path)
        let launchedRunID = try XCTUnwrap(launched.result?.runId)
        XCTAssertEqual(
            launch?.packageDirectory.path,
            packageRoot.appendingPathComponent(launchedRunID).path
        )

        let detached: BurnBarRPCResponseEnvelope<BurnBarSafariCommandCompletionResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "handoff-detach",
                    method: .safariSessionDetach,
                    authToken: Self.authToken,
                    params: BurnBarSafariSessionDetachRequest(
                        sessionId: attached.sessionId,
                        reason: "test_detach"
                    )
                ),
                socketPath: socketPath
            )
        XCTAssertNil(detached.error)
        XCTAssertEqual(detached.result?.accepted, true)

        let afterDetach: BurnBarRPCResponseEnvelope<BurnBarSafariHandoffResponse> =
            try sendEnvelope(
                handoffEnvelope(
                    id: "handoff-after-detach",
                    safariSessionID: attached.sessionId,
                    page: livePage
                ),
                socketPath: socketPath
            )
        assertRPCError(
            afterDetach,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "detached or has been replaced"
        )
        let launchCountAfterDetach =
            await handoffSupervisor.launchCount
        XCTAssertEqual(launchCountAfterDetach, 1)
    }

    func testApprovalSocketConsumesOnlyTheExactLiveSafariBindingOnce()
        async throws {
        let harness = try await makeApprovalHarness()
        try await harness.server.start()
        addTeardownBlock {
            await harness.server.stop()
            try? FileManager.default.removeItem(at: harness.root)
        }

        let livePage = pageState()
        let primary = try attachSafariSession(
            to: harness.socketPath,
            extensionInstanceID: "approval-primary",
            page: livePage
        )
        let other = try attachSafariSession(
            to: harness.socketPath,
            extensionInstanceID: "approval-other",
            page: pageState(
                tabID: livePage.tabId + 100,
                url: "https://example.com/other",
                navigationEpoch: 1
            )
        )
        let clientID = BurnBarClientID(
            rawValue: "safari-extension:\(primary.sessionId)"
        )
        let daemonSessionID = BurnBarSessionID(rawValue: primary.sessionId)

        let created: BurnBarRPCResponseEnvelope<BurnBarRunCreateResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "approval-run-create",
                    method: .runCreate,
                    authToken: Self.authToken,
                    params: BurnBarRunCreateRequest(
                        clientID: clientID,
                        sessionID: daemonSessionID,
                        prompt: "Select the visible plan",
                        modelID: "glm-5",
                        metadata: [
                            "toolKind": .string(BurnBarToolKind.safariClick.rawValue),
                            "toolArguments": .object([
                                "safariSessionId": .string(primary.sessionId),
                                "selector": .string("#select-plan")
                            ])
                        ]
                    )
                ),
                socketPath: harness.socketPath
            )
        XCTAssertNil(created.error)
        XCTAssertEqual(created.result?.phase, .awaitingComputerUseSession)
        let runID = try XCTUnwrap(created.result?.runID)

        let reconciled: BurnBarRPCResponseEnvelope<BurnBarSafariCommandPollResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "approval-reconcile",
                    method: .safariCommandPoll,
                    authToken: Self.authToken,
                    params: BurnBarSafariCommandPollRequest(
                        sessionId: primary.sessionId,
                        activePage: livePage,
                        knownTabs: [tabSnapshot(livePage)]
                    )
                ),
                socketPath: harness.socketPath
            )
        XCTAssertNil(reconciled.error)

        let evidenceCommand = try await waitForSafariCommand(
            idPrefix: "approval-evidence",
            safariSessionID: primary.sessionId,
            page: livePage,
            socketPath: harness.socketPath
        )
        XCTAssertEqual(evidenceCommand.action, .screenshot)
        XCTAssertEqual(evidenceCommand.targetTabId, livePage.tabId)

        let evidenceCompleted:
            BurnBarRPCResponseEnvelope<BurnBarSafariCommandCompletionResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "approval-evidence-complete",
                    method: .safariCommandComplete,
                    authToken: Self.authToken,
                    params: BurnBarSafariCommandCompletionRequest(
                        sessionId: primary.sessionId,
                        commandId: evidenceCommand.commandId,
                        ok: true,
                        result: .object([
                            "base64": .string(Self.minimumJPEG.base64EncodedString()),
                            "mimeType": .string("image/jpeg"),
                            "sizeBytes": .number(Double(Self.minimumJPEG.count))
                        ]),
                        pageState: livePage,
                        tabs: [tabSnapshot(livePage)]
                    )
                ),
                socketPath: harness.socketPath
            )
        XCTAssertNil(evidenceCompleted.error)
        XCTAssertEqual(evidenceCompleted.result?.accepted, true)

        let pending = try await waitForPendingApproval(
            safariSessionID: primary.sessionId,
            runID: runID,
            service: harness.computerUseService,
            runService: harness.runService
        )
        XCTAssertEqual(pending.approval.runId, runID.rawValue)
        XCTAssertEqual(pending.approval.sessionId, pending.computerUseSessionID.rawValue)
        XCTAssertEqual(pending.approval.toolKind, BurnBarToolKind.safariClick.rawValue)

        let substituted: BurnBarRPCResponseEnvelope<BurnBarSafariApprovalRespondResponse> =
            try sendEnvelope(
                approvalEnvelope(
                    id: "approval-substituted",
                    safariSessionID: primary.sessionId,
                    approvalID: "stale-\(pending.approval.approvalId)"
                ),
                socketPath: harness.socketPath
            )
        assertRPCError(
            substituted,
            code: BurnBarRPCErrorCode.conflict,
            contains: "stale, already resolved"
        )

        let crossSession: BurnBarRPCResponseEnvelope<BurnBarSafariApprovalRespondResponse> =
            try sendEnvelope(
                approvalEnvelope(
                    id: "approval-cross-session",
                    safariSessionID: other.sessionId,
                    approvalID: pending.approval.approvalId
                ),
                socketPath: harness.socketPath
            )
        assertRPCError(
            crossSession,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "no live Computer Use approval binding"
        )

        let accepted: BurnBarRPCResponseEnvelope<BurnBarSafariApprovalRespondResponse> =
            try sendEnvelope(
                approvalEnvelope(
                    id: "approval-exact",
                    safariSessionID: primary.sessionId,
                    approvalID: pending.approval.approvalId
                ),
                socketPath: harness.socketPath
            )
        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.result?.accepted, true)
        XCTAssertEqual(accepted.result?.approvalId, pending.approval.approvalId)
        XCTAssertEqual(accepted.result?.runId, runID.rawValue)

        let replayed: BurnBarRPCResponseEnvelope<BurnBarSafariApprovalRespondResponse> =
            try sendEnvelope(
                approvalEnvelope(
                    id: "approval-replay",
                    safariSessionID: primary.sessionId,
                    approvalID: pending.approval.approvalId
                ),
                socketPath: harness.socketPath
            )
        assertRPCError(
            replayed,
            code: BurnBarRPCErrorCode.conflict,
            contains: "stale, already resolved"
        )

        let aborted: BurnBarRPCResponseEnvelope<BurnBarSafariToolResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "approval-abort",
                    method: .safariAbort,
                    authToken: Self.authToken,
                    params: BurnBarSafariToolRequest(
                        safariSessionId: primary.sessionId,
                        computerUseSessionId: pending.computerUseSessionID.rawValue,
                        runId: runID.rawValue,
                        tabId: livePage.tabId,
                        expectedNavigationEpoch: livePage.navigationEpoch
                    )
                ),
                socketPath: harness.socketPath
            )
        XCTAssertNil(aborted.error)
        XCTAssertEqual(aborted.result?.ok, true)

        let afterAbort: BurnBarRPCResponseEnvelope<BurnBarSafariApprovalRespondResponse> =
            try sendEnvelope(
                approvalEnvelope(
                    id: "approval-after-abort",
                    safariSessionID: primary.sessionId,
                    approvalID: pending.approval.approvalId
                ),
                socketPath: harness.socketPath
            )
        assertRPCError(
            afterAbort,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "lease is no longer active"
        )
    }

    func testInvalidOpenTabCompletionErrorMapsToInvalidParams() async throws {
        let server = BurnBarDaemonServer(
            configuration: configuration(
                socketPath: socketPath(name: "invalid-open-tab-error")
            )
        )
        let data = await server.safariRPCErrorResponse(
            id: "invalid-open-tab-error",
            error: BurnBarSafariSessionBroker.BrokerError.invalidOpenTabResult
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarSafariCommandCompletionResponse>.self,
            from: data
        )

        assertRPCError(
            response,
            code: BurnBarRPCErrorCode.invalidParams,
            contains: "unambiguous newly opened tab"
        )
    }

    private static let authToken = "safari-rpc-boundary-token"
    private static let minimumJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func makeApprovalHarness() async throws -> SafariApprovalRPCHarness {
        let root = temporaryRoot(name: "approval-boundary")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let socketPath = socketPath(name: "approval")
        let safariBroker = BurnBarSafariSessionBroker()
        let authorizationRegistry = ComputerUseAuthorizationRegistry(
            enforcementEnabled: false
        )
        let capabilityStateStore = try await activeCapabilityStateStore(at: root)
        let computerUseService = ComputerUseService(
            auditBaseDirectory: root.appendingPathComponent(
                "computer-use-audit",
                isDirectory: true
            ),
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: { _ in nil },
            computerUseKillSwitchEnabled: { false },
            privilegedInputKillSwitchActivator: { _ in },
            safariSessionBroker: safariBroker,
            authorizationRegistry: authorizationRegistry,
            requiresManagedBrowserRunAuthority: true,
            logger: BurnBarDaemonLogger(category: "safari-rpc-boundary-tests")
        )
        let clientRegistry = BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "safari-rpc-boundary-tests")
        )
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "safari-rpc-boundary-tests")
        )
        try await configStore.setSecret("zai-test-secret", for: "zai")
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        let usageRecorder = BurnBarUsageRecorder(
            fileURL: root.appendingPathComponent("usage.jsonl"),
            logger: BurnBarDaemonLogger(category: "safari-rpc-boundary-tests")
        )
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(
                    category: "safari-rpc-boundary-tests"
                )
            ),
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            providerExecutor: SafariRPCBoundaryProviderExecutor(),
            runJournal: BurnBarRunJournal(
                fileURL: root.appendingPathComponent("run-journal.jsonl"),
                checkpointsDirectoryURL: root.appendingPathComponent(
                    "run-checkpoints",
                    isDirectory: true
                ),
                logger: BurnBarDaemonLogger(
                    category: "safari-rpc-boundary-tests"
                )
            ),
            safariComputerUseRunDispatcher: { requirement in
                guard await clientRegistry.sessionID(
                    for: requirement.clientID
                ) == requirement.sessionID else {
                    throw ComputerUseService.ServiceError.clientIdentityMismatch(
                        expected: requirement.sessionID.rawValue,
                        actual: await clientRegistry.sessionID(
                            for: requirement.clientID
                        )?.rawValue ?? "detached"
                    )
                }
                return try await computerUseService.invokeForSafariRun(
                    requirement
                )
            },
            safariComputerUseRunBindingChecker: { requirement in
                guard await clientRegistry.sessionID(
                    for: requirement.clientID
                ) == requirement.sessionID else {
                    return false
                }
                return await computerUseService.safariRunBindingSessionID(
                    requirement
                ) != nil
            },
            safariComputerUseRunRevoker: { requirement in
                guard await clientRegistry.sessionID(
                    for: requirement.clientID
                ) == requirement.sessionID else {
                    return
                }
                await computerUseService.revokeSafariRun(requirement)
            },
            logger: BurnBarDaemonLogger(category: "safari-rpc-boundary-tests")
        )
        let trustStore = BurnBarSafariTrustStore(
            fileURL: root.appendingPathComponent("safari-trust.json")
        )
        let server = BurnBarDaemonServer(
            configuration: configuration(socketPath: socketPath),
            configStore: configStore,
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            runService: runService,
            computerUseService: computerUseService,
            computerUseAuthorizationRegistry: authorizationRegistry,
            safariSessionBroker: safariBroker,
            safariTrustStore: trustStore
        )
        return SafariApprovalRPCHarness(
            root: root,
            socketPath: socketPath,
            server: server,
            computerUseService: computerUseService,
            runService: runService
        )
    }

    private func activeCapabilityStateStore(
        at root: URL
    ) async throws -> ComputerUseCapabilityStateStore {
        let now = Date()
        let store = ComputerUseCapabilityStateStore(
            fileURL: root.appendingPathComponent("capability-state.json"),
            now: { now }
        )
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: now,
            updatedAt: now
        )
        _ = try await store.update(
            ComputerUseCapabilityStateSnapshot(
                publisherInstanceID: "safari-rpc-boundary-tests",
                revision: 1,
                generatedAt: now,
                userID: "safari-rpc-test-user",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: ComputerUseEntitlementSnapshot.hostedProductID,
                    expireAt: now.addingTimeInterval(3_600),
                    allowsBrowser: true,
                    allowsSystem: true,
                    allowsPhoneControl: true,
                    allowsTrustedScopes: true,
                    allowsAuditExport: true
                ),
                entitlementProvenance: provenance,
                budgetEnvelope: ComputerUseBudgetEnvelope(
                    level: .normal,
                    projectedMonthEndUSD: 0,
                    monthToDateUSD: 0,
                    activeActionsPerRun: 50,
                    activeActionsPerDay: 200,
                    activeSessionsPerDay: 4,
                    perUserDailySpendCeilingUSD: 5,
                    updatedAt: now
                ),
                budgetProvenance: provenance,
                quotaUsage: ComputerUseQuotaUsage(
                    dayKey: String(
                        ISO8601DateFormatter().string(from: now).prefix(10)
                    ),
                    updatedAt: now
                ),
                quotaProvenance: provenance,
                concurrentSessionActive: false,
                killSwitch: false,
                isComplete: true
            )
        )
        return store
    }

    private func waitForPendingApproval(
        safariSessionID: String,
        runID: BurnBarRunID,
        service: ComputerUseService,
        runService: BurnBarRunService
    ) async throws -> PendingSafariApproval {
        for _ in 0..<500 {
            if let computerUseSessionID = await service.computerUseSessionID(
                forSafariSessionID: safariSessionID
            ) {
                let pending = await service.pendingApprovals(
                    ComputerUseApprovalPendingRequest(
                        sessionId: computerUseSessionID.rawValue
                    )
                )
                if let approval = pending.requests.first {
                    return PendingSafariApproval(
                        computerUseSessionID: computerUseSessionID,
                        approval: approval
                    )
                }
            }
            if let snapshot = await runService.snapshot(for: runID),
               [.completed, .failed, .cancelled].contains(snapshot.phase) {
                throw SafariRPCBoundaryTestError.approvalUnavailable(
                    "run \(runID.rawValue) became \(snapshot.phase.rawValue): "
                        + (snapshot.errorMessage ?? "no error message")
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await runService.snapshot(for: runID)
        throw SafariRPCBoundaryTestError.approvalUnavailable(
            "timed out with run phase \(snapshot?.phase.rawValue ?? "missing"): "
                + (snapshot?.errorMessage ?? "no error message")
        )
    }

    private func waitForSafariCommand(
        idPrefix: String,
        safariSessionID: String,
        page: BurnBarSafariPageState,
        socketPath: String
    ) async throws -> BurnBarSafariCommand {
        for attempt in 0..<500 {
            let response: BurnBarRPCResponseEnvelope<BurnBarSafariCommandPollResponse> =
                try sendEnvelope(
                    BurnBarRPCRequestEnvelopeWithParams(
                        id: "\(idPrefix)-\(attempt)",
                        method: .safariCommandPoll,
                        authToken: Self.authToken,
                        params: BurnBarSafariCommandPollRequest(
                            sessionId: safariSessionID,
                            activePage: page,
                            knownTabs: [tabSnapshot(page)]
                        )
                    ),
                    socketPath: socketPath
                )
            if let error = response.error {
                throw SafariRPCBoundaryTestError.commandUnavailable(
                    "poll failed with \(error.code): \(error.message)"
                )
            }
            if let command = response.result?.command {
                return command
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SafariRPCBoundaryTestError.commandUnavailable(
            "timed out waiting for the Safari evidence command"
        )
    }

    private func attachSafariSession(
        to socketPath: String,
        extensionInstanceID: String,
        page: BurnBarSafariPageState
    ) throws -> BurnBarSafariSessionAttachResponse {
        let response: BurnBarRPCResponseEnvelope<BurnBarSafariSessionAttachResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "attach-\(extensionInstanceID)",
                    method: .safariSessionAttach,
                    authToken: Self.authToken,
                    params: BurnBarSafariSessionAttachRequest(
                        extensionInstanceId: extensionInstanceID,
                        clientName: "Safari RPC Boundary Tests",
                        activePage: page,
                        capabilities: safariCapabilities()
                    )
                ),
                socketPath: socketPath
            )
        XCTAssertNil(response.error)
        return try XCTUnwrap(response.result)
    }

    private func bootstrapEnvelope(
        id: String,
        sessionID: String? = nil
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariBootstrapRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariBootstrap,
            authToken: Self.authToken,
            params: BurnBarSafariBootstrapRequest(sessionId: sessionID)
        )
    }

    private func detachEnvelope(
        id: String,
        sessionID: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariSessionDetachRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariSessionDetach,
            authToken: Self.authToken,
            params: BurnBarSafariSessionDetachRequest(
                sessionId: sessionID,
                reason: "bootstrap_attribution_test"
            )
        )
    }

    private func handoffEnvelope(
        id: String,
        safariSessionID: String,
        page: BurnBarSafariPageState
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariHandoffRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariHandoff,
            authToken: Self.authToken,
            params: BurnBarSafariHandoffRequest(
                safariSessionId: safariSessionID,
                targetHarness: "codex",
                prompt: "Compare the visible plans.",
                pageState: page,
                readableMarkdown: "# Plans\n\nChoose one.",
                accessibilitySnapshot:
                    #"[ref=obb-1] [role=button] [name="Choose"]"#,
                screenshotJPEG: Self.minimumJPEG,
                screenshotWidth: 1024,
                screenshotHeight: 768,
                screenshotTruncated: false
            )
        )
    }

    private func approvalEnvelope(
        id: String,
        safariSessionID: String,
        approvalID: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariApprovalRespondRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariApprovalRespond,
            authToken: Self.authToken,
            params: BurnBarSafariApprovalRespondRequest(
                safariSessionId: safariSessionID,
                approvalId: approvalID,
                decision: .allowOnce
            )
        )
    }

    private func pageState(
        tabID: Int = 7,
        url: String = "https://example.com/plans",
        navigationEpoch: Int = 11,
        capturedAt: Date = Date()
    ) -> BurnBarSafariPageState {
        BurnBarSafariPageState(
            tabId: tabID,
            windowId: 3,
            url: url,
            title: "Plans",
            navigationEpoch: navigationEpoch,
            isActive: true,
            isTopFrame: true,
            capturedAt: capturedAt
        )
    }

    private func tabSnapshot(
        _ page: BurnBarSafariPageState
    ) -> BurnBarSafariTabSnapshot {
        BurnBarSafariTabSnapshot(
            tabId: page.tabId,
            windowId: page.windowId,
            url: page.url,
            title: page.title,
            isActive: page.isActive,
            isOwned: true,
            navigationEpoch: page.navigationEpoch
        )
    }

    private func safariCapabilities() -> BurnBarSafariExtensionCapabilities {
        BurnBarSafariExtensionCapabilities(
            captureVisibleTab: true,
            scripting: true,
            nativeMessaging: true,
            activeTabPermission: true,
            siteAccessGranted: true
        )
    }

    private func configuration(
        socketPath: String
    ) -> BurnBarDaemonConfiguration {
        BurnBarDaemonConfiguration(
            socketPath: socketPath,
            socketAuthToken: Self.authToken,
            daemonVersion: "safari-rpc-boundary-tests",
            startsMissionControlBackgroundLoops: false
        )
    }

    private func temporaryRoot(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-safari-rpc-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func socketPath(name: String) -> String {
        let nonce = String(UUID().uuidString.prefix(8))
        return "/tmp/obb-safari-\(name)-\(nonce).sock"
    }

    private func assertRPCError<Result>(
        _ response: BurnBarRPCResponseEnvelope<Result>,
        code: Int,
        contains messageFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) where Result: Codable & Sendable {
        XCTAssertNil(response.result, file: file, line: line)
        XCTAssertEqual(response.error?.code, code, file: file, line: line)
        XCTAssertEqual(
            response.error?.message.contains(messageFragment),
            true,
            "Expected RPC error message to contain '\(messageFragment)', got '\(response.error?.message ?? "nil")'.",
            file: file,
            line: line
        )
    }

    private func sendEnvelope<Envelope, Response>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response>
    where Envelope: Encodable, Response: Codable & Sendable {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { reboundPointer in
                connect(
                    fileDescriptor,
                    reboundPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.stride)
                )
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytesRemaining
                )
                guard bytesWritten > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while response.last != 0x0A {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard bytesRead > 0 else { break }
            response.append(contentsOf: buffer.prefix(bytesRead))
        }
        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<Response>.self,
            from: response
        )
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }
}

private struct SafariApprovalRPCHarness {
    let root: URL
    let socketPath: String
    let server: BurnBarDaemonServer
    let computerUseService: ComputerUseService
    let runService: BurnBarRunService
}

private struct PendingSafariApproval {
    let computerUseSessionID: ComputerUseSessionID
    let approval: HermesRealtimeRelayApprovalRequest
}

private enum SafariRPCBoundaryTestError: Error, LocalizedError {
    case approvalUnavailable(String)
    case commandUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .approvalUnavailable(let detail):
            return "Safari approval did not become pending: \(detail)"
        case .commandUnavailable(let detail):
            return "Safari command did not become available: \(detail)"
        }
    }
}

private actor SafariRPCBoundaryHandoffSupervisor:
    SafariHandoffProcessSupervising {
    private var launches:
        [SafariHandoffProcessSupervisor.LaunchSpecification] = []
    private var observations:
        [BurnBarRunID: SafariHandoffProcessSupervisor.Observation] = [:]

    var launchCount: Int { launches.count }
    var firstLaunch: SafariHandoffProcessSupervisor.LaunchSpecification? {
        launches.first
    }

    func launch(
        _ specification: SafariHandoffProcessSupervisor.LaunchSpecification
    ) async throws -> SafariHandoffProcessSupervisor.Observation {
        launches.append(specification)
        let launchedAt = Date()
        let observation = SafariHandoffProcessSupervisor.Observation(
            runID: specification.runID,
            targetHarness: specification.targetHarness,
            state: .running,
            launchedAt: launchedAt,
            observedAt: launchedAt,
            completedAt: nil,
            terminationReason: nil,
            exitStatus: nil,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: nil,
            packageDirectory: specification.packageDirectory
        )
        observations[specification.runID] = observation
        return observation
    }

    func observation(
        for runID: BurnBarRunID
    ) async -> SafariHandoffProcessSupervisor.Observation? {
        observations[runID]
    }

    func cancel(
        runID: BurnBarRunID
    ) async -> SafariHandoffProcessSupervisor.Observation? {
        guard let current = observations[runID] else { return nil }
        let cancelled = SafariHandoffProcessSupervisor.Observation(
            runID: runID,
            targetHarness: current.targetHarness,
            state: .cancelled,
            launchedAt: current.launchedAt,
            observedAt: Date(),
            completedAt: Date(),
            terminationReason: .cancelled,
            exitStatus: 15,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: nil,
            packageDirectory: current.packageDirectory
        )
        observations[runID] = cancelled
        return cancelled
    }

    func registerInterruptedRun(
        runID: BurnBarRunID,
        targetHarness: String,
        packageDirectory: URL,
        expectedPackageIdentity:
            SafariHandoffProcessSupervisor.FilesystemIdentity?,
        launchedAt: Date
    ) async -> SafariHandoffProcessSupervisor.Observation {
        if let current = observations[runID] { return current }
        let interrupted = SafariHandoffProcessSupervisor.Observation(
            runID: runID,
            targetHarness: targetHarness,
            state: .interrupted,
            launchedAt: launchedAt,
            observedAt: Date(),
            completedAt: Date(),
            terminationReason: .interrupted,
            exitStatus: nil,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: .interrupted,
            packageDirectory: packageDirectory
        )
        observations[runID] = interrupted
        return interrupted
    }

    func cleanupEligiblePackages(now: Date) async {}

    func discard(runID: BurnBarRunID) async {
        observations.removeValue(forKey: runID)
    }

    func shutdownAll() async {
        for runID in observations.keys {
            _ = await cancel(runID: runID)
        }
    }
}

private struct SafariRPCBoundaryProviderExecutor: BurnBarProviderExecuting {
    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        BurnBarProviderExecutionResult(
            outputText:
                #"{"action":"complete","rationale":"Safari RPC boundary test completed.","message":"done"}"#,
            inputTokens: max(1, request.userPrompt.count / 4),
            outputTokens: 1,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

private extension BurnBarDaemonServer {
    func installSafariHandoffServiceForRPCBoundaryTests(
        _ service: BurnBarResumeService
    ) {
        safariHandoffService = service
    }
}
