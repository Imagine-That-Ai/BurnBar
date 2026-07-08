import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// A `Clock` whose `sleep` returns immediately. Injected as the model's
/// `debounceClock` so debounce-persist tests advance time deterministically
/// instead of racing the 300 ms debounce window against wall-clock
/// `Task.sleep` waits (which flaked on slow CI simulators).
private final class ImmediateClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private let lock = NSLock()
    private var _now = Instant()

    var now: Instant {
        lock.withLock { _now }
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            if deadline > _now { _now = deadline }
        }
    }
}

@MainActor
final class SmartHubDisplaySettingsModelTests: XCTestCase {

    // MARK: - Defaults

    func test_defaultConfigMatchesSpec() {
        let config = SmartHubDisplayConfig.default
        XCTAssertEqual(config.layout, .quotaCarousel)
        XCTAssertEqual(config.palette, .emberWhimsy)
        XCTAssertEqual(config.theme, .warmCharcoal)
        XCTAssertEqual(config.background, .dashboard)
        XCTAssertEqual(config.clampedBrightness, 0.85, accuracy: 0.0001)
        XCTAssertEqual(config.clampedScrollSpeed, 8)
        XCTAssertEqual(config.clampedRefreshCadence, 5)
        XCTAssertFalse(config.audibleCue)
        XCTAssertFalse(config.identifyOnRefresh)
        XCTAssertTrue(config.providerIDs.isEmpty)
    }

    func test_brightnessClampsBelowMinimum() {
        var config = SmartHubDisplayConfig.default
        config.brightness = 0.0
        XCTAssertEqual(config.clampedBrightness, 0.2, accuracy: 0.0001)
        config.brightness = 1.5
        XCTAssertEqual(config.clampedBrightness, 1.0, accuracy: 0.0001)
    }

    // MARK: - Mutations persist via debounce

    func test_paletteMutationPersistsAfterDebounce() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops,
            debounceClock: ImmediateClock()
        )
        model.updatePalette(.mercury)
        await model.flushPendingPersist()
        XCTAssertEqual(ops.lastConfig?.palette, .mercury)
    }

    func test_themeMutationPersistsAfterDebounce() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops,
            debounceClock: ImmediateClock()
        )
        model.updateTheme(.botanicalCream)
        await model.flushPendingPersist()
        XCTAssertEqual(ops.lastConfig?.theme, .botanicalCream)
    }

    func test_repeatedSameValueOnlyPersistsOnce() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops,
            debounceClock: ImmediateClock()
        )
        model.updatePalette(.mercury)
        model.updatePalette(.mercury)
        model.updatePalette(.mercury)
        await model.flushPendingPersist()
        XCTAssertEqual(ops.lastConfig?.palette, .mercury)
    }

    // MARK: - Provider filter

    func test_providerFilterStartsAsAllSelected() {
        let model = SmartHubDisplaySettingsModel(enabled: true)
        XCTAssertFalse(model.hasExplicitProviderFilter)
        XCTAssertTrue(model.isProviderSelected(.claudeCode))
        XCTAssertTrue(model.isProviderSelected(.codex))
    }

    func test_toggleProviderNarrowsFilter() {
        let model = SmartHubDisplaySettingsModel(enabled: true)
        model.toggleProvider(.claudeCode)
        XCTAssertTrue(model.hasExplicitProviderFilter)
        XCTAssertTrue(model.isProviderSelected(.claudeCode))
        XCTAssertFalse(model.isProviderSelected(.codex))
    }

    func test_resetProviderFilterClearsExplicitSet() {
        let model = SmartHubDisplaySettingsModel(enabled: true)
        model.toggleProvider(.claudeCode)
        model.resetProviderFilter()
        XCTAssertFalse(model.hasExplicitProviderFilter)
        XCTAssertTrue(model.isProviderSelected(.codex))
    }

    // MARK: - Toggles

    func test_audibleCueToggleRoundTrips() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops,
            debounceClock: ImmediateClock()
        )
        model.updateAudibleCue(true)
        await model.flushPendingPersist()
        XCTAssertEqual(ops.lastConfig?.audibleCue, true)
    }

    func test_identifyOnRefreshToggleRoundTrips() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops,
            debounceClock: ImmediateClock()
        )
        model.updateIdentifyOnRefresh(true)
        await model.flushPendingPersist()
        XCTAssertEqual(ops.lastConfig?.identifyOnRefresh, true)
    }

    // MARK: - Operations

    func test_testOperationStoresBridgeStatus() async {
        let ops = InMemorySmartHubDisplayOperations(probeResult: .bound)
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops
        )
        await model.test()
        XCTAssertEqual(model.bridgeStatus, .bound)
        if case .succeeded(let kind, _) = model.operationState {
            XCTAssertEqual(kind, .test)
        } else {
            XCTFail("Expected succeeded test state, got \(model.operationState)")
        }
    }

    func test_refreshOperationRunsThroughOperations() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops
        )
        await model.refresh()
        XCTAssertEqual(ops.refreshCount, 1)
    }

    func test_stopOperationDisablesModel() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops
        )
        await model.stop()
        XCTAssertEqual(ops.stopCount, 1)
        XCTAssertFalse(model.enabled)
    }
}
