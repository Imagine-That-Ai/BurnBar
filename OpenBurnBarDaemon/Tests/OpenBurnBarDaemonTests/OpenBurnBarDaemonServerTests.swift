import OpenBurnBarEngine
import OpenBurnBarInsights
@testable import OpenBurnBarDaemon
import Darwin
import Foundation
import SQLite3
import XCTest

final class BurnBarDaemonServerTests: XCTestCase {
    func testDaemonBootsRespondsToHealthAndCleansUpSocketOnShutdown() async throws {
        let socketPath = makeSocketPath(name: "health")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                daemonVersion: "test-daemon",
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertEqual(socketPermissions(at: socketPath), 0o600)

        let response: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "health-1", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )

        XCTAssertEqual(response.id, "health-1")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.ok, true)
        XCTAssertEqual(response.result?.daemonVersion, "test-daemon")
        XCTAssertEqual(response.result?.socketPath, socketPath)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testLinuxOnboardingSnapshotActionAndResetRoundTripOverSocket() async throws {
        let socketPath = makeSocketPath(name: "linux-onboarding")
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-onboarding-rpc-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let onboardingService = BurnBarLinuxOnboardingService(
            stateURL: stateURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            daemonProbe: { "daemon RPC verified" },
            secretStoreProbe: { "secret store verified" },
            providerPathsProbe: { "provider paths verified" }
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            linuxOnboardingService: onboardingService
        )

        try await server.start()
        addTeardownBlock { await server.stop() }

        let initial: BurnBarRPCResponseEnvelope<BurnBarLinuxOnboardingSnapshot> = try sendRequest(
            BurnBarRPCRequestEnvelope(
                id: "onboarding-snapshot",
                method: .linuxOnboardingSnapshot,
                authToken: "test-token"
            ),
            socketPath: socketPath
        )
        XCTAssertNil(initial.error)
        XCTAssertEqual(initial.result?.currentStepID, .daemon)

        let action: BurnBarRPCResponseEnvelope<BurnBarLinuxOnboardingSnapshot> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "onboarding-action",
                method: .linuxOnboardingAction,
                authToken: "test-token",
                params: BurnBarLinuxOnboardingActionRequest(stepID: .daemon, action: .verify)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(action.error)
        XCTAssertEqual(action.result?.currentStepID, .secretStore)
        XCTAssertEqual(action.result?.steps.first?.state, .verified)

        let reset: BurnBarRPCResponseEnvelope<BurnBarLinuxOnboardingSnapshot> = try sendRequest(
            BurnBarRPCRequestEnvelope(
                id: "onboarding-reset",
                method: .linuxOnboardingReset,
                authToken: "test-token"
            ),
            socketPath: socketPath
        )
        XCTAssertNil(reset.error)
        XCTAssertEqual(reset.result?.currentStepID, .daemon)
        XCTAssertEqual(reset.result?.steps.allSatisfy { $0.state == .pending }, true)
    }

    func testSubscriptionStartResumeAndStopRoundTripOverSocket() async throws {
        let socketPath = makeSocketPath(name: "subscription")
        let subscriptionService = BurnBarSubscriptionService(
            daemonVersion: "test-daemon",
            daemonSessionID: "socket-daemon-session"
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                daemonVersion: "test-daemon",
                startsMissionControlBackgroundLoops: false
            ),
            subscriptionService: subscriptionService
        )

        try await server.start()
        addTeardownBlock { await server.stop() }

        let started: BurnBarRPCResponseEnvelope<BurnBarSubscriptionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-start",
                method: .subscriptionStart,
                authToken: "test-token",
                params: BurnBarSubscriptionStartRequest(
                    topic: "data",
                    requestedSubscriptionID: "linux-desktop-data",
                    clientID: "linux-desktop"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(started.error)
        XCTAssertEqual(started.result?.seq, 1)
        XCTAssertEqual(started.result?.events.first?.snapshot["daemon_session_id"], "socket-daemon-session")
        XCTAssertEqual(started.result?.terminalStateDelivered, false)

        let duplicate: BurnBarRPCResponseEnvelope<BurnBarEmptyResult> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-duplicate",
                method: .subscriptionStart,
                authToken: "test-token",
                params: BurnBarSubscriptionStartRequest(
                    topic: "data",
                    requestedSubscriptionID: "linux-desktop-data",
                    clientID: "linux-desktop"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(duplicate.id, "subscription-duplicate")
        XCTAssertEqual(duplicate.error?.code, BurnBarRPCErrorCode.invalidParams)

        let resumed: BurnBarRPCResponseEnvelope<BurnBarSubscriptionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-resume",
                method: .subscriptionResume,
                authToken: "test-token",
                params: BurnBarSubscriptionResumeRequest(
                    subscriptionID: "linux-desktop-data",
                    topic: "data",
                    afterSeq: 1,
                    clientID: "linux-desktop"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(resumed.error)
        XCTAssertEqual(resumed.result?.seq, 2)
        XCTAssertEqual(resumed.result?.events.first?.kind, "data.tick")

        let stopped: BurnBarRPCResponseEnvelope<BurnBarSubscriptionStopResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "subscription-stop",
                method: .subscriptionStop,
                authToken: "test-token",
                params: BurnBarSubscriptionStopRequest(
                    subscriptionID: "linux-desktop-data",
                    clientID: "linux-desktop"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(stopped.error)
        XCTAssertEqual(stopped.result?.stopped, true)
        XCTAssertEqual(stopped.result?.lastSeq, 2)
    }

    func testDaemonRemovesStaleSocketBeforeBinding() async throws {
        let socketPath = makeSocketPath(name: "stale")
        let staleSocket = try makeStaleSocket(at: socketPath)
        close(staleSocket)

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
        try await server.start()

        let response: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "health-2", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )

        XCTAssertEqual(response.result?.ok, true)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testCatalogResponseUsesBundledCatalogAndCurrentProtocolVersion() async throws {
        let socketPath = makeSocketPath(name: "catalog")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                daemonVersion: "catalog-daemon",
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()

        let response: BurnBarRPCResponseEnvelope<BurnBarCatalogResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "catalog-1", method: .catalog, authToken: "test-token"),
            socketPath: socketPath
        )

        XCTAssertEqual(response.id, "catalog-1")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.catalog, BurnBarCatalogLoader.bundledCatalog)

        await server.stop()
    }

    func testProviderCredentialSlotUpsertRPCWritesDaemonReadableSecret() async throws {
        let socketPath = makeSocketPath(name: "provider-slot")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-provider-slot-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            configStore: configStore
        )

        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarProviderCredentialSlotMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "slot-upsert",
                method: .providerCredentialSlotUpsert,
                authToken: "test-token",
                params: BurnBarProviderCredentialSlotUpsertRequest(
                    providerID: "anthropic",
                    slotID: "icloud",
                    label: "iCloud",
                    apiKey: "oauth-test-token",
                    isEnabled: true
                )
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.slot?.slotID, "icloud")
        XCTAssertEqual(response.result?.snapshot.providerSettings(id: "anthropic")?.preferredCredentialSlotID, "icloud")

        let resolved = try await configStore.resolvedConfiguration(for: "anthropic")
        XCTAssertEqual(resolved.credentialSlots.first?.apiKey, "oauth-test-token")

        let removeResponse: BurnBarRPCResponseEnvelope<BurnBarProviderCredentialSlotMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "slot-remove",
                method: .providerCredentialSlotRemove,
                authToken: "test-token",
                params: BurnBarProviderCredentialSlotRemoveRequest(providerID: "anthropic", slotID: "icloud")
            ),
            socketPath: socketPath
        )

        XCTAssertNil(removeResponse.error)
        let removed = try await configStore.resolvedConfiguration(for: "anthropic")
        XCTAssertTrue(removed.credentialSlots.isEmpty)
    }

    func testDaemonSocketAuthRequiresMatchingToken() async throws {
        let socketPath = makeSocketPath(name: "socket-auth")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "socket-secret",
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()

        let unauthorizedResponse: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "unauthorized-health", method: .health),
            socketPath: socketPath
        )
        XCTAssertNil(unauthorizedResponse.result)
        XCTAssertEqual(unauthorizedResponse.error?.code, -32001)
        XCTAssertEqual(unauthorizedResponse.error?.message, "Unauthorized OpenBurnBar RPC request.")

        let authorizedResponse: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "authorized-health", method: .health, authToken: "socket-secret"),
            socketPath: socketPath
        )
        XCTAssertEqual(authorizedResponse.result?.ok, true)
        XCTAssertNil(authorizedResponse.error)

        await server.stop()
    }

    func testServerExposesRunConfigAndUsageRPCs() async throws {
        let socketPath = makeSocketPath(name: "run-rpc")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-server-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        try await configStore.setSecret("zai-secret", for: "zai")
        let usageRecorder = BurnBarUsageRecorder(
            fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let runJournal = BurnBarRunJournal(
            fileURL: rootURL.appendingPathComponent("run-journal.jsonl"),
            checkpointsDirectoryURL: rootURL.appendingPathComponent("run-checkpoints", isDirectory: true),
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let clientRegistry = BurnBarClientRegistry(logger: BurnBarDaemonLogger(category: "server-tests"))
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(configStore: configStore, logger: BurnBarDaemonLogger(category: "server-tests")),
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            runJournal: runJournal,
            logger: BurnBarDaemonLogger(category: "server-tests")
        )

        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            configStore: configStore,
            usageRecorder: usageRecorder,
            clientRegistry: clientRegistry,
            runService: runService
        )

        try await server.start()

        let clientID = BurnBarClientID(rawValue: "rpc-client")
        let sessionID = BurnBarSessionID(rawValue: "rpc-session")

        let attachResponse: BurnBarRPCResponseEnvelope<BurnBarClientAttachResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "attach-1",
                method: .clientAttach,
                authToken: "test-token",
                params: BurnBarClientAttachRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    clientName: "RPC Client",
                    supportedProtocolVersions: BurnBarProtocolVersion.supported
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(attachResponse.result?.attachedClientID, clientID)
        XCTAssertEqual(attachResponse.result?.negotiatedProtocolVersion, BurnBarProtocolVersion.current)

        let updatedSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "zai",
                    isEnabled: true,
                    baseURL: "https://api.z.ai/api/coding/paas/v4",
                    preferredModelIDs: ["glm-5"]
                ),
                BurnBarProviderSettings(
                    providerID: "minimax",
                    isEnabled: false,
                    baseURL: "https://api.minimax.io/v1",
                    preferredModelIDs: ["minimax-m2.7-highspeed"]
                )
            ]
        )
        let configUpdateResponse: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "config-update-1",
                method: .configUpdate,
                authToken: "test-token",
                params: BurnBarConfigUpdateRequest(snapshot: updatedSnapshot)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(configUpdateResponse.result?.snapshot.providerSettings(id: "zai")?.isEnabled, true)

        let createResponse: BurnBarRPCResponseEnvelope<BurnBarRunCreateResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-create-1",
                method: .runCreate,
                authToken: "test-token",
                params: BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: "Need approval",
                    modelID: "glm-5",
                    metadata: [
                        "requiresApproval": .bool(true),
                        "toolKind": .string(BurnBarToolKind.applyPatch.rawValue)
                    ]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(createResponse.result?.phase, .awaitingApproval)

        let runID = try XCTUnwrap(createResponse.result?.runID)
        let runDetailResponse: BurnBarRPCResponseEnvelope<BurnBarRunDetailResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-get-1",
                method: .runGet,
                authToken: "test-token",
                params: BurnBarRunGetRequest(runID: runID, clientID: clientID)
            ),
            socketPath: socketPath
        )
        let approvalID = try XCTUnwrap(runDetailResponse.result?.approvalRequest?.approvalID)
        XCTAssertEqual(runDetailResponse.result?.run?.phase, .awaitingApproval)

        let approvalResponse: BurnBarRPCResponseEnvelope<BurnBarRunDetailResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "approval-1",
                method: .approvalRespond,
                authToken: "test-token",
                params: BurnBarApprovalRespondRequest(
                    response: BurnBarApprovalResponse(
                        approvalID: approvalID,
                        clientID: clientID,
                        decision: .approve,
                        respondedAt: Date()
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(approvalResponse.result?.run?.phase, .completed)

        let usageResponse: BurnBarRPCResponseEnvelope<BurnBarRecentUsageResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "usage-1",
                method: .usageRecent,
                authToken: "test-token",
                params: BurnBarRecentUsageRequest(limit: 5)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(usageResponse.result?.usage.count, 1)
        XCTAssertEqual(usageResponse.result?.usage.first?.runID, runID)

        let workflowCreate: BurnBarRPCResponseEnvelope<BurnBarRunCreateResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-create-workflow-1",
                method: .runCreate,
                authToken: "test-token",
                params: BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: "Change a string in one file",
                    modelID: "glm-5",
                    metadata: [
                        "workspaceWorkflow": .object([
                            "type": .string("replace_string_in_file"),
                            "path": .string("src/example.ts"),
                            "from": .string("value = 1"),
                            "to": .string("value = 2")
                        ])
                    ]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(workflowCreate.result?.phase, .waitingOnCompanion)
        let workflowRunID = try XCTUnwrap(workflowCreate.result?.runID)

        let pollResponse: BurnBarRPCResponseEnvelope<BurnBarRunEventBatch> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-poll-1",
                method: .runPoll,
                authToken: "test-token",
                params: BurnBarRunPollRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    runID: workflowRunID
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(pollResponse.result?.pendingToolCalls.first?.tool, .readFile)

        let executeToolResponse: BurnBarRPCResponseEnvelope<BurnBarToolExecutionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "workspace-execute-tool-1",
                method: .workspaceExecuteTool,
                authToken: "test-token",
                params: BurnBarToolExecutionRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    runID: workflowRunID
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(executeToolResponse.result?.disposition, .dispatched)
        let workflowCallID = try XCTUnwrap(executeToolResponse.result?.toolCall?.callID)

        let toolResultResponse: BurnBarRPCResponseEnvelope<BurnBarRunDetailResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "workspace-tool-result-1",
                method: .workspaceToolResult,
                authToken: "test-token",
                params: BurnBarToolResultSubmissionRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    runID: workflowRunID,
                    callID: workflowCallID,
                    succeeded: true,
                    output: .object([
                        "path": .string("file:///workspace/src/example.ts"),
                        "content": .string("export const value = 1;\n")
                    ]),
                    error: nil,
                    completedAt: Date()
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(toolResultResponse.result?.run?.phase, .awaitingApproval)
        XCTAssertEqual(toolResultResponse.result?.approvalRequest?.tool, .applyPatch)
        XCTAssertNil(toolResultResponse.result?.pendingToolCall)

        await server.stop()
    }

    func testSearchQueryWithoutIndexDatabaseReturnsError() async throws {
        let socketPath = makeSocketPath(name: "search-no-db")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                indexDatabasePath: nil,
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchQueryResult> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "search-1",
                method: .searchQuery,
                authToken: "test-token",
                params: BurnBarSearchQueryRequest(query: "test query", resultLimit: 5)
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32603)
        XCTAssertEqual(response.error?.message.contains("indexed search"), true)

        await server.stop()
    }

    func testServerExposesConnectorAndBrowserToolPlaneRPCs() async throws {
        let socketPath = makeSocketPath(name: "tool-plane")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-tool-plane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let connectorService = BurnBarConnectorPlaneService(
            fileURL: rootURL.appendingPathComponent("connector-plane.json"),
            secretStore: BurnBarInMemoryConnectorSecretStore(secrets: [.github: "ghp_test"]),
            transport: { request in
                guard let url = request.url else {
                    fatalError("Connector test request was missing a URL.")
                }
                let payload: [String: Any]
                if url.absoluteString.contains("/user") {
                    payload = ["login": "openburnbar-bot", "html_url": "https://github.com/openburnbar-bot"]
                } else {
                    payload = ["ok": true]
                }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            },
            hostResolver: { _ in ["140.82.113.6"] },
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let browserService = BurnBarBrowserToolService(
            fileURL: rootURL.appendingPathComponent("browser-tooling.json"),
            fetcher: { url in
                let html = "<html><head><title>OpenBurnBar</title></head><body><a href=\"https://example.com\">OpenBurnBar</a></body></html>"
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(html.utf8), response)
            },
            opener: { _ in },
            locateExecutable: { executable in
                executable == "playwright" ? "/opt/homebrew/bin/playwright" : nil
            },
            hostResolver: { _ in ["93.184.216.34"] },
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "server-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
                logger: BurnBarDaemonLogger(category: "server-tests")
            ),
            clientRegistry: BurnBarClientRegistry(logger: BurnBarDaemonLogger(category: "server-tests")),
            connectorPlaneService: connectorService,
            browserToolService: browserService,
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            runService: runService
        )

        try await server.start()

        let connectorGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "connector-get-1", method: .connectorPlaneGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(connectorGet.result?.snapshot.connectors.first?.kind, .github)

        let connectorUpdate: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "connector-update-1",
                method: .connectorConfigUpdate,
                authToken: "test-token",
                params: BurnBarConnectorConfigUpdateRequest(
                    config: BurnBarConnectorConfigMutation(
                        kind: .github,
                        isEnabled: true,
                        baseURL: "https://api.github.com",
                        authKind: .bearerToken
                    ),
                    secret: "ghp_test",
                    replaceSecret: true
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(connectorUpdate.result?.snapshot.connectors.first?.status, .configured)

        let connectorAction: BurnBarRPCResponseEnvelope<BurnBarConnectorActionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "connector-action-1",
                method: .connectorAction,
                authToken: "test-token",
                params: BurnBarConnectorActionRequest(kind: .github, action: .testConnection)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(connectorAction.result?.ok, true)
        XCTAssertEqual(connectorAction.result?.summary.contains("GitHub"), true)

        let browserGet: BurnBarRPCResponseEnvelope<BurnBarBrowserToolingResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "browser-get-1", method: .browserToolingGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(browserGet.result?.snapshot.preferredEngine, .urlSession)

        let browserUpdate: BurnBarRPCResponseEnvelope<BurnBarBrowserToolingResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "browser-update-1",
                method: .browserToolingUpdate,
                authToken: "test-token",
                params: BurnBarBrowserToolingUpdateRequest(
                    preferredEngine: .systemBrowser,
                    allowExternalNavigation: true,
                    enginePreferences: [
                        BurnBarBrowserEnginePreference(kind: .systemBrowser, isEnabled: true),
                        BurnBarBrowserEnginePreference(kind: .urlSession, isEnabled: true),
                        BurnBarBrowserEnginePreference(kind: .playwright, isEnabled: true),
                        BurnBarBrowserEnginePreference(kind: .lightpanda, isEnabled: false)
                    ]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(browserUpdate.result?.snapshot.preferredEngine, .systemBrowser)

        let browserAction: BurnBarRPCResponseEnvelope<BurnBarBrowserActionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "browser-action-1",
                method: .browserAction,
                authToken: "test-token",
                params: BurnBarBrowserActionRequest(
                    action: .extractLinks,
                    url: "https://example.com",
                    preferredEngine: .urlSession,
                    maxLinks: 5
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(browserAction.result?.ok, true)
        XCTAssertEqual(browserAction.result?.links.first, "https://example.com")

        await server.stop()
    }

    func testVAL_GOV_003_ConnectorPlaneHealthOutcomesAreDeterministic() async throws {
        let socketPath = makeSocketPath(name: "val-gov-003")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-connector-determinism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        actor ConnectorTransportFixture {
            var statusCode: Int = 200

            func setStatusCode(_ nextStatusCode: Int) {
                statusCode = nextStatusCode
            }

            func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                guard let url = request.url else {
                    fatalError("Expected connector transport request URL.")
                }
                let payload: [String: Any] = (200 ..< 300).contains(statusCode)
                    ? ["login": "openburnbar-bot", "html_url": "https://github.com/openburnbar-bot"]
                    : ["message": "Service unavailable"]
                let data = try JSONSerialization.data(withJSONObject: payload)
                let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        }

        let fixture = ConnectorTransportFixture()
        let connectorService = BurnBarConnectorPlaneService(
            fileURL: rootURL.appendingPathComponent("connector-plane.json"),
            secretStore: BurnBarInMemoryConnectorSecretStore(),
            transport: { request in
                try await fixture.respond(request)
            },
            hostResolver: { _ in ["140.82.113.6"] },
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json"),
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let runService = BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "server-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
                logger: BurnBarDaemonLogger(category: "server-tests")
            ),
            clientRegistry: BurnBarClientRegistry(logger: BurnBarDaemonLogger(category: "server-tests")),
            connectorPlaneService: connectorService,
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            runService: runService
        )

        try await server.start()

        func githubStatus(from response: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse>) throws -> BurnBarConnectorHealthStatus {
            try XCTUnwrap(response.result?.snapshot.connectors.first(where: { $0.kind == .github })?.status)
        }

        let initialGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "val-gov-003-get-1", method: .connectorPlaneGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(try githubStatus(from: initialGet), .disabled)

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-gov-003-update-1",
                method: .connectorConfigUpdate,
                authToken: "test-token",
                params: BurnBarConnectorConfigUpdateRequest(
                    config: BurnBarConnectorConfigMutation(
                        kind: .github,
                        isEnabled: true,
                        baseURL: "https://api.github.com",
                        authKind: .bearerToken
                    ),
                    secret: nil,
                    replaceSecret: true
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse>
        let missingSecretGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "val-gov-003-get-2", method: .connectorPlaneGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(try githubStatus(from: missingSecretGet), .missingSecret)

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-gov-003-update-2",
                method: .connectorConfigUpdate,
                authToken: "test-token",
                params: BurnBarConnectorConfigUpdateRequest(
                    config: BurnBarConnectorConfigMutation(
                        kind: .github,
                        isEnabled: true,
                        baseURL: "https://api.github.com",
                        authKind: .bearerToken
                    ),
                    secret: "ghp_test",
                    replaceSecret: true
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse>
        let configuredGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "val-gov-003-get-3", method: .connectorPlaneGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(try githubStatus(from: configuredGet), .configured)

        await fixture.setStatusCode(200)
        let healthyAction: BurnBarRPCResponseEnvelope<BurnBarConnectorActionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-gov-003-action-1",
                method: .connectorAction,
                authToken: "test-token",
                params: BurnBarConnectorActionRequest(kind: .github, action: .testConnection)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(healthyAction.result?.ok, true)
        let healthyGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "val-gov-003-get-4", method: .connectorPlaneGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(try githubStatus(from: healthyGet), .healthy)

        await fixture.setStatusCode(503)
        let degradedAction: BurnBarRPCResponseEnvelope<BurnBarConnectorActionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-gov-003-action-2",
                method: .connectorAction,
                authToken: "test-token",
                params: BurnBarConnectorActionRequest(kind: .github, action: .testConnection)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(degradedAction.result?.ok, false)
        let degradedGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "val-gov-003-get-5", method: .connectorPlaneGet, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(try githubStatus(from: degradedGet), .degraded)

        await server.stop()
    }

    func testServerExposesMissionControlRPCs() async throws {
        let socketPath = makeSocketPath(name: "mission-control")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }

        let missionControlService = BurnBarMissionControlService(
            store: BurnBarMissionControlStore(
                eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
                projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
                logger: BurnBarDaemonLogger(category: "server-tests"),
                notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
            ),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            transport: .live(),
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl")
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            missionControlService: missionControlService
        )

        try await server.start()

        let upsertProject: BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "controller-project-upsert-1",
                method: .controllerProjectUpsert,
                authToken: "test-token",
                params: BurnBarControllerProjectUpsertRequest(
                    project: BurnBarReviewProjectSnapshot(
                        id: "project-luna",
                        projectSlug: "luna",
                        displayName: "Luna",
                        summary: "Mission-control smoke test project.",
                        status: .healthy,
                        preferredCadence: .daily,
                        freshness: .provisional,
                        pendingQuestionCount: 0,
                        openFollowupCount: 0,
                        activeMissionCount: 0,
                        needsOperatorAttention: false
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(upsertProject.result?.project?.projectSlug, "luna")

        let questionID = BurnBarQuestionID(rawValue: "question-luna")
        let createQuestion: BurnBarRPCResponseEnvelope<BurnBarQuestionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "question-create-1",
                method: .questionCreate,
                authToken: "test-token",
                params: BurnBarQuestionCreateRequest(
                    question: BurnBarPendingQuestionSnapshot(
                        id: questionID,
                        projectSlug: "luna",
                        title: "Approve the next review packet?",
                        prompt: "Need operator guidance before running the packet.",
                        status: .pending,
                        priority: .high,
                        askedAt: Date()
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(createQuestion.result?.question?.id, questionID)

        let followups: BurnBarRPCResponseEnvelope<BurnBarFollowupsListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "followups-list-1",
                method: .followupsList,
                authToken: "test-token",
                params: BurnBarFollowupsListRequest(projectSlug: "luna")
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(followups.result?.followups.count, 1)
        XCTAssertEqual(followups.result?.followups.first?.questionID, questionID)

        let summary: BurnBarRPCResponseEnvelope<BurnBarControllerSummaryResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "controller-summary-1",
                method: .controllerSummary,
                authToken: "test-token",
                params: BurnBarControllerSummaryRequest(projectSlug: "luna")
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(summary.result?.summary.counts.pendingQuestionCount, 1)
        XCTAssertEqual(summary.result?.summary.counts.openFollowupCount, 1)

        await server.stop()
    }

    func testVAL_CROSS_015_MissionDispatchPathRunsThroughLiveDaemonSocketIntegration() async throws {
        let socketPath = makeSocketPath(name: "val-cross-015")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cross-015-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let missionControlStore = BurnBarMissionControlStore(
            eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "server-tests")
        )
        let missionControlService = BurnBarMissionControlService(
            store: missionControlStore,
            logger: BurnBarDaemonLogger(category: "server-tests"),
            transport: .live(),
            activitySnapshotURL: nil,
            reviewRunLauncher: nil,
            runSnapshotLookup: nil,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            executionReadinessGate: { _, _ in nil }
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            missionControlService: missionControlService
        )

        try await server.start()

        let projectUpsert: BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-cross-015-project-upsert",
                method: .controllerProjectUpsert,
                authToken: "test-token",
                params: BurnBarControllerProjectUpsertRequest(
                    project: BurnBarReviewProjectSnapshot(
                        id: "project-atlas",
                        projectSlug: "atlas",
                        displayName: "Atlas",
                        summary: "Cross-surface integration smoke project.",
                        status: .healthy,
                        preferredCadence: .daily,
                        freshness: .provisional,
                        pendingQuestionCount: 0,
                        openFollowupCount: 0,
                        activeMissionCount: 0,
                        needsOperatorAttention: false
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(projectUpsert.result?.project?.projectSlug, "atlas")

        let missionCreate: BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-cross-015-mission-create",
                method: .missionCreate,
                authToken: "test-token",
                params: BurnBarMissionCreateRequest(
                    projectSlug: "atlas",
                    title: "Dispatch integration smoke",
                    summary: "Exercise daemon socket dispatch path without mock-only controller state.",
                    createdBy: "operator",
                    recommendation: .review
                )
            ),
            socketPath: socketPath
        )
        let missionID = try XCTUnwrap(missionCreate.result?.mission.id)

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-cross-015-mission-approve",
                method: .missionApprove,
                authToken: "test-token",
                params: BurnBarMissionApproveRequest(
                    missionID: missionID,
                    actor: "operator",
                    note: "Proceed with integration smoke."
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>

        let dispatch: BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-cross-015-mission-dispatch",
                method: .missionDispatchPacket,
                authToken: "test-token",
                params: BurnBarMissionDispatchPacketRequest(
                    missionID: missionID,
                    actor: "operator",
                    packet: BurnBarMissionPacketSnapshot(
                        id: BurnBarMissionPacketID(rawValue: "packet-cross-015"),
                        missionID: missionID,
                        workerName: "integration-worker",
                        objective: "Run live daemon socket integration smoke",
                        status: .queued,
                        metadata: [:]
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(dispatch.result?.mission.packets.count, 1)
        XCTAssertEqual(dispatch.result?.mission.packets.first?.status, .queued)
        XCTAssertNil(dispatch.result?.mission.packets.first?.runID)

        let missionGet: BurnBarRPCResponseEnvelope<BurnBarMissionResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "val-cross-015-mission-get",
                method: .missionGet,
                authToken: "test-token",
                params: BurnBarMissionGetRequest(missionID: missionID)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(missionGet.result?.mission?.id, missionID)
        XCTAssertEqual(missionGet.result?.mission?.packets.first?.id.rawValue, "packet-cross-015")

        await server.stop()
    }

    func testUsageRecordRPCAppendsAndRespectsIdempotency() async throws {
        let socketPath = makeSocketPath(name: "usage-record")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let usageRecorder = BurnBarUsageRecorder(
            fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "usage-record-tests")
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "usage-record-tests"),
            usageRecorder: usageRecorder
        )

        try await server.start()

        let event = BurnBarUsageEvent(
            providerID: "hermes",
            modelID: "minimax-m2.7-highspeed",
            inputTokens: 250,
            outputTokens: 80,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 12,
            cost: 0.013,
            recordedAt: Date(timeIntervalSince1970: 1_773_600_000),
            sessionID: "hermes-mobile-session",
            projectName: "Hermes (proxy)",
            confidence: .exact
        )
        let recordRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "usage-record-1",
            method: .usageRecord,
            authToken: "test-token",
            params: BurnBarRecordUsageRequest(idempotencyKey: "hermes-001", event: event)
        )

        let firstInsert: BurnBarRPCResponseEnvelope<BurnBarRecordUsageResponse> = try sendEnvelope(
            recordRequest,
            socketPath: socketPath
        )
        XCTAssertEqual(firstInsert.result?.idempotencyKey, "hermes-001")
        XCTAssertEqual(firstInsert.result?.inserted, true)
        XCTAssertEqual(firstInsert.result?.event.providerID, "hermes")
        XCTAssertEqual(firstInsert.result?.event.confidence, .exact)
        XCTAssertEqual(firstInsert.result?.event.reasoningTokens, 12)

        let duplicateInsert: BurnBarRPCResponseEnvelope<BurnBarRecordUsageResponse> = try sendEnvelope(
            recordRequest,
            socketPath: socketPath
        )
        XCTAssertEqual(duplicateInsert.result?.inserted, false)

        let invalidResponse: BurnBarRPCResponseEnvelope<BurnBarEmptyResult> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "usage-record-invalid",
                method: .usageRecord,
                authToken: "test-token",
                params: BurnBarRecordUsageRequest(
                    idempotencyKey: "hermes-invalid",
                    event: BurnBarUsageEvent(
                        providerID: "hermes",
                        modelID: "minimax-m2.7-highspeed",
                        inputTokens: -1,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cost: 0,
                        recordedAt: Date()
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(invalidResponse.id, "usage-record-invalid")
        XCTAssertEqual(invalidResponse.error?.code, BurnBarRPCErrorCode.invalidParams)
        XCTAssertEqual(invalidResponse.error?.message.contains("inputTokens must be nonnegative"), true)
        let recordsAfterInvalidRequest = try await usageRecorder.records()
        XCTAssertEqual(recordsAfterInvalidRequest.count, 1)

        let recentResponse: BurnBarRPCResponseEnvelope<BurnBarRecentUsageResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "usage-recent-after-record",
                method: .usageRecent,
                authToken: "test-token",
                params: BurnBarRecentUsageRequest(limit: 5)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(recentResponse.result?.usage.count, 1)
        XCTAssertEqual(recentResponse.result?.usage.first?.providerID, "hermes")
        XCTAssertEqual(recentResponse.result?.usage.first?.sessionID, "hermes-mobile-session")
        XCTAssertEqual(recentResponse.result?.usage.first?.projectName, "Hermes (proxy)")
        XCTAssertEqual(recentResponse.result?.usage.first?.confidence, .exact)

        let insightsResponse: BurnBarRPCResponseEnvelope<BurnBarUsageInsightsResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "usage-insights-after-record",
                method: .usageInsights,
                authToken: "test-token",
                params: BurnBarUsageInsightsRequest(
                    limit: 5,
                    windowSeconds: 366 * 24 * 60 * 60,
                    prompt: "Summarize the recorded usage."
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(insightsResponse.error)
        XCTAssertEqual(insightsResponse.result?.usage.count, 1)
        XCTAssertEqual(insightsResponse.result?.sourceID, "daemon.usage.ledger")
        XCTAssertEqual(insightsResponse.result?.analysis.platform, .linux)

        await server.stop()
    }

    func testUsageHistoryRPCReturnsTheExplicitCompleteSnapshot() async throws {
        let socketPath = makeSocketPath(name: "usage-history")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-history-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let databaseURL = rootURL.appendingPathComponent("openburnbar.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { throw XCTSkip("SQLite is unavailable") }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            sessionId TEXT NOT NULL,
            projectName TEXT NOT NULL,
            startTime TEXT,
            endTime TEXT,
            keyFiles TEXT,
            keyCommands TEXT,
            keyTools TEXT,
            inferredTaskTitle TEXT,
            summaryTitle TEXT,
            summaryModel TEXT,
            summary TEXT,
            lastAssistantMessage TEXT,
            fullText TEXT,
            indexedAt TEXT,
            workingDirectory TEXT
        );
        INSERT INTO conversations (
            id, provider, sessionId, projectName, startTime, endTime,
            keyFiles, keyCommands, keyTools, inferredTaskTitle, summaryTitle,
            summaryModel, summary, lastAssistantMessage, fullText, indexedAt,
            workingDirectory
        ) VALUES (
            'Codex:rpc-history', 'Codex', 'rpc-history', 'BurnBar',
            '2026-07-13 12:00:00.000', '2026-07-13 12:01:00.000',
            '[]', '[]', '[]', 'History test', 'History test', 'gpt-5',
            'Persisted summary', 'Continue the task.', 'User asked.\n\nAssistant answered.',
            '2026-07-13 12:02:00.000', '/tmp/burnbar-history'
        );
        """
        var sqliteError: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, &sqliteError), SQLITE_OK)
        if let sqliteError { sqlite3_free(sqliteError) }

        let usageRecorder = BurnBarUsageRecorder(
            fileURL: rootURL.appendingPathComponent("usage-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "usage-history-tests")
        )
        _ = try await usageRecorder.record(
            BurnBarUsageEvent(
                runID: BurnBarRunID(rawValue: "Codex:rpc-history"),
                providerID: "codex",
                modelID: "gpt-5",
                inputTokens: 120,
                outputTokens: 30,
                cacheReadTokens: 20,
                reasoningTokens: 10,
                cost: 0.42,
                recordedAt: Date(timeIntervalSince1970: 1_752_408_060),
                sessionID: "rpc-history"
            ),
            idempotencyKey: "usage-history-record"
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                indexDatabasePath: databaseURL.path,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "usage-history-tests"),
            usageRecorder: usageRecorder
        )

        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarActivityHistoryResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "usage-history-1",
                method: .usageHistory,
                authToken: "test-token",
                params: BurnBarActivityHistoryRequest(limit: 500)
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.historyComplete, true)
        XCTAssertNil(response.result?.nextCursor)
        XCTAssertEqual(response.result?.totalCount, 1)
        let session = try XCTUnwrap(response.result?.sessions.first)
        XCTAssertEqual(session.sourceID, "Codex:rpc-history")
        XCTAssertTrue(session.bodyMD.contains("Persisted summary"))
        XCTAssertEqual(session.tokens, 160)
        XCTAssertEqual(session.costUsd, 0.42, accuracy: 0.000_001)
        XCTAssertEqual(session.model, "gpt-5")
    }

    func testUsageHistoryRPCSkipsTheUsageLedgerWhenHistoryIsIncomplete() async throws {
        let socketPath = makeSocketPath(name: "usage-history-incomplete")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-usage-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let databaseURL = rootURL.appendingPathComponent("openburnbar.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { throw XCTSkip("SQLite is unavailable") }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            sessionId TEXT NOT NULL,
            projectName TEXT NOT NULL,
            startTime TEXT,
            endTime TEXT,
            keyFiles TEXT,
            keyCommands TEXT,
            keyTools TEXT,
            inferredTaskTitle TEXT,
            summaryTitle TEXT,
            summaryModel TEXT,
            summary TEXT,
            lastAssistantMessage TEXT,
            fullText TEXT,
            indexedAt TEXT,
            workingDirectory TEXT
        );
        """
        var sqliteError: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, &sqliteError), SQLITE_OK)
        if let errorPointer = sqliteError {
            sqlite3_free(errorPointer)
            sqliteError = nil
        }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN", nil, nil, &sqliteError), SQLITE_OK)
        if let errorPointer = sqliteError {
            sqlite3_free(errorPointer)
            sqliteError = nil
        }
        for index in 0...500 {
            let insert = """
            INSERT INTO conversations (
                id, provider, sessionId, projectName, startTime, endTime,
                keyFiles, keyCommands, keyTools, inferredTaskTitle, summaryTitle,
                summaryModel, summary, lastAssistantMessage, fullText, indexedAt,
                workingDirectory
            ) VALUES (
                'Codex:history-\(index)', 'Codex', 'history-\(index)', 'BurnBar',
                '2026-07-13 12:00:00.000', '2026-07-13 12:01:00.000',
                '[]', '[]', '[]', 'History \(index)', 'History \(index)', 'gpt-5',
                'Summary', 'Continue.', 'User asked.', '2026-07-13 12:02:00.000',
                '/tmp/burnbar-history'
            );
            """
            XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, &sqliteError), SQLITE_OK)
            if let errorPointer = sqliteError {
                sqlite3_free(errorPointer)
                sqliteError = nil
            }
        }
        XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, &sqliteError), SQLITE_OK)
        if let errorPointer = sqliteError { sqlite3_free(errorPointer) }

        let ledgerURL = rootURL.appendingPathComponent("usage-events.jsonl")
        try Data("{definitely-not-valid-json}\n".utf8).write(to: ledgerURL, options: .atomic)
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                indexDatabasePath: databaseURL.path,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "usage-history-tests"),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: ledgerURL,
                logger: BurnBarDaemonLogger(category: "usage-history-tests")
            )
        )

        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarActivityHistoryResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "usage-history-incomplete-1",
                method: .usageHistory,
                authToken: "test-token",
                params: BurnBarActivityHistoryRequest(limit: 500)
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.error)
        XCTAssertFalse(response.result?.historyComplete ?? true)
        XCTAssertEqual(response.result?.nextCursor, "more")
        XCTAssertEqual(response.result?.historyLimit, 500)
        XCTAssertEqual(response.result?.totalCount, 501)
        XCTAssertTrue(response.result?.sessions.isEmpty ?? false)
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/openburnbar-daemon-tests-\(name)-\(UUID().uuidString).sock"
    }

    private func sendRequest<Response: Decodable>(
        _ request: BurnBarRPCRequestEnvelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendEnvelope(request, socketPath: socketPath)
    }

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }

        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        defer {
            close(fileDescriptor)
        }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var bytesRemaining = rawBuffer.count
            var offset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: offset)
                let bytesWritten = write(fileDescriptor, pointer, bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        let decoder = JSONDecoder()
        return try decoder.decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func makeStaleSocket(at socketPath: String) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = try socketAddress(for: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                Darwin.bind(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }

        guard bindResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        guard listen(fileDescriptor, SOMAXCONN) == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        return fileDescriptor
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

    private func socketPermissions(at socketPath: String) -> mode_t? {
        var fileStatus = stat()
        guard lstat(socketPath, &fileStatus) == 0 else { return nil }
        return fileStatus.st_mode & mode_t(0o777)
    }

    // MARK: - Configuration Validation (D09)

    func testRateLimitingThrottlesExcessiveRequests() async throws {
        let socketPath = makeSocketPath(name: "rate-limit")
        let rateLimiter = BurnBarRateLimiter(
            configuration: BurnBarRateLimitConfiguration(requestsPerSecond: 1, burstCapacity: 1)
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            rateLimiter: rateLimiter
        )

        try await server.start()

        // First request should be allowed
        let allowed: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "rl-1", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertEqual(allowed.result?.ok, true)
        XCTAssertNil(allowed.error)

        // Second immediate request should be throttled
        let throttled: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "rl-2", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertNil(throttled.result)
        XCTAssertEqual(throttled.error?.code, BurnBarRPCErrorCode.rateLimitExceeded)
        XCTAssertEqual(throttled.error?.message.contains("Rate limit exceeded"), true)

        await server.stop()
    }

    func testConfigurationValidate_throwsWhenSocketAuthTokenMissing() throws {
        let config = BurnBarDaemonConfiguration(
            socketPath: makeSocketPath(name: "validation"),
            socketAuthToken: nil
        )
        XCTAssertThrowsError(try config.validate()) { error in
            guard case BurnBarDaemonConfiguration.ValidationError.missingSocketAuthToken = error else {
                return XCTFail("Expected missingSocketAuthToken, got \(error)")
            }
        }
    }

    func testConfigurationValidate_succeedsWhenSocketAuthTokenProvided() throws {
        let config = BurnBarDaemonConfiguration(
            socketPath: makeSocketPath(name: "validation"),
            socketAuthToken: "test-auth-token"
        )
        XCTAssertNoThrow(try config.validate())
    }
}
