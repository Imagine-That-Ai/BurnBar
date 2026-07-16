import GRDB
import XCTest

@testable import OpenBurnBar

@MainActor
final class MemoryFootprintWatchdogTests: XCTestCase {
    func test_startAndStop_runsMonitorWithoutActivatingPressureShedding() async throws {
        let dataStore = try DataStore(
            databaseQueue: DatabaseQueue(),
            runMigrations: true,
            refreshOnInit: false
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-memory-watchdog-\(UUID().uuidString)", isDirectory: true)
        let quotaService = ProviderQuotaService(
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: root),
            homeDirectoryURL: root.appendingPathComponent("home", isDirectory: true),
            refreshProviders: []
        )
        let aggregator = UsageAggregator(
            dataStore: dataStore,
            quotaService: quotaService,
            parserOverrides: [:]
        )
        let watchdog = MemoryFootprintWatchdog()

        watchdog.start(aggregator: aggregator)
        try await Task.sleep(for: .milliseconds(50))
        watchdog.start(aggregator: aggregator)
        watchdog.stop()

        XCTAssertFalse(aggregator.memoryPressureSheddingActive)
    }
}
