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

    private func makeService(
        home: URL,
        appSupportRoot: URL,
        refreshProviders: [AgentProvider]
    ) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: ProviderAPIKeyStore(
                keychain: KeychainStore(
                    service: "tests.\(UUID().uuidString)",
                    legacyServices: [],
                    backend: ProviderQuotaRefreshTTLKeychainBackend()
                )
            ),
            providerRuntimeKeyStore: KeychainStore(
                service: "tests.runtime.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaRefreshTTLKeychainBackend()
            ),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: .shared,
            environment: [:],
            homeDirectoryURL: home,
            miniMaxModeProvider: { .payAsYouGo },
            factoryPlanProvider: { .unknown },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            refreshProviders: refreshProviders
        )
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
