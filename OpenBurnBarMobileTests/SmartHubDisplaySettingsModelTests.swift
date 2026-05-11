import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

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
            operations: ops
        )
        model.updatePalette(.mercury)
        try? await Task.sleep(nanoseconds: 400_000_000) // past 300ms debounce
        XCTAssertEqual(ops.lastConfig?.palette, .mercury)
    }

    func test_themeMutationPersistsAfterDebounce() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops
        )
        model.updateTheme(.botanicalCream)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(ops.lastConfig?.theme, .botanicalCream)
    }

    func test_repeatedSameValueOnlyPersistsOnce() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops
        )
        model.updatePalette(.mercury)
        model.updatePalette(.mercury)
        model.updatePalette(.mercury)
        try? await Task.sleep(nanoseconds: 400_000_000)
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
            operations: ops
        )
        model.updateAudibleCue(true)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(ops.lastConfig?.audibleCue, true)
    }

    func test_identifyOnRefreshToggleRoundTrips() async {
        let ops = InMemorySmartHubDisplayOperations()
        let model = SmartHubDisplaySettingsModel(
            enabled: true,
            initialConfig: .default,
            operations: ops
        )
        model.updateIdentifyOnRefresh(true)
        try? await Task.sleep(nanoseconds: 400_000_000)
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
