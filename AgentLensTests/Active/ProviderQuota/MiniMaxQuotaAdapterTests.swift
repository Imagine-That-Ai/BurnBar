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

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("Pay-as-you-go"))
    }

    func testFetch_openPlatformKey_returnsGuidanceMessage() async throws {
        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-api-test-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("Coding Plan key"))
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

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
        XCTAssertTrue(requestedURLs.first?.contains("coding_plan/remains") ?? false)
    }

    // MARK: - Cursor-connector keychain fallback (credential-read fault path)

    /// A genuinely absent Cursor-connector key must degrade gracefully: the
    /// adapter falls through to the "add a key" unavailable snapshot without
    /// throwing. This proves the migrated `credentialIfPresent` accessor
    /// preserves the nil-on-absent contract.
    func testFetch_absentCursorConnectorKey_yieldsUnavailableWithoutThrowing() async throws {
        let adapter = MiniMaxQuotaAdapter(keychain: KeychainStore(backend: EmptyKeychainBackend()))
        let context = try makeContext(apiKey: nil)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("Add a MiniMax Token Plan API key"))
    }

    /// A broken/locked keychain (real OSStatus fault) must NOT crash the fetch
    /// and must NOT be misread as a configured credential. The migrated
    /// accessor logs the fault and returns nil, so the adapter resolves no key
    /// and reports the same graceful "add a key" unavailable snapshot — but
    /// crucially `fetch` completes without throwing the keychain error.
    func testFetch_faultingKeychain_isObservedAsNilWithoutThrowing() async throws {
        let faultingBackend = FaultingKeychainBackend(error: .unhandled(errSecNotAvailable))
        let adapter = MiniMaxQuotaAdapter(keychain: KeychainStore(backend: faultingBackend))
        let context = try makeContext(apiKey: nil)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertTrue(faultingBackend.didAttemptRead, "Expected the keychain fallback to be exercised")
        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("Add a MiniMax Token Plan API key"))
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

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    private func makeContext(
        apiKey: String?,
        mode: MiniMaxQuotaMode = .tokenPlan
    ) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths.live()
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
            resolvedAPIKeys: apiKey.map { ["minimax": $0] } ?? [:]
        )
    }
}

/// Backend that holds no items: `data(for:)` always returns nil so every read
/// resolves to "genuinely absent" rather than a fault.
private final class EmptyKeychainBackend: KeychainStoreBackend {
    func set(_ value: Data, service: String, account: String) throws {}

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        nil
    }

    func delete(service: String, account: String) throws {}
}

/// Backend that simulates a broken/locked keychain: `data(for:)` throws a real
/// `KeychainStoreError`, exercising the fault path that `try?` used to swallow.
private final class FaultingKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    let error: KeychainStoreError
    private(set) var didAttemptRead = false

    init(error: KeychainStoreError) {
        self.error = error
    }

    func set(_ value: Data, service: String, account: String) throws {}

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        didAttemptRead = true
        throw error
    }

    func delete(service: String, account: String) throws {}
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
