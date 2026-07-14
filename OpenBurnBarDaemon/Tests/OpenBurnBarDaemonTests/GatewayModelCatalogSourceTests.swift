import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
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
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
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
            lock.lock(); _count += 1; lock.unlock()
            return result
        }
    }

    private func makeConfigStore() throws -> BurnBarConfigStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-catalog-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return BurnBarConfigStore(
            fileURL: dir.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
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
        cacheTTL: TimeInterval
    ) -> GatewayModelCatalogSource {
        GatewayModelCatalogSource(
            configStore: configStore,
            session: URLSession(configuration: .ephemeral),
            droidProcessRunner: droidRunner,
            modelHealthStore: BurnBarGatewayModelHealthStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("obb-catalog-source-health-\(UUID().uuidString).json")
            ),
            cacheTTL: cacheTTL,
            logger: BurnBarDaemonLogger(category: "catalog-source-tests")
        )
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
}
