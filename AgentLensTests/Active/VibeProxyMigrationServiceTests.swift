import XCTest
@testable import OpenBurnBar

final class VibeProxyMigrationServiceTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-vibeproxy-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        try super.tearDownWithError()
    }

    func test_scanMapsImportableVibeProxySecretsWithoutExposingRawSecret() throws {
        try writeJSON(
            [
                "type": "openai-compat",
                "provider": "zai",
                "label": "GLM Plan",
                "api_key": "z1",
            ],
            to: tempHome.appendingPathComponent(".cli-proxy-api/zai.json")
        )

        let snapshot = try makeService().scan()

        XCTAssertEqual(snapshot.importableRecords.count, 1)
        let record = try XCTUnwrap(snapshot.importableRecords.first)
        XCTAssertEqual(record.sourceLabel, "GLM Plan")
        XCTAssertEqual(record.providerID, "zai")
        XCTAssertEqual(record.authMethodID, "zai-coding-plan")
        XCTAssertEqual(record.redactedSecret, "...")
    }

    func test_importCredentialsSendsSupportedSecretsToImporter() async throws {
        try writeJSON(
            [
                "type": "qwen",
                "email": "alberto@example.com",
                "api_key": "q2",
            ],
            to: tempHome.appendingPathComponent(".cli-proxy-api/qwen.json")
        )

        let service = makeService()
        let snapshot = try service.scan()
        let recorder = ImportRequestRecorder()
        let result = await service.importCredentials(from: snapshot) { request in
            await recorder.append(request)
            return "slot-id"
        }
        let requests = await recorder.requests

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(requests.first?.providerID, "alibaba")
        XCTAssertEqual(requests.first?.authMethodID, "alibaba-api-key")
        XCTAssertEqual(requests.first?.label, "VibeProxy alberto@example.com")
        XCTAssertEqual(requests.first?.apiKey, "q2")
    }

    func test_scanMarksLocalLoginRecordsForReconnect() throws {
        try writeJSON(
            [
                "type": "codex",
                "email": "chatgpt@example.com",
                "expired": false,
            ],
            to: tempHome.appendingPathComponent(".cli-proxy-api/codex.json")
        )

        let snapshot = try makeService().scan()

        XCTAssertEqual(snapshot.importableRecords.count, 0)
        XCTAssertEqual(snapshot.reconnectRecords.count, 1)
        guard case .needsReconnect(let reason) = snapshot.reconnectRecords[0].disposition else {
            return XCTFail("expected reconnect disposition")
        }
        XCTAssertTrue(reason.contains("Reconnect"))
    }

    func test_scanDoesNotImportOAuthAccessTokensAsAPIKeys() throws {
        try writeJSON(
            [
                "type": "gemini",
                "email": "gemini@example.com",
                "access_token": "ya29.oauth-session-token",
            ],
            to: tempHome.appendingPathComponent(".cli-proxy-api/gemini.json")
        )

        let snapshot = try makeService().scan()

        XCTAssertEqual(snapshot.importableRecords.count, 0)
        XCTAssertEqual(snapshot.reconnectRecords.count, 1)
        XCTAssertEqual(snapshot.reconnectRecords.first?.redactedSecret, "")
    }

    func test_scanDetectsVibeProxyClientConfigs() throws {
        try writeText(
            """
            [model_providers.factory-vibeproxy]
            base_url = "http://localhost:8317/v1"
            wire_api = "responses"
            """,
            to: tempHome.appendingPathComponent(".codex/config.toml")
        )
        try writeJSON(
            [
                "customModels": [
                    [
                        "id": "custom:VibeProxy-Claude",
                        "model": "claude-sonnet",
                        "provider": "anthropic",
                        "baseUrl": "http://localhost:8317",
                    ],
                ],
            ],
            to: tempHome.appendingPathComponent(".factory/settings.local.json")
        )

        let snapshot = try makeService().scan()

        XCTAssertTrue(snapshot.detectedTargets.contains(.codex))
        XCTAssertTrue(snapshot.detectedTargets.contains(.droid))
    }

    private func makeService() -> VibeProxyMigrationService {
        VibeProxyMigrationService(fileManager: .default, home: tempHome)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor ImportRequestRecorder {
    private(set) var requests: [VibeProxyCredentialImportRequest] = []

    func append(_ request: VibeProxyCredentialImportRequest) {
        requests.append(request)
    }
}
