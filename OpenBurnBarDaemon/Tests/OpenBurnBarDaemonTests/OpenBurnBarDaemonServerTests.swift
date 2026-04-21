import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Darwin
import Foundation
import XCTest

final class BurnBarDaemonServerTests: XCTestCase {
    func testDaemonBootsRespondsToHealthAndCleansUpSocketOnShutdown() async throws {
        let socketPath = makeSocketPath(name: "health")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                daemonVersion: "test-daemon"
            )
        )

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

        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath)
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
        let socketPath = makeSocketPath(name: "catalog")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                daemonVersion: "catalog-daemon"
            )
        )

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

    func testDaemonSocketAuthRequiresMatchingToken() async throws {
        let socketPath = makeSocketPath(name: "socket-auth")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "socket-secret"
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
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath),
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
        XCTAssertEqual(toolResultResponse.result?.run?.phase, .awaitingApproval)
        XCTAssertEqual(toolResultResponse.result?.approvalRequest?.tool, .applyPatch)
        XCTAssertNil(toolResultResponse.result?.pendingToolCall)

        await server.stop()
    }

    func testSearchQueryWithoutIndexDatabaseReturnsError() async throws {
        let socketPath = makeSocketPath(name: "search-no-db")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath, indexDatabasePath: nil)
        )

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
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath),
            logger: BurnBarDaemonLogger(category: "server-tests"),
            runService: runService
        )

        try await server.start()

        let connectorGet: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "connector-get-1", method: .connectorPlaneGet),
            socketPath: socketPath
        )
        XCTAssertEqual(connectorGet.result?.snapshot.connectors.first?.kind, .github)

        let connectorUpdate: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "connector-update-1",
                method: .connectorConfigUpdate,
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
                params: BurnBarConnectorActionRequest(kind: .github, action: .testConnection)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(connectorAction.result?.ok, true)
        XCTAssertTrue(connectorAction.result?.summary.contains("GitHub") == true)

        let browserGet: BurnBarRPCResponseEnvelope<BurnBarBrowserToolingResponse> = try sendRequest(
            BurnBarRPCRequestEnvelope(id: "browser-get-1", method: .browserToolingGet),
            socketPath: socketPath
        )
        XCTAssertEqual(browserGet.result?.snapshot.preferredEngine, .urlSession)

        let browserUpdate: BurnBarRPCResponseEnvelope<BurnBarBrowserToolingResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "browser-update-1",
                method: .browserToolingUpdate,
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

    func testServerExposesMissionControlRPCs() async throws {
        let socketPath = makeSocketPath(name: "mission-control")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath)
        )

        try await server.start()

        let upsertProject: BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "controller-project-upsert-1",
                method: .controllerProjectUpsert,
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
                params: BurnBarControllerSummaryRequest(projectSlug: "luna")
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(summary.result?.summary.counts.pendingQuestionCount, 1)
        XCTAssertEqual(summary.result?.summary.counts.openFollowupCount, 1)

        await server.stop()
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
}
