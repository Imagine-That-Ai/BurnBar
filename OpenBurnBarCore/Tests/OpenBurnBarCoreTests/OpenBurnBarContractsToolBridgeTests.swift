import XCTest
@testable import OpenBurnBarCore

final class BurnBarContractsToolBridgeTests: XCTestCase {
    func testToolExecutionRequestRoundTripCodable() throws {
        let original = BurnBarToolExecutionRequest(
            clientID: BurnBarClientID(rawValue: "client-1"),
            sessionID: BurnBarSessionID(rawValue: "session-1"),
            runID: BurnBarRunID(rawValue: "run-1")
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BurnBarToolExecutionRequest.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testToolExecutionResponseRoundTripIncludesRefusalErrorShape() throws {
        let snapshot = BurnBarToolCallSnapshot(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .applyPatch,
            arguments: .object(["changes": .array([])]),
            status: .failed,
            requestedBy: BurnBarClientID(rawValue: "client-1"),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            claimedBy: BurnBarClientID(rawValue: "client-1"),
            claimedAt: Date(timeIntervalSince1970: 1_700_000_010),
            completedAt: Date(timeIntervalSince1970: 1_700_000_020),
            output: nil,
            error: BurnBarToolExecutionError(
                code: .trustGated,
                message: "Workspace trust is required."
            )
        )
        let original = BurnBarToolExecutionResponse(disposition: .dispatched, toolCall: snapshot)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BurnBarToolExecutionResponse.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.toolCall?.error?.code, .trustGated)
    }

    func testRunEventBatchRoundTripIncludesPendingToolCalls() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let runID = BurnBarRunID(rawValue: "run-1")
        let clientID = BurnBarClientID(rawValue: "client-1")

        let batch = BurnBarRunEventBatch(
            runs: [
                BurnBarRunStateSnapshot(
                    runID: runID,
                    clientID: clientID,
                    sessionID: BurnBarSessionID(rawValue: "session-1"),
                    phase: .waitingOnCompanion,
                    modelID: "glm-5",
                    updatedAt: now
                )
            ],
            approvals: [],
            pendingToolCalls: [
                BurnBarToolCallSnapshot(
                    callID: "call-1",
                    runID: runID,
                    tool: .readFile,
                    arguments: .object(["path": .string("README.md")]),
                    status: .pending,
                    requestedBy: clientID,
                    requestedAt: now
                )
            ],
            arbitration: BurnBarClientArbitrationSnapshot(
                activeClientID: clientID,
                attachedClientIDs: [clientID],
                reason: "first_controller_attached"
            ),
            emittedAt: now
        )

        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(BurnBarRunEventBatch.self, from: data)

        XCTAssertEqual(decoded.runs.first?.phase, .waitingOnCompanion)
        XCTAssertEqual(decoded.pendingToolCalls.first?.tool, .readFile)
        XCTAssertEqual(decoded.arbitration?.activeClientID, clientID)
    }

    func testConnectorAndBrowserContractsRoundTrip() throws {
        let connectorSnapshot = BurnBarConnectorPlaneSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_710_300_000),
            connectors: [
                BurnBarConnectorConfigSnapshot(
                    kind: .github,
                    displayName: "GitHub",
                    isEnabled: true,
                    baseURL: "https://api.github.com",
                    authKind: .bearerToken,
                    secretConfigured: true,
                    secretHint: "ghp_...",
                    status: .healthy,
                    lastCheckedAt: Date(timeIntervalSince1970: 1_710_300_010),
                    statusDetail: "Connected as openburnbar-bot.",
                    supportedActions: [.testConnection, .sampleRequest]
                )
            ]
        )
        let browserSnapshot = BurnBarBrowserToolingSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_710_300_020),
            preferredEngine: .urlSession,
            allowExternalNavigation: true,
            engines: [
                BurnBarBrowserEngineSnapshot(
                    kind: .urlSession,
                    displayName: "Daemon Fetcher",
                    isEnabled: true,
                    status: .ready,
                    detail: "Ready for fetch and link extraction.",
                    supportsFetch: true,
                    supportsExternalNavigation: false
                ),
                BurnBarBrowserEngineSnapshot(
                    kind: .systemBrowser,
                    displayName: "System Browser",
                    isEnabled: true,
                    status: .ready,
                    executablePath: "/usr/bin/open",
                    supportsFetch: false,
                    supportsExternalNavigation: true
                )
            ]
        )
        let connectorAction = BurnBarConnectorActionResponse(
            kind: .github,
            action: .sampleRequest,
            ok: true,
            summary: "Fetched account preview.",
            detail: "Connected as openburnbar-bot.",
            payload: .object(["login": .string("openburnbar-bot")]),
            recordedAt: Date(timeIntervalSince1970: 1_710_300_030)
        )
        let browserAction = BurnBarBrowserActionResponse(
            action: .extractLinks,
            engine: .urlSession,
            ok: true,
            summary: "Extracted 2 links.",
            title: "OpenBurnBar",
            document: "OpenBurnBar ships daemon-first tooling.",
            links: ["https://example.com", "https://example.com/docs"],
            recordedAt: Date(timeIntervalSince1970: 1_710_300_040)
        )

        let payload = [
            try BurnBarJSONValue.fromEncodable(BurnBarConnectorPlaneResponse(snapshot: connectorSnapshot)),
            try BurnBarJSONValue.fromEncodable(BurnBarBrowserToolingResponse(snapshot: browserSnapshot)),
            try BurnBarJSONValue.fromEncodable(connectorAction),
            try BurnBarJSONValue.fromEncodable(browserAction)
        ]

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode([BurnBarJSONValue].self, from: data)

        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(connectorSnapshot.connectors.first?.status, .healthy)
        XCTAssertEqual(browserSnapshot.engines.first?.kind, .urlSession)
        XCTAssertEqual(connectorAction.kind, .github)
        XCTAssertEqual(browserAction.engine, .urlSession)
    }

    func testRPCMethodsIncludeConnectorAndBrowserPlane() {
        let methods = Set(BurnBarRPCMethod.allCases.map(\.rawValue))
        XCTAssertTrue(methods.contains("daemon.connector.plane.get"))
        XCTAssertTrue(methods.contains("daemon.connector.config.update"))
        XCTAssertTrue(methods.contains("daemon.connector.action"))
        XCTAssertTrue(methods.contains("daemon.browser.tooling.get"))
        XCTAssertTrue(methods.contains("daemon.browser.tooling.update"))
        XCTAssertTrue(methods.contains("daemon.browser.action"))
        XCTAssertTrue(methods.contains("daemon.provider.credential_slot.upsert"))
        XCTAssertTrue(methods.contains("daemon.provider.credential_slot.remove"))
    }
}
