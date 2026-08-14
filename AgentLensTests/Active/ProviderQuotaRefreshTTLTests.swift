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
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
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
        gate: QuotaRefreshRequestGate
    ) throws -> ProviderQuotaService {
        let backend = ProviderQuotaRefreshTTLKeychainBackend()
        let keyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(
                service: "tests.\(UUID().uuidString)",
                legacyServices: [],
                backend: backend
            )
        )
        for (provider, apiKey) in apiKeys {
            try keyStore.setAPIKey(apiKey, for: provider)
        }
        ProviderQuotaRefreshTTLStubURLProtocol.requestHandler = { request in
            gate.record(request)
            let body: String
            switch request.url?.path {
            case gate.blockedPath:
                body = """
                {
                  "model_remains": [{
                    "model_name": "MiniMax-M2.7",
                    "current_interval_total_count": 100,
                    "current_interval_usage_count": 90
                  }]
                }
                """
            case "/user/balance":
                body = """
                {
                  "is_available": true,
                  "balance_infos": [{
                    "currency": "USD",
                    "total_balance": "42.50"
                  }]
                }
                """
            default:
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
            statusMessage: nil,
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

private final class QuotaRefreshRequestGate: @unchecked Sendable {
    let blockedPath: String
    private let condition = NSCondition()
    private var isOpen = false
    private var requestCounts: [String: Int] = [:]

    init(blockedPath: String) {
        self.blockedPath = blockedPath
    }

    func record(_ request: URLRequest) {
        condition.lock()
        let path = request.url?.path ?? ""
        requestCounts[path, default: 0] += 1
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
