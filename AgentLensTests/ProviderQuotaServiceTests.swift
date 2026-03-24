import Foundation
import XCTest
@testable import BurnBar

@MainActor
final class ProviderQuotaServiceTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        StubURLProtocol.requestHandler = nil
    }

    func test_codexRefresh_readsLatestLocalQuotaSnapshot() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let rolloutDirectory = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions/2026/03/24", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = rolloutDirectory.appendingPathComponent("rollout-2026-03-24T10-00-00.jsonl")
        let payload = """
        {"timestamp":"2026-03-24T10:00:01Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":22.0,"window_minutes":300,"resets_at":1774359600},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1774801258}}}}
        """
        try Data(payload.utf8).write(to: rolloutURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport
        )

        await service.refresh(provider: .codex, dataStore: DataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .codex))

        XCTAssertEqual(snapshot.source, .localSession)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "5-hour window" })?.remainingPercent?.rounded(), 78)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "7-day window" })?.remainingPercent?.rounded(), 80)
    }

    func test_claudeBridge_installAndRemove_roundTripsStatusLineCommand() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let originalSettings = """
        {
          "statusLine": {
            "type": "command",
            "command": "echo original-status"
          }
        }
        """
        try Data(originalSettings.utf8).write(to: settingsURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport
        )

        try service.installClaudeQuotaBridge()

        let installedSettings = try readJSON(from: settingsURL)
        let installedStatusLine = try XCTUnwrap(installedSettings["statusLine"] as? [String: Any])
        let installedCommand = try XCTUnwrap(installedStatusLine["command"] as? String)
        XCTAssertEqual(installedCommand, BurnBarAppPaths(applicationSupportRoot: appSupport).claudeStatuslineBridgeScriptURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BurnBarAppPaths(applicationSupportRoot: appSupport).claudeStatuslineBridgeScriptURL.path))
        XCTAssertEqual(service.claudeBridgeStatus.state, .awaitingFirstPayload)

        try service.removeClaudeQuotaBridge()

        let restoredSettings = try readJSON(from: settingsURL)
        let restoredStatusLine = try XCTUnwrap(restoredSettings["statusLine"] as? [String: Any])
        XCTAssertEqual(restoredStatusLine["command"] as? String, "echo original-status")
    }

    func test_factoryRefresh_estimatesRemainingFromPlanTierAndMonthlyUsage() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            factoryPlanProvider: { .pro }
        )

        let store = DataStore()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
        store.replaceUsages([
            TokenUsage(
                provider: .factory,
                sessionId: "factory-month",
                projectName: "Quota",
                model: "factory-model",
                inputTokens: 3_000_000,
                outputTokens: 2_000_000,
                costUSD: 0,
                startTime: start.addingTimeInterval(60),
                endTime: start.addingTimeInterval(120)
            )
        ])

        await service.refresh(provider: .factory, dataStore: store)
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))
        let bucket = try XCTUnwrap(snapshot.primaryBucket)

        XCTAssertEqual(snapshot.source, .manualEstimate)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(bucket.remainingValue?.rounded(), 15_000_000)
        XCTAssertEqual(bucket.limitValue?.rounded(), 20_000_000)
    }

    func test_refreshAll_persistsSnapshotsAndReloadsFromDisk() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = BurnBarAppPaths(applicationSupportRoot: appSupport)

        let first = makeService(
            home: home,
            appSupportRoot: appSupport,
            factoryPlanProvider: { .pro }
        )

        let store = DataStore()
        await first.refreshAll(dataStore: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.providerQuotaSnapshotsURL.path))

        let second = makeService(
            home: home,
            appSupportRoot: appSupport,
            factoryPlanProvider: { .pro }
        )

        XCTAssertNotNil(second.snapshot(for: .factory))
    }

    func test_miniMaxRefresh_usesTokenPlanEndpoint() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "minimax", value: "mm-token")
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mm-token")

            let body = """
            {
              "data": [
                {
                  "name": "5 hour quota",
                  "used_percent": 25,
                  "window": "5 hour"
                },
                {
                  "name": "weekly quota",
                  "used_percent": 40,
                  "window": "weekly"
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            miniMaxModeProvider: { .tokenPlan }
        )

        await service.refresh(provider: .minimax, dataStore: DataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .minimax))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first?.remainingPercent?.rounded(), 75)
    }

    func test_zaiRefresh_usesOfficialMonitorEndpoints() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "zai", value: "zai-key")
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            let path = url.path
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "zai-key")

            if path.hasSuffix("/api/monitor/usage/model-usage") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: #"{"data":[{"model":"glm-5","usage":2}]}"#
                )
            }

            if path.hasSuffix("/api/monitor/usage/tool-usage") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: #"{"data":[{"name":"mcp","usage":12}]}"#
                )
            }

            if path.hasSuffix("/api/monitor/usage/quota/limit") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "data": [
                        {
                          "type": "TOKENS_LIMIT",
                          "percentage": 32,
                          "resets_at": "2026-03-24T12:00:00Z"
                        },
                        {
                          "type": "TIME_LIMIT",
                          "currentUsage": 12,
                          "usage": 100,
                          "percentage": 12
                        }
                      ]
                    }
                    """
                )
            }

            XCTFail("Unexpected URL \(url.absoluteString)")
            return try self.httpResponse(url: url, statusCode: 404, body: #"{"error":"not found"}"#)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session
        )

        await service.refresh(provider: .zai, dataStore: DataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .zai))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertGreaterThanOrEqual(snapshot.buckets.count, 2)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label.lowercased().contains("token") }))
    }

    private func makeService(
        home: URL,
        appSupportRoot: URL,
        keyStore: ProviderAPIKeyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(service: "tests.\(UUID().uuidString)", legacyServices: [], backend: TestKeychainBackend())
        ),
        session: URLSession = .shared,
        miniMaxModeProvider: @escaping () -> MiniMaxQuotaMode = { .payAsYouGo },
        factoryPlanProvider: @escaping () -> FactoryQuotaPlanTier = { .unknown }
    ) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: keyStore,
            appPaths: BurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: session,
            environment: [:],
            homeDirectoryURL: home,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider
        )
    }

    private func makeKeyStore(provider: String, value: String) throws -> ProviderAPIKeyStore {
        let backend = TestKeychainBackend()
        let store = ProviderAPIKeyStore(
            keychain: KeychainStore(service: "tests.\(UUID().uuidString)", legacyServices: [], backend: backend)
        )
        try store.setAPIKey(value, for: provider)
        return store
    }

    private func makeStubSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        StubURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func httpResponse(url: URL, statusCode: Int, body: String) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, Data(body.utf8))
    }

    private func readJSON(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }
}

private final class TestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
