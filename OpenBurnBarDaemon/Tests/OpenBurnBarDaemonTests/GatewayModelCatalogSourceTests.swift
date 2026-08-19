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
        clock: @escaping @Sendable () -> Date = { Date() }
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
            logger: BurnBarDaemonLogger(category: "catalog-source-tests"),
            clock: clock
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

    func test_defaultProductionDiscoveryTTLIsTenMinutes() {
        XCTAssertEqual(BurnBarHTTPGatewayServer.defaultModelCatalogCacheTTL, 10 * 60)
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

    func test_repeatedSnapshotsReadEachUnchangedCredentialOncePerConfigurationRevision() async throws {
        let secretStore = CountingSecretStore(
            secrets: ["factory.slot.max": "fk-gateway"]
        )
        let configStore = try makeConfigStore(secretStore: secretStore)
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max",
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "max",
                        label: "Factory Max",
                        isEnabled: true,
                        status: .ready
                    )
                ]
            )
        )
        let source = makeSource(
            configStore: configStore,
            droidRunner: CountingDroidRunner(),
            cacheTTL: 600
        )

        _ = try await source.snapshot()
        _ = try await source.snapshot()

        let readCounts = await secretStore.readCountsSnapshot()
        XCTAssertEqual(readCounts["factory.slot.max"], 1)
        XCTAssertTrue(
            readCounts.values.allSatisfy { $0 == 1 },
            "unchanged credential material must be resolved once even though catalog status is reprojected"
        )
    }

    func test_concurrentSnapshotsSingleFlightCredentialReads() async throws {
        let secretStore = CountingSecretStore(
            secrets: ["factory.slot.max": "fk-gateway"],
            readDelayNanoseconds: 20_000_000
        )
        let configStore = try makeConfigStore(secretStore: secretStore)
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max",
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "max",
                        label: "Factory Max",
                        isEnabled: true,
                        status: .ready
                    )
                ]
            )
        )
        let source = makeSource(
            configStore: configStore,
            droidRunner: CountingDroidRunner(),
            cacheTTL: 600
        )

        async let first = source.snapshot()
        async let second = source.snapshot()
        _ = try await (first, second)

        let readCounts = await secretStore.readCountsSnapshot()
        XCTAssertEqual(readCounts["factory.slot.max"], 1)
        XCTAssertTrue(
            readCounts.values.allSatisfy { $0 == 1 },
            "concurrent catalog requests must share in-flight credential reads"
        )
    }

    func test_transientStatusAndQuotaReprojectWithoutCredentialRereads() async throws {
        let secretStore = CountingSecretStore(
            secrets: ["factory.slot.max": "fk-gateway"]
        )
        let configStore = try makeConfigStore(secretStore: secretStore)
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max",
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "max",
                        label: "Factory Max",
                        isEnabled: true,
                        status: .ready
                    )
                ]
            )
        )
        let source = makeSource(
            configStore: configStore,
            droidRunner: CountingDroidRunner(),
            cacheTTL: 600
        )

        _ = try await source.snapshot()
        try await configStore.updateCredentialSlotStatus(
            providerID: "factory",
            slotID: "max",
            status: .coolingDown,
            cooldownUntil: Date().addingTimeInterval(60),
            message: "retry later"
        )
        let coolingDown = try await source.snapshot()
        XCTAssertFalse(try factoryModel(in: coolingDown).routeEligible)

        try await configStore.updateCredentialSlotStatus(
            providerID: "factory",
            slotID: "max",
            status: .ready,
            cooldownUntil: nil,
            message: nil
        )
        try await configStore.updateCredentialSlotQuota(
            providerID: "factory",
            slotID: "max",
            remainingPercent: 80,
            resetsAt: nil,
            message: "quota recovered"
        )
        let recovered = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: recovered).quotaRemainingPercent, 80)
        XCTAssertTrue(try factoryModel(in: recovered).routeEligible)

        let readCount = await secretStore.readCount(for: "factory.slot.max")
        XCTAssertEqual(
            readCount,
            1,
            "mutable status/quota projection must stay fresh without rereading unchanged secrets"
        )
    }

    func test_credentialEditInvalidatesCredentialMaterialImmediately() async throws {
        let secretStore = CountingSecretStore(
            secrets: ["factory.slot.max": "fk-gateway"]
        )
        let configStore = try makeConfigStore(secretStore: secretStore)
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max",
                credentialSlots: [
                    BurnBarProviderCredentialSlot(
                        slotID: "max",
                        label: "Factory Max",
                        isEnabled: true,
                        status: .ready
                    )
                ]
            )
        )
        let source = makeSource(
            configStore: configStore,
            droidRunner: CountingDroidRunner(),
            cacheTTL: 600
        )

        _ = try await source.snapshot()
        _ = try await configStore.upsertCredentialSlot(
            providerID: "factory",
            slotID: "max",
            label: "Factory Max",
            apiKey: "fk-gateway-rotated"
        )
        await secretStore.resetReadCounts()

        _ = try await source.snapshot()
        let resolved = try await configStore.resolvedConfiguration(for: "factory")

        XCTAssertEqual(resolved.apiKey, "fk-gateway-rotated")
        let readCount = await secretStore.readCount(for: "factory.slot.max")
        XCTAssertEqual(
            readCount,
            1,
            "credential edits must invalidate material immediately, then reuse the newly resolved value"
        )
    }

    func test_cacheTTLPositiveExpiresAtConfiguredBoundaryWithoutSliding() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let source = makeSource(
            configStore: configStore,
            droidRunner: droid,
            cacheTTL: 600,
            clock: { clock.read() }
        )

        _ = try await source.snapshot()
        clock.withLock { $0 = $0.addingTimeInterval(599) }
        _ = try await source.snapshot()
        XCTAssertEqual(droid.count, 1)

        clock.withLock { $0 = $0.addingTimeInterval(2) }
        _ = try await source.snapshot()
        XCTAssertEqual(
            droid.count,
            2,
            "cache reads must not slide the discovery timestamp beyond the ten-minute budget"
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

    func test_transientCredentialHealthReprojectsWithoutRediscovery() async throws {
        let configStore = try makeConfigStore()
        try await configureFactory(configStore)
        let droid = CountingDroidRunner()
        let source = makeSource(configStore: configStore, droidRunner: droid, cacheTTL: 600)

        let ready = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: ready).quotaState, .healthy)
        XCTAssertTrue(try factoryModel(in: ready).routeEligible)

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
        XCTAssertFalse(try factoryModel(in: coolingDown).routeEligible)

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
        XCTAssertTrue(try factoryModel(in: recovered).routeEligible)
        XCTAssertEqual(
            droid.count,
            1,
            "credential-health projection must stay fresh without repeating expensive discovery"
        )
    }

    func test_transientCredentialQuotaReprojectsWithoutRediscovery() async throws {
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
        XCTAssertFalse(try factoryModel(in: exhausted).routeEligible)

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
        XCTAssertTrue(try factoryModel(in: recovered).routeEligible)
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
        XCTAssertFalse(try factoryModel(in: coolingDown).routeEligible)

        try await configStore.recordCredentialSelection(
            providerID: "factory",
            slotID: "max"
        )
        let restored = try await source.snapshot()
        XCTAssertEqual(try factoryAccount(in: restored).quotaState, .healthy)
        XCTAssertTrue(try factoryModel(in: restored).routeEligible)
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

private actor CountingSecretStore: BurnBarProviderSecretStoring {
    private var secrets: [String: String]
    private var readCounts: [String: Int] = [:]
    private let readDelayNanoseconds: UInt64

    init(
        secrets: [String: String] = [:],
        readDelayNanoseconds: UInt64 = 0
    ) {
        self.secrets = secrets
        self.readDelayNanoseconds = readDelayNanoseconds
    }

    func secret(for providerID: String) async throws -> String? {
        readCounts[providerID, default: 0] += 1
        if readDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: readDelayNanoseconds)
        }
        return secrets[providerID]
    }

    func setSecret(_ secret: String?, for providerID: String) async throws {
        let normalized = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            secrets[providerID] = normalized
        } else {
            secrets.removeValue(forKey: providerID)
        }
    }

    func readCount(for providerID: String) -> Int {
        readCounts[providerID, default: 0]
    }

    func readCountsSnapshot() -> [String: Int] {
        readCounts
    }

    func resetReadCounts() {
        readCounts.removeAll(keepingCapacity: true)
    }
}
