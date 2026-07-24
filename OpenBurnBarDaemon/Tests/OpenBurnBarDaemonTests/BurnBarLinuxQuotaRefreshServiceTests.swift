#if os(Linux)

import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

final class BurnBarLinuxQuotaRefreshServiceTests: XCTestCase {
    private struct FixtureAdapter: ProviderQuotaAdapter {
        let snapshot: ProviderQuotaSnapshot

        func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
            _ = context.resolvedAPIKeys
            return snapshot
        }
    }

    func testRefreshUsesSharedAdapterAndPersistsOnlySnapshots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = ProviderQuotaSnapshot(
            id: "fixture-codex",
            provider: AgentProvider.codex.rawValue,
            providerID: AgentProvider.codex.providerID,
            sourceKind: .officialAPI,
            sourceId: "fixture.adapter",
            fetchedAt: Date(),
            source: "fixture",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(
                    key: "requests",
                    label: "Requests",
                    windowKind: .daily,
                    usedValue: 1,
                    limitValue: 10,
                    remainingValue: 9,
                    usedPercent: 10,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
            ],
            updatedAt: Date()
        )
        let registry = ProviderQuotaAdapterRegistry(entries: [
            .init(provider: .codex, adapter: FixtureAdapter(snapshot: snapshot), coverage: .live)
        ])
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("config.json"),
            secretStore: BurnBarInMemorySecretStore()
        )
        let cacheURL = root.appendingPathComponent("quotas.json")
        let service = BurnBarLinuxQuotaRefreshService(
            configStore: configStore,
            registry: registry,
            cache: BurnBarLinuxQuotaSnapshotCache(fileURL: cacheURL)
        )

        let refreshed = await service.refreshIfNeeded(force: true)
        XCTAssertEqual(refreshed, [snapshot])

        let reloaded = BurnBarLinuxQuotaSnapshotCache(fileURL: cacheURL)
        XCTAssertEqual(reloaded.snapshots(), [snapshot])
    }
}

#endif
