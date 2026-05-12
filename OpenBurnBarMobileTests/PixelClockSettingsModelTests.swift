import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class PixelClockSettingsModelTests: XCTestCase {

    // MARK: - Defaults

    func test_defaultConfigMatchesSpec() {
        let config = PixelClockConfig.disabled
        XCTAssertEqual(config.host, "192.168.68.92")
        XCTAssertEqual(config.layout, .quotaCarousel)
        XCTAssertEqual(config.palette, .emberWhimsy)
        XCTAssertEqual(config.timePeriod, .rolling5h)
        XCTAssertEqual(config.clampedUpdateInterval, 60)
        XCTAssertEqual(config.lastProbeStatus, .unknown)
    }

    // MARK: - Mutations bump preview frame identity

    func test_mutationsAdvancePreviewFrameIdentity() {
        let model = PixelClockSettingsModel(
            initialConfig: .disabled,
            operations: InMemoryPixelClockOperations()
        )
        let baseline = PixelClockFramePresenter.makePreviewFrame(config: model.config).id

        model.updatePalette(.mercury)
        let afterPalette = PixelClockFramePresenter.makePreviewFrame(config: model.config).id
        XCTAssertNotEqual(baseline, afterPalette, "Palette change should change frame identity")

        model.updateLayout(.burnStatus)
        let afterLayout = PixelClockFramePresenter.makePreviewFrame(config: model.config).id
        XCTAssertNotEqual(afterPalette, afterLayout, "Layout change should change frame identity")

        model.toggleProvider(.claudeCode)
        let afterProvider = PixelClockFramePresenter.makePreviewFrame(config: model.config).id
        XCTAssertNotEqual(afterLayout, afterProvider, "Provider filter change should change frame identity")

        model.updateTimePeriod(.rolling7d)
        let afterPeriod = PixelClockFramePresenter.makePreviewFrame(config: model.config).id
        XCTAssertNotEqual(afterProvider, afterPeriod, "Time period change should change frame identity")
    }

    // MARK: - Probe state machine

    func test_probeUpdatesFirmwareToReady() async {
        let ops = InMemoryPixelClockOperations(probeResult: .awtrixReady)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        await model.probe()
        XCTAssertEqual(model.firmware, .awtrixReady)
        XCTAssertNil(model.firmwareWarningMessage)
        if case .succeeded(let kind, _) = model.operationState {
            XCTAssertEqual(kind, .probe)
        } else {
            XCTFail("Expected succeeded probe state, got \(model.operationState)")
        }
    }

    func test_probeWithStockFirmwareSurfacesWarning() async {
        let ops = InMemoryPixelClockOperations(probeResult: .stockUlanziFirmware)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        await model.probe()
        XCTAssertEqual(model.firmware, .stockUlanziFirmware)
        XCTAssertEqual(
            model.firmwareWarningMessage,
            "Stock Ulanzi needs Awtrix Simulator pointed at this Mac's IP, not the clock IP."
        )
    }

    func test_probeUnreachableSurfacesUnreachableWarning() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        await model.probe()
        XCTAssertEqual(model.firmware, .unreachable)
        XCTAssertNotNil(model.firmwareWarningMessage)
    }

    // MARK: - Push surfaces failure copy

    func test_pushPropagatesFailureMessage() async {
        let ops = InMemoryPixelClockOperations(probeResult: .awtrixReady)
        ops.failureToThrow = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        await model.push()
        XCTAssertEqual(model.operationState.failureMessage, "boom")
        XCTAssertNil(model.inflightOperation)
    }

    func test_setupAutomaticallyEnablesPreparesAndPushesWhenReady() async {
        let ops = InMemoryPixelClockOperations(probeResult: .awtrixReady)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)

        await model.setupAutomatically()

        XCTAssertTrue(model.config.enabled)
        XCTAssertEqual(model.firmware, .awtrixReady)
        XCTAssertEqual(ops.prepareCallCount, 1)
        XCTAssertEqual(ops.pushCallCount, 1)
    }

    func test_setupAutomaticallyDoesNotPushStockFirmware() async {
        let ops = InMemoryPixelClockOperations(probeResult: .stockUlanziFirmware)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)

        await model.setupAutomatically()

        XCTAssertTrue(model.config.enabled)
        XCTAssertEqual(model.firmware, .stockUlanziFirmware)
        XCTAssertEqual(ops.prepareCallCount, 1)
        XCTAssertEqual(ops.pushCallCount, 0)
        XCTAssertTrue(model.setupNeedsAttention)
    }

    // MARK: - Provider filter behavior

    func test_providerFilterStartsAsAllSelected() {
        let model = PixelClockSettingsModel(
            initialConfig: .disabled,
            operations: InMemoryPixelClockOperations()
        )
        XCTAssertFalse(model.hasExplicitProviderFilter)
        XCTAssertTrue(model.isProviderSelected(.claudeCode))
        XCTAssertTrue(model.isProviderSelected(.codex))
    }

    func test_toggleProviderNarrowsFilter() {
        let model = PixelClockSettingsModel(
            initialConfig: .disabled,
            operations: InMemoryPixelClockOperations()
        )
        model.toggleProvider(.claudeCode)
        XCTAssertTrue(model.hasExplicitProviderFilter)
        XCTAssertTrue(model.isProviderSelected(.claudeCode))
        XCTAssertFalse(model.config.providerIDs.isEmpty)
    }

    // MARK: - Frame presenter never crashes

    func test_framePresenterRendersAllLayouts() {
        for layout in PixelClockLayout.allCases {
            var config = PixelClockConfig.disabled
            config.layout = layout
            let frame = PixelClockFramePresenter.makePreviewFrame(config: config)
            XCTAssertEqual(frame.pixels.count, PixelClockPreviewFrame.rows)
            XCTAssertEqual(frame.pixels.first?.count, PixelClockPreviewFrame.columns)
            XCTAssertFalse(frame.accessibilityLabel.isEmpty)
        }
    }

    func test_framePresenterAccessibilityLabelMentionsLayoutAndPalette() {
        var config = PixelClockConfig.disabled
        config.layout = .burnStatus
        config.palette = .traffic
        let frame = PixelClockFramePresenter.makePreviewFrame(config: config)
        XCTAssertTrue(frame.accessibilityLabel.contains(PixelClockLayout.burnStatus.displayName))
        XCTAssertTrue(frame.accessibilityLabel.contains(PixelClockPalette.traffic.displayName))
    }

    // MARK: - Adapter forwarding stays in-memory

    func test_inMemoryAdapterRecordsLastConfig() async {
        let ops = InMemoryPixelClockOperations()
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        model.updateHost("10.0.0.7")
        try? await Task.sleep(nanoseconds: 400_000_000) // wait past debounce
        XCTAssertEqual(ops.lastConfig?.host, "10.0.0.7")
    }
}
