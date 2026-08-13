import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Characterizes `GatewayModelCatalogSource` — the collaborator extracted from
/// BurnBarHTTPGatewayServer that owns the live model-catalog snapshot + TTL cache.
///
/// The TTL cache path is the source's reason to exist yet was DEAD UNDER TEST in
/// the gateway suite (both harness constructors default `modelCatalogCacheTTL` to
/// 0, so the cache branch never executed). These tests pin it directly: a
/// Factory provider makes `snapshot()` fan out through the droid runner, so a
/// call-counting runner observes exactly how often the expensive fan-out fires.
final class GatewayModelCatalogSourceTests: XCTestCase {

    /// A droid runner that COUNTS invocations (the shared RecordingFactoryDroidRunner
    /// only retains the last call), so we can assert cache hits vs fan-outs.
    private final class CountingDroidRunner: FactoryDroidProcessRunning, @unchecked Sendable {
        private let invocationCount = Locked(0)
        var count: Int { invocationCount.read() }
        private let result: FactoryDroidProcessResult

        init() {
            result = FactoryDroidProcessResult(
                exitCode: 0,
                stdout: """
                Available Models:
                  gpt-5.5                                                   GPT-5.5
                  glm-5.1                                                   Droid Core (GLM-5.1)
                """,
                stderr: ""
            )
        }

        func runDroid(arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> FactoryDroidProcessResult {
            invocationCount.withLock { $0 += 1 }
            return result
        }
    }

    private actor RevisionTrackingSecretStore: BurnBarProviderSecretStoring {
        private var secrets: [String: String] = [:]
        private var revision: UInt64 = 0

        func secret(for providerID: String) async throws -> String? {
            secrets[providerID]
        }

        func setSecret(_ secret: String?, for providerID: String) async throws {
            if let secret {
                secrets[providerID] = secret
            } else {
                secrets.removeValue(forKey: providerID)
            }
        }

        func credentialReplacementRevision() async -> UInt64 {
            revision
        }

        func replaceCredentialOutOfBand(_ secret: String, for providerID: String) {
            secrets[providerID] = secret
            revision &+= 1
        }
    }

    private final class AnthropicCredentialURLProtocol: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var authorizationHeaders: [String] = []
        nonisolated(unsafe) private static var blockedStaleRequestStarted: DispatchSemaphore?
        nonisolated(unsafe) private static var blockedStaleResponseRelease: DispatchSemaphore?

        static func reset() {
            lock.lock()
            authorizationHeaders = []
            blockedStaleRequestStarted = nil
            blockedStaleResponseRelease = nil
            lock.unlock()
        }

        static func prepareBlockedStaleRequest() {
            lock.lock()
            blockedStaleRequestStarted = DispatchSemaphore(value: 0)
            blockedStaleResponseRelease = DispatchSemaphore(value: 0)
            lock.unlock()
        }

        static func waitForBlockedStaleRequest() -> Bool {
            lock.lock()
            let semaphore = blockedStaleRequestStarted
            lock.unlock()
            return semaphore?.wait(timeout: .now() + 5) == .success
        }

        static func releaseBlockedStaleResponse() {
            lock.lock()
            let semaphore = blockedStaleResponseRelease
            blockedStaleResponseRelease = nil
            lock.unlock()
            semaphore?.signal()
        }

        static func recordedAuthorizationHeaders() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return authorizationHeaders
        }

        override static func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "api.anthropic.com"
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            Self.lock.lock()
            Self.authorizationHeaders.append(authorization)
            let started = authorization == "Bearer sk-ant-oat-stale"
                ? Self.blockedStaleRequestStarted
                : nil
            let release = authorization == "Bearer sk-ant-oat-stale"
                ? Self.blockedStaleResponseRelease
                : nil
            if started != nil {
                Self.blockedStaleRequestStarted = nil
            }
            Self.lock.unlock()
            started?.signal()
            if started != nil {
                _ = release?.wait(timeout: .now() + 5)
            }

