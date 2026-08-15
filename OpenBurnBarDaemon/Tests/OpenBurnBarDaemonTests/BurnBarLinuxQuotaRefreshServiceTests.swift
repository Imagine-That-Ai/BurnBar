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

    func testRefreshIfNeeded_skipsFreshHighRemainingSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fetchCount = Locked(0)
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
            .init(provider: .codex, adapter: CountingAdapter(snapshot: snapshot, fetchCount: fetchCount), coverage: .live)
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

        _ = await service.refreshIfNeeded(force: true)
        XCTAssertEqual(fetchCount.read(), 1)
        _ = await service.refreshIfNeeded(force: false)
        XCTAssertEqual(fetchCount.read(), 1)
    }

    private struct CountingAdapter: ProviderQuotaAdapter {
        let snapshot: ProviderQuotaSnapshot
        let fetchCount: Locked<Int>

        func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
            _ = context.resolvedAPIKeys
            fetchCount.withLock { $0 += 1 }
            return snapshot
        }
    }

    func testCLIExecutorDrainsBothStreamsAndRejectsOversizedOutput() throws {
        let root = try makeExecutableDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try "#!/bin/sh\ni=0\nwhile [ $i -lt 20 ]; do printf '%65536s' '' >&2; i=$((i + 1)); done\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertThrowsError(
            try BurnBarLinuxQuotaCLIExecutor(timeout: 1).run(
                executable: executable.path,
                arguments: [],
                environment: ["PATH": root.path]
            )
        ) { error in
            XCTAssertEqual(
                (error as? QuotaServiceError)?.errorDescription,
                "Linux quota CLI output exceeded the safety bound."
            )
        }
    }

    func testCLIExecutorTerminatesAWedgedProviderProcess() throws {
        let root = try makeExecutableDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try "#!/bin/sh\nwhile :; do :; done\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let started = Date()
        XCTAssertThrowsError(
            try BurnBarLinuxQuotaCLIExecutor(timeout: 0.1).run(
                executable: executable.path,
                arguments: [],
                environment: ["PATH": root.path]
            )
        ) { error in
            XCTAssertEqual(
                (error as? QuotaServiceError)?.errorDescription,
                "Linux quota CLI timed out."
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func makeExecutableDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-quota-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

#endif
