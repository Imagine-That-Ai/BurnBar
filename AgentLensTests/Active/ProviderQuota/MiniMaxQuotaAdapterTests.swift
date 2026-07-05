import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class MiniMaxQuotaAdapterTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectoryURL)
        MiniMaxMockURLProtocol.responder = nil
        super.tearDown()
    }

    func testFetch_paygMode_returnsUnavailableMessage() async throws {
        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-cp-test-key", mode: .payAsYouGo)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.minimax.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("Pay-as-you-go"), true)
    }

    func testFetch_openPlatformKey_returnsGuidanceMessage() async throws {
        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-api-test-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.minimax.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("Coding Plan key"), true)
    }

    func testFetch_codingPlanKey_usesCodingPlanEndpointFirst() async throws {
        let remainsJSON = """
        {"model_remains":[{"model_name":"MiniMax-M2.7","remains":900,"total":1000}]}
        """
        var requestedURLs: [String] = []
        MiniMaxMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            requestedURLs.append(url)
            if url.contains("coding_plan/remains") {
                let data = remainsJSON.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-cp-test-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.minimax.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
        XCTAssertTrue(requestedURLs.first?.contains("coding_plan/remains") ?? false)
    }

    // MARK: - Cursor-connector secret-store fallback

    /// A genuinely absent Cursor-connector key must degrade gracefully: the
    /// adapter falls through to the "add a key" unavailable snapshot without
    /// throwing. This proves the lifted secret-store seam preserves the
    /// nil-on-absent contract.
    func testFetch_absentCursorConnectorKey_yieldsUnavailableWithoutThrowing() async throws {
        let secretStore = CountingMiniMaxSecretStore(value: nil)
        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: nil, secretStore: secretStore)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertGreaterThanOrEqual(secretStore.readCallCount, 1)
        XCTAssertEqual(snapshot.provider, AgentProvider.minimax.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("Add a MiniMax Token Plan API key"), true)
    }

    /// A present Cursor-connector key must satisfy the API-key fallback and let
    /// the adapter hit the Token Plan endpoint.
    func testFetch_presentCursorConnectorKey_usesTokenPlanEndpoint() async throws {
        let secretStore = CountingMiniMaxSecretStore(value: "sk-cp-secret-store-key")
        let remainsJSON = """
        {"model_remains":[{"model_name":"MiniMax-M2.7","remains":700,"total":1000}]}
        """
        MiniMaxMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("coding_plan/remains") {
                let data = remainsJSON.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: nil, secretStore: secretStore)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertGreaterThanOrEqual(secretStore.readCallCount, 1)
        XCTAssertEqual(snapshot.provider, AgentProvider.minimax.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    func testFetch_tokenPlanEndpointUsedWhenCodingPlanFails() async throws {
        let remainsJSON = """
        {"model_remains":[{"model_name":"MiniMax-M2.7","remains":500,"total":1000}]}
        """
        MiniMaxMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("token_plan/remains") {
                let data = remainsJSON.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-other-token-plan-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.minimax.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    private func makeContext(
        apiKey: String?,
        mode: MiniMaxQuotaMode = .tokenPlan,
        secretStore: any SecretStore = NoOpSecretStore()
    ) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths.live()
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniMaxMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: [:],
            homeDirectoryURL: tempDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: ClaudeQuotaBridgeManager(
                appPaths: appPaths,
                homeDirectoryURL: tempDirectoryURL,
                fileManager: fileManager,
                snapshotStore: snapshotStore
            ),
            miniMaxMode: mode,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: apiKey.map { ["minimax": $0] } ?? [:],
            secretStore: secretStore
        )
    }
}

private final class CountingMiniMaxSecretStore: SecretStore, @unchecked Sendable {
    private let value: String?
    private let lock = NSLock()
    private var _readCallCount = 0

    var readCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _readCallCount
    }

    init(value: String?) {
        self.value = value
    }

    func string(for account: String, service: String) -> String? {
        lock.lock()
        _readCallCount += 1
        lock.unlock()
        return value
    }
}

private final class MiniMaxMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (URLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
