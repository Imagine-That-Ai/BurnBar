import Foundation
import GRDB
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBar
@testable import OpenBurnBarQuota

private typealias ProviderQuotaBucket = OpenBurnBar.ProviderQuotaBucket
private typealias ProviderQuotaSnapshot = OpenBurnBar.ProviderQuotaSnapshot

/// Adaptive quota TTL cases extracted from `ProviderQuotaServiceTests` so that
/// type-body length stays under the SwiftLint `--strict` ratchet.
@MainActor
final class ProviderQuotaRefreshTTLTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        ProviderQuotaRefreshTTLStubURLProtocol.requestHandler = nil
        MainActor.assumeIsolated {
            OpenBurnBarDaemonManager.shared.providerConfigurations = []
        }
        try super.tearDownWithError()
    }

    func test_refreshIfNeeded_skipsHighRemainingSnapshotsPastGlobalMaxAge() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let fetchedAt = Date().addingTimeInterval(-20 * 60)
        ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default).persistSnapshots([
            .warp: ProviderQuotaSnapshot(
                provider: .warp,
                fetchedAt: fetchedAt,
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Fresh high remaining.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "credits",
                        label: "Credits",
                        windowKind: .monthly,
                        usedValue: 10,
                        limitValue: 100,
                        remainingValue: 90,
                        usedPercent: 10,
                        resetsAt: nil,
                        unit: .requests,
                        isEstimated: false
                    )
                ]
            )
        ])

        let warpDirectory = home
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDirectory, withIntermediateDirectories: true)
        try Data("Body {\"batch\":[]}".utf8).write(to: warpDirectory.appendingPathComponent("warp_network.log"))

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            refreshProviders: [.warp]
        )
        await service.refreshIfNeeded(dataStore: try makeDataStore(), maxAge: 300)
        let snapshot = try XCTUnwrap(service.snapshot(for: .warp))
        XCTAssertEqual(
            snapshot.fetchedAt.timeIntervalSince1970,
            fetchedAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func test_refreshIfNeeded_refreshesLowRemainingSnapshotsInsideGlobalMaxAge() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let fetchedAt = Date().addingTimeInterval(-4 * 60)
        ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default).persistSnapshots([
            .warp: ProviderQuotaSnapshot(
                provider: .warp,
                fetchedAt: fetchedAt,
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Low remaining.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "credits",
                        label: "Credits",
                        windowKind: .monthly,
                        usedValue: 90,
                        limitValue: 100,
                        remainingValue: 10,
                        usedPercent: 90,
                        resetsAt: nil,
                        unit: .requests,
                        isEstimated: false
                    )
                ]
            )
        ])

        let warpDirectory = home
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDirectory, withIntermediateDirectories: true)
        try Data("Body {\"batch\":[]}".utf8).write(to: warpDirectory.appendingPathComponent("warp_network.log"))

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            refreshProviders: [.warp]
        )
        await service.refreshIfNeeded(dataStore: try makeDataStore(), maxAge: 300)
        let snapshot = try XCTUnwrap(service.snapshot(for: .warp))
        XCTAssertGreaterThan(snapshot.fetchedAt.timeIntervalSince(fetchedAt), 1)
    }

    func test_refreshIfNeeded_coalescesConcurrentAdaptiveRefreshes() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        try persistSnapshot(
            provider: .minimax,
            fetchedAt: Date().addingTimeInterval(-4 * 60),
            remaining: 10,
            appSupportRoot: appSupport
        )
        let gate = QuotaRefreshRequestGate(blockedPath: "/v1/api/openplatform/coding_plan/remains")
        let service = try makeNetworkService(
            home: home,
            appSupportRoot: appSupport,
            providers: [.minimax],
            apiKeys: ["minimax": "mm-token"],
            gate: gate
        )
        let dataStore = try makeDataStore()

        let first = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await waitForRequestCount(1, path: gate.blockedPath, gate: gate)
        let second = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        await first.value
        await second.value

        XCTAssertEqual(gate.requestCount(for: gate.blockedPath), 1)
    }

    func test_refreshAll_reusesOverlappingAdaptiveRefreshAndFetchesOnlyRemainder() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let now = Date()
        try persistSnapshots(
            [
                makeSnapshot(provider: .minimax, fetchedAt: now.addingTimeInterval(-4 * 60), remaining: 10),
                makeSnapshot(provider: .deepSeek, fetchedAt: now, remaining: 90)
            ],
            appSupportRoot: appSupport
        )
        let miniMaxPath = "/v1/api/openplatform/coding_plan/remains"
        let deepSeekPath = "/user/balance"
        let gate = QuotaRefreshRequestGate(blockedPath: miniMaxPath)
        let service = try makeNetworkService(
            home: home,
            appSupportRoot: appSupport,
            providers: [.minimax, .deepSeek],
            apiKeys: [
                "minimax": "mm-token",
                "deepseek": "deepseek-token"
            ],
            gate: gate
        )
        let dataStore = try makeDataStore()

        let adaptive = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await waitForRequestCount(1, path: miniMaxPath, gate: gate)
        let full = Task { await service.refreshAll(dataStore: dataStore) }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        await adaptive.value
        await full.value

        XCTAssertEqual(gate.requestCount(for: miniMaxPath), 1)
        XCTAssertEqual(gate.requestCount(for: deepSeekPath), 1)
    }

    func test_refreshIfNeeded_reusesOverlappingFullRefresh() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let now = Date()
        try persistSnapshots(
            [
                makeSnapshot(provider: .minimax, fetchedAt: now.addingTimeInterval(-4 * 60), remaining: 10),
                makeSnapshot(provider: .deepSeek, fetchedAt: now, remaining: 90)
            ],
            appSupportRoot: appSupport
        )
        let miniMaxPath = "/v1/api/openplatform/coding_plan/remains"
        let deepSeekPath = "/user/balance"
        let gate = QuotaRefreshRequestGate(blockedPath: miniMaxPath)
        let service = try makeNetworkService(
            home: home,
            appSupportRoot: appSupport,
            providers: [.minimax, .deepSeek],
            apiKeys: [
                "minimax": "mm-token",
                "deepseek": "deepseek-token"
            ],
            gate: gate
        )
        let dataStore = try makeDataStore()

        let full = Task { await service.refreshAll(dataStore: dataStore) }
        try await waitForRequestCount(1, path: miniMaxPath, gate: gate)
        let adaptive = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        await full.value
        await adaptive.value

        XCTAssertEqual(gate.requestCount(for: miniMaxPath), 1)
        XCTAssertEqual(gate.requestCount(for: deepSeekPath), 1)
    }

    private func makeService(
        home: URL,
        appSupportRoot: URL,
        keyStore: ProviderAPIKeyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(
                service: "tests.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaRefreshTTLKeychainBackend()
            )
        ),
        session: URLSession = .shared,
        miniMaxModeProvider: @escaping @MainActor () -> MiniMaxQuotaMode = { .payAsYouGo },
        refreshProviders: [AgentProvider]
    ) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: keyStore,
            providerRuntimeKeyStore: KeychainStore(
                service: "tests.runtime.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaRefreshTTLKeychainBackend()
            ),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: session,
            environment: [:],
            homeDirectoryURL: home,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: { .unknown },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            refreshProviders: refreshProviders
        )
    }

    private func makeNetworkService(
        home: URL,
        appSupportRoot: URL,
        providers: [AgentProvider],
        apiKeys: [String: String],
        gate: QuotaRefreshRequestGate,
        keyStore suppliedKeyStore: ProviderAPIKeyStore? = nil,
        responseBody: (@Sendable (URLRequest) throws -> String)? = nil
    ) throws -> ProviderQuotaService {
        let keyStore = suppliedKeyStore ?? ProviderAPIKeyStore(
            keychain: KeychainStore(
                service: "tests.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaRefreshTTLKeychainBackend()
            )
        )
        for (provider, apiKey) in apiKeys {
            try keyStore.setAPIKey(apiKey, for: provider)
        }
        ProviderQuotaRefreshTTLStubURLProtocol.requestHandler = { request in
            gate.record(request)
            let body: String
            if let responseBody {
                body = try responseBody(request)
            } else if request.url?.path == gate.blockedPath {
                body = """
                {
                  "model_remains": [{
                    "model_name": "MiniMax-M2.7",
                    "current_interval_total_count": 100,
                    "current_interval_usage_count": 90
                  }]
                }
                """
            } else if request.url?.path == "/user/balance" {
                body = """
                {
                  "is_available": true,
                  "balance_infos": [{
                    "currency": "USD",
                    "total_balance": "42.50"
                  }]
                }
                """
            } else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderQuotaRefreshTTLStubURLProtocol.self]
        return makeService(
            home: home,
            appSupportRoot: appSupportRoot,
            keyStore: keyStore,
            session: URLSession(configuration: configuration),
            miniMaxModeProvider: { .tokenPlan },
            refreshProviders: providers
        )
    }

    private func persistSnapshot(
        provider: AgentProvider,
        fetchedAt: Date,
        remaining: Double,
        appSupportRoot: URL
    ) throws {
        try persistSnapshots(
            [makeSnapshot(provider: provider, fetchedAt: fetchedAt, remaining: remaining)],
            appSupportRoot: appSupportRoot
        )
    }

    private func persistSnapshots(
        _ snapshots: [ProviderQuotaSnapshot],
        appSupportRoot: URL
    ) throws {
        let paths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
        let snapshotsByProvider = try Dictionary(
            uniqueKeysWithValues: snapshots.map { snapshot in
                (try XCTUnwrap(snapshot.quotaProvider), snapshot)
            }
        )
        ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default).persistSnapshots(
            snapshotsByProvider
        )
    }

    private func makeSnapshot(
        provider: AgentProvider,
        fetchedAt: Date,
        remaining: Double
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: fetchedAt,
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "",
            buckets: [
                ProviderQuotaBucket(
                    key: "quota",
                    label: "Quota",
                    windowKind: .monthly,
                    usedValue: 100 - remaining,
                    limitValue: 100,
                    remainingValue: remaining,
                    usedPercent: 100 - remaining,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
            ]
        )
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        path: String,
        gate: QuotaRefreshRequestGate
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while gate.requestCount(for: path) < expectedCount, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(gate.requestCount(for: path), expectedCount)
    }

    private func makeDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }
}

