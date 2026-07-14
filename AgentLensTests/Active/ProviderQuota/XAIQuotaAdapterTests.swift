import XCTest
import Security
@testable import OpenBurnBar
@testable import OpenBurnBarCore
// Core-decomposition: XAIQuotaAdapter (incl. its INTERNAL static superGrokLogURL) moved from the
// Core monolith into OpenBurnBarQuota; the umbrella shim re-exports only Quota's public API, so
// reaching the internal member needs a direct @testable import (same AE-TESTABLE pattern as the
// WarpQuota/Antigravity test fixes; the app target already links OpenBurnBarQuota).
@testable import OpenBurnBarQuota

final class XAIQuotaAdapterTests: XCTestCase {
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
        XAIMockURLProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - Branch 3: missing key + unknown plan

    func testFetch_unknownPlanWithoutKey_returnsUnavailable() async throws {
        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .unknown, mgmtKey: nil)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("Pick a Grok plan"), true)
    }

    // MARK: - Branch 1: GrokBuild credit balance

    func testFetch_grokBuildPlan_parsesPrepaidBalanceFromManagementAPI() async throws {
        // 1234 USD cents of unspent credit → xAI returns total.val = "-1234".
        let teamsJSON = #"{ "teams": [ { "id": "team_42", "name": "Acme" } ] }"#
        let balanceJSON = #"{ "total": { "val": "-1234" } }"#
        let usageJSON = #"""
        {
          "timeSeries": [
            {
              "dataPoints": [
                { "timestamp": "\#(iso8601(Date().addingTimeInterval(-60)))", "values": [ { "name": "usd", "value": 0.5 } ] },
                { "timestamp": "\#(iso8601(Date().addingTimeInterval(-2 * 24 * 60 * 60)))", "values": [ { "name": "usd", "value": 2.0 } ] }
              ]
            }
          ]
        }
        """#

        XAIMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            switch url {
            case "https://api.x.ai/v1/teams":
                return Self.respond(json: teamsJSON, for: request)
            case "https://api.x.ai/v1/billing/teams/team_42/prepaid/balance":
                return Self.respond(json: balanceJSON, for: request)
            case "https://api.x.ai/v1/billing/teams/team_42/usage":
                return Self.respond(json: usageJSON, for: request)
            default:
                return Self.respond(status: 404, json: "{}", for: request)
            }
        }

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .grokBuild, mgmtKey: "xai-mgmt-test")

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.exact)

        guard let balanceBucket = snapshot.buckets.first(where: { $0.key == "xai-prepaid-credit-balance" }) else {
            XCTFail("Missing prepaid credit balance bucket"); return
        }
        XCTAssertEqual(balanceBucket.unit, .currency)
        XCTAssertEqual(balanceBucket.remainingValue ?? -1, 12.34, accuracy: 0.001)

        guard let bucket24h = snapshot.buckets.first(where: { $0.key == "xai-usage-24h" }) else {
            XCTFail("Missing 24h usage bucket"); return
        }
        XCTAssertEqual(bucket24h.usedValue ?? -1, 0.5, accuracy: 0.001)

        guard let bucket7d = snapshot.buckets.first(where: { $0.key == "xai-usage-7d" }) else {
            XCTFail("Missing 7d usage bucket"); return
        }
        XCTAssertEqual(bucket7d.usedValue ?? -1, 2.5, accuracy: 0.001)
    }

    // MARK: - Branch 2: SuperGrok pacing

    func testFetch_superGrokPlan_withPopulatedLog_reportsRollingWindowUsage() async throws {
        let now = Date()
        try writeSuperGrokLog(events: [
            // In-window events.
            now.addingTimeInterval(-30 * 60),
            now.addingTimeInterval(-60 * 60),
            now.addingTimeInterval(-90 * 60),
            // Out of window — must NOT count.
            now.addingTimeInterval(-3 * 60 * 60)
        ])

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .superGrok, mgmtKey: nil)

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.estimated)

        guard let bucket = snapshot.buckets.first(where: { $0.key == "xai-supergrok-2h-rolling" }) else {
            XCTFail("Missing rolling 2h bucket"); return
        }
        XCTAssertEqual(bucket.usedValue ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(bucket.limitValue ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(bucket.remainingValue ?? -1, 97, accuracy: 0.0001)
        XCTAssertTrue(bucket.isEstimated)
    }

    func testFetch_superGrokPlan_withEmptyLog_reportsZeroUsedAndFullHeadroom() async throws {
        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .superGrokHeavy, mgmtKey: nil)

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.estimated)
        XCTAssertEqual(snapshot.buckets.count, 1)
        let bucket = snapshot.buckets[0]
        XCTAssertEqual(bucket.usedValue, 0)
        XCTAssertEqual(bucket.limitValue ?? -1, 400, accuracy: 0.0001)
        XCTAssertEqual(bucket.remainingValue ?? -1, 400, accuracy: 0.0001)
    }

    // MARK: - Credential read: adapter probes secret store, absent stays nil

    /// A genuinely missing Cursor-connector secret must still be observed by
    /// the adapter instead of being skipped. The cross-platform quota seam now
    /// reads through `ProviderQuotaAdapterContext.secretStore`; when that store
    /// resolves nil, the adapter degrades to the "add a key" unavailable
    /// snapshot without throwing or crashing.
    func testCursorConnectorKeyRead_missingSecret_isObservedAndDegradesGracefully() async throws {
        let secretStore = CountingXAISecretStore(value: nil)
        let adapter = XAIQuotaAdapter()
        // No resolved key, no env override: the Cursor-connector secret-store
        // fallback is the only source the adapter can read.
        let context = try makeContext(plan: .grokBuild, mgmtKey: nil, secretStore: secretStore)

        let snapshot = try await adapter.fetch(context: context)

        // The read actually reached the injected store; it was not skipped or
        // short-circuited before trying the Cursor-connector fallback.
        XCTAssertGreaterThanOrEqual(
            secretStore.readCallCount,
            1,
            "Expected the management-key secret read to reach the injected store"
        )
        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.unavailable)
        XCTAssertEqual(snapshot.statusMessage?.contains("Management Key"), true)
    }

    /// When the Cursor-connector secret is present, it should satisfy the
    /// management-key requirement and let the adapter hit the management API.
    func testCursorConnectorKeyRead_presentSecret_usesManagementAPI() async throws {
        let secretStore = CountingXAISecretStore(value: "xai-mgmt-from-secret-store")
        let teamsJSON = #"{ "teams": [ { "id": "team_42", "name": "Acme" } ] }"#
        let balanceJSON = #"{ "total": { "val": "-250" } }"#
        let usageJSON = #"{ "timeSeries": [] }"#
        XAIMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            switch url {
            case "https://api.x.ai/v1/teams":
                return Self.respond(json: teamsJSON, for: request)
            case "https://api.x.ai/v1/billing/teams/team_42/prepaid/balance":
                return Self.respond(json: balanceJSON, for: request)
            case "https://api.x.ai/v1/billing/teams/team_42/usage":
                return Self.respond(json: usageJSON, for: request)
            default:
                return Self.respond(status: 404, json: "{}", for: request)
            }
        }

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .grokBuild, mgmtKey: nil, secretStore: secretStore)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertGreaterThanOrEqual(
            secretStore.readCallCount,
            1,
            "Expected the management-key secret read to reach the injected store"
        )
        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.exact)
    }

    /// Direct proof at the accessor seam: a faulting backend yields nil
    /// (caught + logged) without propagating the error. Uses an isolated
    /// service with no legacy fallbacks so the read path is deterministic.
    func testCredentialIfPresent_faultReturnsNilWithoutThrowing() {
        let backend = FaultInjectingXAIKeychainBackend(
            behavior: .fault(KeychainStoreError.unhandled(errSecNotAvailable))
        )
        let keychain = KeychainStore(
            service: "com.openburnbar.xai-quota-credential-read-tests",
            legacyServices: [],
            backend: backend
        )

        var value: String?
        XCTAssertNoThrow(
            value = keychain.credentialIfPresent(
                for: "provider.xai.managementKey",
                allowUserInteraction: false,
                event: "xai_quota_management_key_read_failed"
            )
        )

        XCTAssertNil(value)
        XCTAssertGreaterThanOrEqual(backend.dataCallCount, 1)
    }

    // MARK: - Branch 1: HTTP error → unavailable

    func testFetch_grokBuildPlan_returnsUnavailableWhenTeamsEndpointRejects() async throws {
        XAIMockURLProtocol.responder = { request in
            Self.respond(status: 401, json: #"{ "error": { "message": "Invalid key" } }"#, for: request)
        }

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .grokBuild, mgmtKey: "xai-mgmt-bad")

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, AgentProvider.xAI.rawValue)
        XCTAssertEqual(snapshot.confidence, ProviderQuotaConfidence.unavailable)
    }

    // MARK: - Helpers

    private func makeContext(
        plan: XAIQuotaPlanTier,
        mgmtKey: String?,
        secretStore: any SecretStore = NoOpSecretStore()
    ) throws -> ProviderQuotaAdapterContext {
        // Use a temp-scoped app-support root so the resolved-team-id scratch
        // cache is isolated per test and never short-circuits the mocked
        // `/v1/teams` resolution with a value left over from a prior run.
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: tempDirectoryURL)
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XAIMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var resolvedKeys: [String: String?] = [:]
        if let mgmtKey {
            resolvedKeys["xai_management_key"] = mgmtKey
        }

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
            xaiPlan: plan,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: resolvedKeys,
            secretStore: secretStore
        )
    }

    /// Write a populated SuperGrok event log to the temp home directory
    /// so the pacing branch has something to read.
    private func writeSuperGrokLog(events: [Date]) throws {
        let url = XAIQuotaAdapter.superGrokLogURL(homeDirectoryURL: tempDirectoryURL)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let lines = events.map { date -> String in
            let ms = Int(date.timeIntervalSince1970 * 1000)
            return "{\"plan\":\"superGrok\",\"timestamp\":\(ms)}"
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func respond(
        status: Int = 200,
        json: String,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, json.data(using: .utf8) ?? Data())
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Secret-store seam used by XAI adapter tests to prove the Cursor-connector
/// management-key fallback was actually reached.
private final class CountingXAISecretStore: SecretStore, @unchecked Sendable {
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

/// A `KeychainStoreBackend` used to drive the management-key read down either
/// the genuine-fault path (throws) or the genuinely-absent path (returns nil),
/// while counting reads so tests can prove the read actually reached the
/// backend.
private final class FaultInjectingXAIKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    enum Behavior {
        case fault(Error)
        case absent
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var _dataCallCount = 0

    var dataCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _dataCallCount
    }

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func set(_ value: Data, service: String, account: String) throws {
        throw KeychainStoreError.unhandled(errSecNotAvailable)
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        lock.lock()
        _dataCallCount += 1
        lock.unlock()
        switch behavior {
        case .fault(let error):
            throw error
        case .absent:
            return nil
        }
    }

    func delete(service: String, account: String) throws {}
}

private final class XAIMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
