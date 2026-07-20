import GRDB
import XCTest

@testable import OpenBurnBar

@MainActor
final class MemoryFootprintWatchdogTests: XCTestCase {

    // MARK: - Helpers

    private func makeAggregator() throws -> UsageAggregator {
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
        return UsageAggregator(
            dataStore: dataStore,
            quotaService: quotaService,
            parserOverrides: [:]
        )
    }

    // MARK: - Start / Stop

    func test_startAndStop_runsMonitorWithoutActivatingPressureShedding() async throws {
        let aggregator = try makeAggregator()
        let watchdog = MemoryFootprintWatchdog()

        watchdog.start(aggregator: aggregator)
        try await Task.sleep(for: .milliseconds(50))
        watchdog.start(aggregator: aggregator)
        watchdog.stop()

        XCTAssertFalse(aggregator.memoryPressureSheddingActive)
    }

    // MARK: - Non-Cancellation Sleep Failure

    /// A sleep failure that is NOT `CancellationError` must terminate the
    /// monitor loop (log + return) rather than retrying forever on a broken
    /// sleep. This defends the `catch { … return }` branch (source lines
    /// 55-60): a flipped `return` → `continue`, or a dropped non-cancellation
    /// catch, would call the injected sleep a second time.
    func test_start_nonCancellationSleepFailure_terminatesMonitorLoop() async throws {
        let aggregator = try makeAggregator()
        let watchdog = MemoryFootprintWatchdog()

        /// Reference type so the `@Sendable` sleep closure and the test body
        /// observe the same call count without capturing mutable state across
        /// an isolation boundary.
        final class SleepCallCounter: @unchecked Sendable {
            private(set) var calls = 0
            func increment() -> Int {
                calls += 1
                return calls
            }
        }

        struct SleepInfrastructureFailure: Error {}

        let counter = SleepCallCounter()

        watchdog.start(aggregator: aggregator) { [counter] in
            // First call: throw a named, non-CancellationError failure so the
            // watchdog exercises the log-and-return branch.
            if counter.increment() == 1 {
                throw SleepInfrastructureFailure()
            }
            // A buggy loop that ignored the failure and continued would reach
            // here. Suspend (cancellation-responsive) so the failure is
            // observable as `calls == 2` rather than a synchronous spin, and
            // so `stop()` cleanly cancels it.
            try await Task.sleep(for: .seconds(3600))
        }

        // Give the @MainActor monitor task a chance to run its first
        // iteration: sample (no-op at the test process footprint) then the
        // injected sleep throws SleepInfrastructureFailure, which the
        // watchdog must log and then exit the loop. `Task.yield()` is a
        // deterministic cooperative hop — no wall-clock race.
        for _ in 0..<64 where counter.calls == 0 {
            await Task.yield()
        }
        // A few more hops so a loop that incorrectly continued past the
        // failure would have invoked the sleep a second time.
        for _ in 0..<16 {
            await Task.yield()
        }

        XCTAssertEqual(counter.calls, 1, "monitor must invoke sleep exactly once then terminate on a non-cancellation failure")
        XCTAssertFalse(aggregator.memoryPressureSheddingActive)

        watchdog.stop()
    }
}