@MainActor
extension ProviderQuotaRefreshTTLTests {
    func test_refreshAll_fullyCoveredByAdaptiveRefresh_stillSweepsEveryCredentialSlot() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            makeSlotConfiguration(providerID: "minimax", slotID: "current"),
            makeSlotConfiguration(providerID: "deepseek", slotID: "current")
        ]
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        try await dataStore.upsertProviderAccount(
            ProviderAccountDoc(
                id: "deepseek-removed",
                providerID: AgentProvider.deepSeek.providerID,
                label: "Removed",
                identityHint: "Daemon credential slot",
                status: .connected,
                credentialKind: .bearer,
                storageScope: .deviceKeychain,
                redactedLabel: "Stored in Mac Keychain",
                isDefault: true,
                sortKey: 0,
                schemaVersion: 1,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
        try persistSnapshot(
            provider: .minimax,
            fetchedAt: Date().addingTimeInterval(-4 * 60),
            remaining: 10,
            appSupportRoot: appSupport
        )
        let gate = QuotaRefreshRequestGate(blockedPath: "/v1/api/openplatform/coding_plan/remains")
        let service = try makeNetworkService(
            home: home,
            appSupportRoot: appSupport,
            providers: [.minimax],
            apiKeys: ["minimax": "mm-token"],
            gate: gate
        )

        let adaptive = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await waitForRequestCount(1, path: gate.blockedPath, gate: gate)
        let full = Task { await service.refreshAll(dataStore: dataStore) }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        await adaptive.value
        await full.value

        let accounts = try await dataStore.fetchProviderAccounts(providerID: AgentProvider.deepSeek.providerID)
        XCTAssertEqual(accounts.first { $0.id == "deepseek-current" }?.status, .connected)
        let removed = try XCTUnwrap(accounts.first { $0.id == "deepseek-removed" })
        XCTAssertEqual(removed.status, .deleted)
        XCTAssertEqual(removed.lastErrorCode, "credential_slot_removed")
    }

    func test_cancelledFullRefresh_waitingOnAdaptiveRefresh_doesNotLaunchRemainder() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let now = Date()
        try persistSnapshots(
            [
                makeSnapshot(provider: .minimax, fetchedAt: now.addingTimeInterval(-4 * 60), remaining: 10),
                makeSnapshot(provider: .deepSeek, fetchedAt: now, remaining: 90)
            ],
            appSupportRoot: appSupport
        )
        let miniMaxPath = "/v1/api/openplatform/coding_plan/remains"
        let deepSeekPath = "/user/balance"
        let gate = QuotaRefreshRequestGate(blockedPath: miniMaxPath)
        let service = try makeNetworkService(
            home: home,
            appSupportRoot: appSupport,
            providers: [.minimax, .deepSeek],
            apiKeys: [
                "minimax": "mm-token",
                "deepseek": "deepseek-token"
            ],
            gate: gate
        )
        let dataStore = try makeDataStore()

        let adaptive = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await waitForRequestCount(1, path: miniMaxPath, gate: gate)
        let full = Task { await service.refreshAll(dataStore: dataStore) }
        try await Task.sleep(for: .milliseconds(100))
        full.cancel()
        gate.open()
        await adaptive.value
        await full.value

        XCTAssertEqual(gate.requestCount(for: miniMaxPath), 1)
        XCTAssertEqual(gate.requestCount(for: deepSeekPath), 0)
    }

    func test_credentialChangeRefresh_waitsForOldRequestThenRerunsWithNewCredential() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        try persistSnapshot(
            provider: .minimax,
            fetchedAt: Date().addingTimeInterval(-4 * 60),
            remaining: 10,
            appSupportRoot: appSupport
        )
        let keyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(
                service: "tests.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaRefreshTTLKeychainBackend()
            )
        )
        let path = "/v1/api/openplatform/coding_plan/remains"
        let gate = QuotaRefreshRequestGate(blockedPath: path)
        let service = try makeNetworkService(
            home: home,
            appSupportRoot: appSupport,
            providers: [.minimax],
            apiKeys: ["minimax": "old-token"],
            gate: gate,
            keyStore: keyStore,
            responseBody: { request in
                let remaining = request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token"
                    ? 80
                    : 10
                return """
                {
                  "model_remains": [{
                    "model_name": "MiniMax-M2.7",
                    "current_interval_total_count": 100,
                    "current_interval_usage_count": \(remaining)
                  }]
                }
                """
            }
        )
        let dataStore = try makeDataStore()
        service.startAutomaticRefresh(
            dataStore: dataStore,
            initialDelay: .seconds(3_600),
            interval: .seconds(3_600)
        )
        defer { service.stopAutomaticRefresh() }

        let adaptive = Task { await service.refreshIfNeeded(dataStore: dataStore) }
        try await waitForRequestCount(1, path: path, gate: gate)
        try keyStore.setAPIKey("new-token", for: "minimax")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            gate.requestCount(for: path),
            1,
            "The credential-change refresh must wait for the old-key batch."
        )

        gate.open()
        await adaptive.value
        try await waitForRequestCount(2, path: path, gate: gate)
        try await waitForRemaining(80, provider: .minimax, service: service)

        XCTAssertEqual(
            gate.authorizationHeaders(for: path),
            ["Bearer old-token", "Bearer new-token"]
        )
    }

    private func makeSlotConfiguration(
        providerID: String,
        slotID: String
    ) -> OpenBurnBarDaemonProviderConfiguration {
        OpenBurnBarDaemonProviderConfiguration(
            providerID: providerID,
            provider: nil,
            displayName: providerID,
            isEnabled: true,
            baseURL: "https://\(providerID).example/v1",
            preferredModelIDs: [],
            preferredCredentialSlotID: slotID,
            credentialSlots: [
                OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                    slotID: slotID,
                    label: "Current",
                    isEnabled: true,
                    status: .ready,
                    cooldownUntil: nil,
                    lastSelectedAt: nil,
                    lastQuotaRemainingPercent: nil,
                    lastQuotaResetsAt: nil,
                    lastStatusMessage: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            ]
        )
    }

    private func waitForRemaining(
        _ expected: Double,
        provider: AgentProvider,
        service: ProviderQuotaService
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while service.snapshot(for: provider)?.primaryDisplayableBucket?.remainingValue != expected,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            service.snapshot(for: provider)?.primaryDisplayableBucket?.remainingValue,
            expected
        )
    }
}

private final class QuotaRefreshRequestGate: @unchecked Sendable {
    let blockedPath: String
    private let condition = NSCondition()
    private var isOpen = false
    private var requestCounts: [String: Int] = [:]
    private var authorizationHeadersByPath: [String: [String]] = [:]

    init(blockedPath: String) {
        self.blockedPath = blockedPath
    }

    func record(_ request: URLRequest) {
        condition.lock()
        let path = request.url?.path ?? ""
        requestCounts[path, default: 0] += 1
        authorizationHeadersByPath[path, default: []].append(
            request.value(forHTTPHeaderField: "Authorization") ?? ""
        )
        condition.broadcast()
        while path == blockedPath, !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func requestCount(for path: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return requestCounts[path, default: 0]
    }

    func authorizationHeaders(for path: String) -> [String] {
        condition.lock()
        defer { condition.unlock() }
        return authorizationHeadersByPath[path, default: []]
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ProviderQuotaRefreshTTLStubURLProtocol: URLProtocol {
    private static let handlerBox = Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerBox.read() }
        set { handlerBox.write(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ProviderQuotaRefreshTTLKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}
