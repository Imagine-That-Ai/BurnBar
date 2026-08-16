import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

final class BurnBarDaemonServerTests: XCTestCase {
    /// Builds a hermetic daemon configuration: the socket lives under /tmp
    /// and the fleet persistence paths (fleet.sqlite + fleet-snapshot.json)
    /// live in a per-test temp dir — never the real support dir.
    private func makeConfiguration(
        name: String,
        daemonVersion: String = "test-daemon",
        indexDatabasePath: String? = nil
    ) -> BurnBarDaemonConfiguration {
        let socketPath = makeSocketPath(name: name)
        let fleetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-server-fleet-\(name)-\(UUID().uuidString)", isDirectory: true)
        return BurnBarDaemonConfiguration(
            socketPath: socketPath,
            daemonVersion: daemonVersion,
            indexDatabasePath: indexDatabasePath,
            fleetStorePath: fleetDir.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: fleetDir.appendingPathComponent("fleet-snapshot.json").path
        )
    }

    func testDaemonBootsRespondsToHealthAndCleansUpSocketOnShutdown() async throws {
        let configuration = makeConfiguration(name: "health", daemonVersion: "test-daemon")
        let socketPath = configuration.socketPath
        let server = BurnBarDaemonServer(configuration: configuration)

        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let response: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "health-1", method: .health),
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

    func testDaemonRemovesStaleSocketBeforeBinding() async throws {
        let socketPath = makeSocketPath(name: "stale")
        let staleSocket = try makeStaleSocket(at: socketPath)
        close(staleSocket)

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let fleetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-server-fleet-stale-\(UUID().uuidString)", isDirectory: true)
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                fleetStorePath: fleetDir.appendingPathComponent("fleet.sqlite").path,
                fleetSnapshotFilePath: fleetDir.appendingPathComponent("fleet-snapshot.json").path
            )
        )
        try await server.start()

        let response: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "health-2", method: .health),
            socketPath: socketPath
        )

        XCTAssertEqual(response.result?.ok, true)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testCatalogResponseUsesBundledCatalogAndCurrentProtocolVersion() async throws {
        let configuration = makeConfiguration(name: "catalog", daemonVersion: "catalog-daemon")
        let socketPath = configuration.socketPath
        let server = BurnBarDaemonServer(configuration: configuration)

        try await server.start()

        let response: BurnBarRPCResponseEnvelope<BurnBarCatalogResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "catalog-1", method: .catalog),
            socketPath: socketPath
        )

        XCTAssertEqual(response.id, "catalog-1")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.catalog, BurnBarCatalogLoader.bundledCatalog)

        await server.stop()
    }

    func testServerExposesRunConfigAndUsageRPCs() async throws {
        let socketPath = makeSocketPath(name: "run-rpc")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-server-rpc-\(UUID().uuidString)", isDirectory: true)
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
                fleetStorePath: rootURL.appendingPathComponent("fleet.sqlite").path,
                fleetSnapshotFilePath: rootURL.appendingPathComponent("fleet-snapshot.json").path
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
                params: BurnBarConfigUpdateRequest(snapshot: updatedSnapshot)
            ),
            socketPath: socketPath
        )
        XCTAssertTrue(configUpdateResponse.result?.snapshot.providerSettings(id: "zai")?.isEnabled == true)

        let createResponse: BurnBarRPCResponseEnvelope<BurnBarRunCreateResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-create-1",
                method: .runCreate,
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
        XCTAssertEqual(toolResultResponse.result?.run?.phase, .waitingOnCompanion)
        XCTAssertEqual(toolResultResponse.result?.pendingToolCall?.tool, .applyPatch)

        await server.stop()
    }

    func testSearchQueryWithoutIndexDatabaseReturnsError() async throws {
        let configuration = makeConfiguration(name: "search-no-db", indexDatabasePath: nil)
        let socketPath = configuration.socketPath
        let server = BurnBarDaemonServer(configuration: configuration)

        try await server.start()

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchQueryResult> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "search-1",
                method: .searchQuery,
                params: BurnBarSearchQueryRequest(query: "test query", resultLimit: 5)
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32603)
        XCTAssertTrue(response.error?.message.contains("indexed search") == true)

        await server.stop()
    }

    func testFleetOrchestratorAndDirectiveMethodsDispatchAfterM4() async throws {
        let configuration = makeConfiguration(name: "fleet-m4-dispatch")
        let socketPath = configuration.socketPath
        let server = BurnBarDaemonServer(configuration: configuration)
        try await server.start()

        // M4: the orchestrator/directive method cases dispatch real handlers.
        // On a fresh daemon, get returns the default none designation in the
        // standard versioned envelope (VAL-RPC-008).
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "fleet-orch-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.id, "fleet-orch-get")
        XCTAssertEqual(getResponse.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(getResponse.error)
        XCTAssertEqual(getResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertNil(getResponse.result?.state.setAt)
        XCTAssertEqual(getResponse.result?.state.pendingDirectives, 0)

        // The daemon keeps serving normal requests after the fleet calls.
        let health: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "health-after-fleet", method: .health),
            socketPath: socketPath
        )
        XCTAssertEqual(health.result?.ok, true)

        await server.stop()
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/burnbar-daemon-tests-\(name)-\(UUID().uuidString).sock"
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
        try sendFleetEnvelope(envelope, socketPath: socketPath)
    }

    private func makeStaleSocket(at socketPath: String) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = try fleetSocketAddress(for: socketPath)
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

}