            let authorized = authorization == "Bearer sk-ant-oat-fresh"
            let body = authorized
                ? #"{"data":[{"id":"claude-opus-4-8","display_name":"Claude Opus 4.8","type":"model"}],"has_more":false}"#
                : #"{"error":{"message":"Invalid authentication credentials"}}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: authorized ? 200 : 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeConfigStore(
        secretStore: any BurnBarProviderSecretStoring = BurnBarInMemorySecretStore()
    ) throws -> BurnBarConfigStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-catalog-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return BurnBarConfigStore(
            fileURL: dir.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "catalog-source-tests")
        )
    }

    private func configureFactory(_ configStore: BurnBarConfigStore) async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "factory",
            slotID: "max",
            label: "Factory Max",
            apiKey: "fk-gateway"
        )
    }

    private func makeSource(
        configStore: BurnBarConfigStore,
        droidRunner: any FactoryDroidProcessRunning,
        cacheTTL: TimeInterval,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) -> GatewayModelCatalogSource {
        GatewayModelCatalogSource(
            configStore: configStore,
            session: session,
            droidProcessRunner: droidRunner,
            modelHealthStore: BurnBarGatewayModelHealthStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("obb-catalog-source-health-\(UUID().uuidString).json")
            ),
            cacheTTL: cacheTTL,
            logger: BurnBarDaemonLogger(category: "catalog-source-tests")
        )
    }

    private func factoryAccount(
        in snapshot: BurnBarLiveModelCatalogSnapshot
    ) throws -> BurnBarLiveModelAccountDescriptor {
        try XCTUnwrap(snapshot.accounts.first {
            $0.providerID == "factory" && $0.accountID == "max"
        })
    }

    private func factoryModel(
        in snapshot: BurnBarLiveModelCatalogSnapshot,
        id: String = "gpt-5.5"
    ) throws -> BurnBarLiveAdvertisedModel {
        try XCTUnwrap(snapshot.models.first {
            $0.providerID == "factory" && $0.accountID == "max" && $0.id == id
        })
    }

    func test_cacheTTLZero_fansOutEveryCall() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 0)

        _ = try await source.snapshot()
        _ = try await source.snapshot()

        XCTAssertEqual(droid.count, 2, "TTL=0 must reproduce the uncached per-call fan-out byte-for-byte")
    }

    func test_cacheTTLPositive_reusesSnapshotWithinWindow() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 600)

        let first = try await source.snapshot()
        let second = try await source.snapshot()

        XCTAssertEqual(droid.count, 1, "a fresh snapshot within the TTL must serve from cache, not refan-out")
        XCTAssertEqual(
            first.models.map(\.id).sorted(),
            second.models.map(\.id).sorted(),
            "cached snapshot must be identical to the freshly built one"
        )
    }

    func test_configChange_invalidatesCacheImmediately() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 600)

        _ = try await source.snapshot()
        XCTAssertEqual(droid.count, 1)

        // A provider/credential edit changes the config snapshot identity (the
        // cache key), so the very next snapshot must re-fan-out even within TTL.
        _ = try await configStore.upsertCredentialSlot(
            providerID: "factory",
            slotID: "max",
            label: "Factory Max (rotated)",
            apiKey: "fk-gateway-rotated"
        )
        _ = try await source.snapshot()

        XCTAssertEqual(droid.count, 2, "a config edit must invalidate the catalog cache immediately")
    }

    func test_cachedAnthropicAuthenticationFailureIsDiscardedImmediatelyAfterOutOfBandCredentialReplacement() async throws {
        AnthropicCredentialURLProtocol.reset()
        defer { AnthropicCredentialURLProtocol.reset() }
        let secretStore = RevisionTrackingSecretStore()
        let configStore = try makeConfigStore(secretStore: secretStore)
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-8"],
                preferredCredentialSlotID: "max"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "max",
            label: "Anthropic Max",
            apiKey: "sk-ant-oat-stale"
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AnthropicCredentialURLProtocol.self]
        let source = makeSource(
            configStore: configStore,
            droidRunner: CountingDroidRunner(),
            cacheTTL: 600,
            session: URLSession(configuration: sessionConfiguration)
        )

        let blocked = try await source.snapshot()
        let blockedModel = try XCTUnwrap(blocked.models.first {
            $0.providerID == "anthropic" && $0.accountID == "max" && $0.id == "claude-opus-4-8"
        })
        XCTAssertFalse(blockedModel.routeEligible)
        XCTAssertEqual(
            AnthropicCredentialURLProtocol.recordedAuthorizationHeaders(),
            ["Bearer sk-ant-oat-stale"]
        )

        await secretStore.replaceCredentialOutOfBand(
            "sk-ant-oat-fresh",
            for: "anthropic.slot.max"
        )

        let recovered = try await source.snapshot()
        let recoveredModel = try XCTUnwrap(recovered.models.first {
            $0.providerID == "anthropic" && $0.accountID == "max" && $0.id == "claude-opus-4-8"
        })
        XCTAssertTrue(recoveredModel.routeEligible)
        XCTAssertNil(recoveredModel.lastError)
        XCTAssertEqual(
            AnthropicCredentialURLProtocol.recordedAuthorizationHeaders(),
            ["Bearer sk-ant-oat-stale", "Bearer sk-ant-oat-fresh"],
            "the credential replacement revision must bypass the cached 401 immediately"
        )
    }

    func test_credentialReplacementDuringFreshDiscoveryRetriesBeforeCaching() async throws {
        AnthropicCredentialURLProtocol.reset()
        AnthropicCredentialURLProtocol.prepareBlockedStaleRequest()
        defer {
            AnthropicCredentialURLProtocol.releaseBlockedStaleResponse()
            AnthropicCredentialURLProtocol.reset()
        }
        let secretStore = RevisionTrackingSecretStore()
        let configStore = try makeConfigStore(secretStore: secretStore)
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-8"],
                preferredCredentialSlotID: "max"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "max",
            label: "Anthropic Max",
            apiKey: "sk-ant-oat-stale"
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AnthropicCredentialURLProtocol.self]
        let source = makeSource(
            configStore: configStore,
            droidRunner: CountingDroidRunner(),
            cacheTTL: 600,
            session: URLSession(configuration: sessionConfiguration)
        )

        let snapshotTask = Task {
            try await source.snapshot()
        }
        XCTAssertTrue(
            AnthropicCredentialURLProtocol.waitForBlockedStaleRequest(),
            "the first discovery request must reach the stale credential before rotation"
        )
        await secretStore.replaceCredentialOutOfBand(
            "sk-ant-oat-fresh",
            for: "anthropic.slot.max"
        )
        AnthropicCredentialURLProtocol.releaseBlockedStaleResponse()

        let recovered = try await snapshotTask.value
        let recoveredModel = try XCTUnwrap(recovered.models.first {
            $0.providerID == "anthropic" && $0.accountID == "max" && $0.id == "claude-opus-4-8"
        })
        XCTAssertTrue(recoveredModel.routeEligible)
        XCTAssertNil(recoveredModel.lastError)
        XCTAssertEqual(
            AnthropicCredentialURLProtocol.recordedAuthorizationHeaders(),
            ["Bearer sk-ant-oat-stale", "Bearer sk-ant-oat-fresh"],
            "a mid-flight credential replacement must rediscover before the result is returned or cached"
        )
    }

    func test_transientCredentialHealthReprojectsReadyCoolingDownAndReadyWithoutRediscovery() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 600)

        let ready = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: ready).quotaState, .healthy)
        XCTAssertEqual(try factoryModel(in: ready).routeEligible, true)

        try await configStore.updateCredentialSlotStatus(
            providerID: "factory",
            slotID: "max",
            status: .coolingDown,
            cooldownUntil: Date().addingTimeInterval(60),
            message: "retry later"
        )
        let coolingDown = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: coolingDown).quotaState, .coolingDown)
        XCTAssertEqual(try factoryAccount(in: coolingDown).lastError, "retry later")
        XCTAssertEqual(try factoryModel(in: coolingDown).quotaState, .coolingDown)
        XCTAssertEqual(try factoryModel(in: coolingDown).routeEligible, false)

        try await configStore.updateCredentialSlotStatus(
            providerID: "factory",
            slotID: "max",
            status: .ready,
            cooldownUntil: nil,
            message: nil
        )
        let recovered = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: recovered).quotaState, .healthy)
        XCTAssertNil(try factoryAccount(in: recovered).lastError)
        XCTAssertEqual(try factoryModel(in: recovered).routeEligible, true)

        XCTAssertEqual(
            droid.count,
            1,
            "credential-health projection must stay fresh without repeating expensive discovery"
        )
    }

    func test_transientCredentialQuotaReprojectsExhaustionAndRecoveryWithoutRediscovery() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 600)

        _ = try await source.snapshot()
        try await configStore.updateCredentialSlotQuota(
            providerID: "factory",
            slotID: "max",
            remainingPercent: 0,
            resetsAt: nil,
            message: "quota exhausted"
        )
        let exhausted = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: exhausted).quotaState, .exhausted)
        XCTAssertEqual(try factoryAccount(in: exhausted).quotaRemainingPercent, 0)
        XCTAssertEqual(try factoryModel(in: exhausted).quotaState, .exhausted)
        XCTAssertEqual(try factoryModel(in: exhausted).routeEligible, false)

        try await configStore.updateCredentialSlotQuota(
            providerID: "factory",
            slotID: "max",
            remainingPercent: 80,
            resetsAt: nil,
            message: "quota recovered"
        )
        let recovered = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: recovered).quotaState, .healthy)
        XCTAssertEqual(try factoryAccount(in: recovered).quotaRemainingPercent, 80)
        XCTAssertEqual(try factoryModel(in: recovered).quotaState, .healthy)
        XCTAssertEqual(try factoryModel(in: recovered).routeEligible, true)
        XCTAssertEqual(droid.count, 1, "quota transitions must not repeat provider discovery")
    }

    func test_recordCredentialSelectionReprojectsReadyStateWithoutRediscovery() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 600)

        _ = try await source.snapshot()
        try await configStore.updateCredentialSlotStatus(
            providerID: "factory",
            slotID: "max",
            status: .coolingDown,
            cooldownUntil: Date().addingTimeInterval(60),
            message: "retry later"
        )
        let coolingDown = try await source.snapshot()
        XCTAssertEqual(try factoryModel(in: coolingDown).routeEligible, false)

        try await configStore.recordCredentialSelection(
            providerID: "factory",
            slotID: "max"
        )
        let restored = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: restored).quotaState, .healthy)
        XCTAssertEqual(try factoryModel(in: restored).routeEligible, true)
        XCTAssertEqual(droid.count, 1, "selection bookkeeping must reuse provider discovery")
    }

    func test_modelHealthDoesNotBlockCurrentClaudeCodeSlotOnAuthFailure() async throws {
        let store = BurnBarGatewayModelHealthStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("obb-current-claude-health-\(UUID().uuidString).json")
        )
        let route = BurnBarProviderRoute(
            providerID: "anthropic",
            providerDisplayName: "Anthropic",
            credentialSlotID: "current-claude-code-login",
            credentialSlotLabel: "Current Claude Code login",
            baseURL: "https://api.anthropic.com/v1",
            requestedModel: "claude-opus-4-8",
            resolvedModelID: "claude-opus-4-8",
            canonicalModelID: "claude-opus-4-8",
            apiKey: "sk-ant-oat-stale",
            pricing: BurnBarModelPricing(inputPerMToken: 0, outputPerMToken: 0, cacheReadPerMToken: 0),
            formatFamily: .anthropic
        )

        await store.recordFailure(
            modelID: "claude-opus-4-8",
            formatFamily: .anthropic,
            route: route,
            error: BurnBarProviderExecutorError.upstreamError(
                401,
                #"{"error":{"message":"Invalid authentication credentials"}}"#
            )
        )

        let failure = await store.activeFailure(
            modelID: "claude-opus-4-8",
            providerID: "anthropic",
            accountID: "current-claude-code-login",
            formatFamily: .anthropic
        )
        XCTAssertNil(failure)
    }

    func test_retiredModelFailurePersistsAcrossStoreReload() async throws {
        let healthURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-retired-model-health-\(UUID().uuidString).json")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let route = BurnBarProviderRoute(
            providerID: "ollama",
            providerDisplayName: "Ollama Cloud",
            credentialSlotID: "primary",
            credentialSlotLabel: "Primary Ollama account",
            baseURL: "https://ollama.com/api",
            requestedModel: "retired-model",
            resolvedModelID: "retired-model",
            canonicalModelID: "retired-model",
            apiKey: "ollama-test-key",
            pricing: BurnBarModelPricing(inputPerMToken: 0, outputPerMToken: 0, cacheReadPerMToken: 0),
            formatFamily: .openaiCompat
        )
        let store = BurnBarGatewayModelHealthStore(fileURL: healthURL, clock: { now })

        await store.recordFailure(
            modelID: "retired-model:cloud",
            formatFamily: .openaiCompat,
            route: route,
            error: BurnBarProviderExecutorError.upstreamError(
                410,
                #"{"error":"retired-model was retired"}"#
            )
        )

        let reloadedStore = BurnBarGatewayModelHealthStore(fileURL: healthURL, clock: { now })
        let failure = await reloadedStore.activeFailure(
            modelID: "retired-model:cloud",
            providerID: "ollama",
            accountID: "primary",
            formatFamily: .openaiCompat
        )
        XCTAssertEqual(failure?.statusCode, 410)
        XCTAssertEqual(failure?.blockedUntil, now.addingTimeInterval(24 * 60 * 60))
        XCTAssertEqual(failure?.message.contains("retired-model was retired"), true)
    }
}
