import XCTest
import Security
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class MimoQuotaAdapterTests: XCTestCase {
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
        MimoMockURLProtocol.responder = nil
        super.tearDown()
    }

    func testFetch_paygKey_returnsUnavailableBalanceMessage() async throws {
        let adapter = MimoQuotaAdapter()
        let context = try makeContext(apiKey: "sk-test-payg-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("pay-as-you-go"))
    }

    func testFetch_tokenPlanRemains_parsesExactBuckets() async throws {
        let remainsJSON = """
        {"data":{"remains":[{"name":"credits","used":100,"limit":1000,"remaining":900}]}}
        """
        MimoMockURLProtocol.responder = { request in
            let url = request.url ?? URL(string: "https://example.com")!
            guard url.absoluteString.contains("token_plan/remains") else {
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let data = remainsJSON.data(using: .utf8)!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let adapter = MimoQuotaAdapter()
        let context = try makeContext(apiKey: "tp-test-token-plan")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    func testFetch_tokenPlanRemainsMissing_usesTierEstimate() async throws {
        MimoMockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let adapter = MimoQuotaAdapter()
        let context = try makeContext(
            apiKey: "tp-test-token-plan",
            tier: .standard,
            billingCycle: .monthly
        )

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.buckets.first?.limitValue, MimoTokenPlanTier.standard.monthlyCreditLimit)
    }

    // MARK: - Connector-key credential read (fault must be observable)

    /// The migrated read in `MimoQuotaAdapter.cursorConnectorKey(for:)` resolves
    /// the connector key via `KeychainStore.credentialIfPresent` instead of the
    /// old `try? keychain.string(for:)`. These tests drive that exact accessor
    /// through the `KeychainStore(backend:)` seam:
    ///   * a genuine Keychain fault (`unhandled(errSecNotAvailable)`) must return
    ///     `nil` *without throwing or crashing* — the fault is surfaced to
    ///     `AppLogger`, never silently collapsed into "no credential".
    ///   * a genuinely absent credential must still return `nil`, preserving the
    ///     graceful-degradation contract the call site relies on.
    private let connectorService = "com.openburnbar.mimoquota-credential-tests"
    private let connectorAccount = "provider.mimo.apiKey"

    func testConnectorKeyRead_keychainFault_returnsNilWithoutThrowing() {
        let backend = MimoFaultInjectingKeychainBackend()
        backend.readErrors[connectorService] = KeychainStoreError.unhandled(errSecNotAvailable)
        let keychain = KeychainStore(service: connectorService, legacyServices: [], backend: backend)

        let result = keychain.credentialIfPresent(
            for: connectorAccount,
            allowUserInteraction: false,
            event: "mimo_quota_connector_key_read_failed"
        )

        XCTAssertNil(result)
    }

    func testConnectorKeyRead_credentialAbsent_returnsNil() {
        let backend = MimoFaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: connectorService, legacyServices: [], backend: backend)

        let result = keychain.credentialIfPresent(
            for: connectorAccount,
            allowUserInteraction: false,
            event: "mimo_quota_connector_key_read_failed"
        )

        XCTAssertNil(result)
    }

    func testConnectorKeyRead_credentialPresent_returnsStoredValue() throws {
        let backend = MimoFaultInjectingKeychainBackend()
        let keychain = KeychainStore(service: connectorService, legacyServices: [], backend: backend)
        try keychain.set("tp-connector-secret", for: connectorAccount)

        let result = keychain.credentialIfPresent(
            for: connectorAccount,
            allowUserInteraction: false,
            event: "mimo_quota_connector_key_read_failed"
        )

        XCTAssertEqual(result, "tp-connector-secret")
    }

    /// Proves the migrated call site degrades gracefully end-to-end: with no
    /// resolved/env key and a *broken* Keychain behind the connector-key read,
    /// `fetch` returns the unavailable snapshot rather than throwing.
    func testFetch_noKeyAndKeychainFault_returnsUnavailableWithoutThrowing() async throws {
        let backend = MimoFaultInjectingKeychainBackend()
        backend.readErrors[connectorService] = KeychainStoreError.unhandled(errSecNotAvailable)
        let service = connectorService
        let adapter = MimoQuotaAdapter(
            keychainStoreProvider: { KeychainStore(service: service, legacyServices: [], backend: backend) }
        )
        let context = try makeContext(apiKey: nil)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .unavailable)
    }

    private func makeContext(
        apiKey: String?,
        region: ProviderEndpointRegion = .sgp,
        tier: MimoTokenPlanTier? = nil,
        billingCycle: MimoTokenPlanBillingCycle = .monthly
    ) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths.live()
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MimoMockURLProtocol.self]
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
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: region,
            mimoTokenPlanTier: tier,
            mimoTokenPlanBillingCycle: billingCycle,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: ["mimo": apiKey]
        )
    }
}

private final class MimoMockURLProtocol: URLProtocol {
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

// MARK: - Fault-injecting test backend

/// In-memory `KeychainStoreBackend` whose `data(for:)` throws a configured fault,
/// letting tests model a locked/unavailable Keychain through the production seam.
private final class MimoFaultInjectingKeychainBackend: KeychainStoreBackend {
    var storage: [String: [String: Data]] = [:]
    var readErrors: [String: Error] = [:]
    var deleteErrors: [String: Error] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        if let error = readErrors[service] {
            throw error
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        if let error = deleteErrors[service] {
            throw error
        }
        storage[service]?[account] = nil
    }
}
