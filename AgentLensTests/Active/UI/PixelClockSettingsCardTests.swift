import XCTest
import SwiftUI
import ViewInspector
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class PixelClockSettingsCardTests: XCTestCase {

    func test_macSmartDisplaysSectionRendersBothCardLabels() throws {
        let settingsManager = SettingsManager()
        let section = SmartDisplaysSection(settingsManager: settingsManager)
        let sut = try section.inspect()

        XCTAssertNoThrow(try sut.find(text: MacCopy.googleNestHubSectionTitle))
        XCTAssertNoThrow(try sut.find(text: MacCopy.pixelClockSectionTitle))
    }

    func test_devicesSettingsExposesSmartDisplaysSection() throws {
        let deviceTrust = DeviceTrustViewModel(gateway: FakeMacDeviceTrustGateway(devices: []))
        let exportVM = CredentialTransferExportViewModel(gateway: FakeExportGateway())
        let view = DevicesAndSyncSettingsView(
            settingsManager: SettingsManager(),
            deviceTrust: deviceTrust,
            exportViewModel: exportVM
        )
        let sut = try view.inspect()

        // After the iOS-style drill-down redesign, Devices & Sync surfaces
        // Smart Displays as a discoverable navigation row in its landing list.
        XCTAssertNoThrow(try sut.find(text: MacCopy.smartDisplaysSectionTitle))

        // The Nest Hub controls themselves live in the drill-down destination.
        let detail = SmartDisplaysDetailView(
            settingsManager: SettingsManager(),
            runtimeContext: nil
        )
        let detailSUT = try detail.inspect()
        XCTAssertNoThrow(try detailSUT.find(text: "Nest Hub quota display"))
    }

    func test_pixelClockCardCollapsedWhenDisabled() throws {
        let settingsManager = SettingsManager()
        var config = settingsManager.pixelClockConfig
        config.enabled = false
        settingsManager.pixelClockConfig = config

        let card = PixelClockSettingsCard(settingsManager: settingsManager)
        let sut = try card.inspect()
        XCTAssertNoThrow(try sut.find(text: "ULANZI TC001 Pixel Clock"))
    }

    func test_pixelClockCardMainPathIsAutomaticSetupWhenEnabled() throws {
        let settingsManager = SettingsManager()
        var config = settingsManager.pixelClockConfig
        config.enabled = true
        config.lastProbeStatus = .unknown
        settingsManager.pixelClockConfig = config

        let model = PixelClockSettingsModel(
            initialConfig: config,
            operations: InMemoryPixelClockOperations()
        )
        let card = PixelClockSettingsCard(settingsManager: settingsManager, model: model)
        let sut = try card.inspect()

        XCTAssertNoThrow(try sut.find(text: "Set up automatically"))
        XCTAssertNoThrow(try sut.find(text: "Customize display"))
        XCTAssertNoThrow(try sut.find(text: "Advanced"))
    }

    func test_pixelClockSettingsModel_stockFirmwareWarningHasExactSpecCopy() async {
        let ops = InMemoryPixelClockOperations(probeResult: .stockUlanziFirmware)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        await model.probe()
        XCTAssertEqual(
            model.firmwareWarningMessage,
            "Stock Ulanzi needs Awtrix Simulator pointed at this Mac's IP."
        )
    }

    func test_pixelClockSettingsModel_setupStopsWhenClockIsAbsentFromWiFiAndUSB() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        ops.prepareResult = PixelClockSetupResult(
            mode: .unreachable,
            probeStatus: .unreachable,
            message: "No Pixel Clock found on Wi-Fi or USB.",
            clockHost: "192.168.68.92"
        )
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)

        await model.setupAutomatically()

        XCTAssertEqual(ops.prepareCallCount, 1)
        XCTAssertEqual(ops.flashCallCount, 0)
        XCTAssertEqual(ops.pushCallCount, 0)
        XCTAssertEqual(model.firmware, .unreachable)
        XCTAssertEqual(model.setupPrimaryTitle, "Detect Pixel Clock")
        XCTAssertEqual(model.setupResult?.mode, .unreachable)
        XCTAssertNil(model.setupResult?.flasherURL)
    }

    func test_pixelClockSettingsModel_setupFlashesOnlyWhenPrepareFindsUSBSetupPath() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        ops.prepareResult = PixelClockSetupResult(
            mode: .needsAwtrixLightFlash,
            probeStatus: .unreachable,
            message: "USB setup is available.",
            clockHost: "192.168.68.92"
        )
        ops.flashResult = PixelClockSetupResult(
            mode: .awtrixLightReady,
            probeStatus: .awtrixReady,
            message: "AWTRIX is ready.",
            clockHost: "192.168.68.92"
        )
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)

        await model.setupAutomatically()

        XCTAssertEqual(ops.prepareCallCount, 1)
        XCTAssertEqual(ops.flashCallCount, 1)
        XCTAssertEqual(ops.pushCallCount, 1)
        XCTAssertEqual(model.firmware, .awtrixReady)
        XCTAssertEqual(model.setupPrimaryTitle, "Push to Pixel Clock")
    }

    func test_pixelClockSettingsModel_setupFinishesVisibleAwtrixSetupWiFi() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        ops.prepareResult = PixelClockSetupResult(
            mode: .needsWiFiProvisioning,
            probeStatus: .unreachable,
            message: "AWTRIX setup Wi-Fi awtrix_ab12cd is visible.",
            clockHost: "192.168.68.92",
            setupSSID: "awtrix_ab12cd"
        )
        ops.flashResult = PixelClockSetupResult(
            mode: .awtrixLightReady,
            probeStatus: .awtrixReady,
            message: "AWTRIX is ready.",
            clockHost: "192.168.68.92"
        )
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)

        await model.setupAutomatically()

        XCTAssertEqual(ops.prepareCallCount, 1)
        XCTAssertEqual(ops.flashCallCount, 1)
        XCTAssertEqual(ops.pushCallCount, 1)
        XCTAssertEqual(model.firmware, .awtrixReady)
    }

    func test_pixelClockSettingsModel_visibleAwtrixSetupWiFiUsesWiFiSetupCopy() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        ops.prepareResult = PixelClockSetupResult(
            mode: .needsWiFiProvisioning,
            probeStatus: .unreachable,
            message: "AWTRIX setup Wi-Fi awtrix_ab12cd is visible.",
            clockHost: "192.168.68.92",
            setupSSID: "awtrix_ab12cd"
        )
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)

        await model.prepare()

        XCTAssertEqual(model.setupPrimaryTitle, "Send Wi-Fi and Finish")
        XCTAssertEqual(model.setupStatusSymbolName, "wifi.router.fill")
        XCTAssertTrue(model.setupNeedsAttention)
    }

    func test_pixelClockSettingsModel_setupWaitsAndPushesWhenClockAppearsOnRetry() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        ops.prepareResults = [
            PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: .unreachable,
                message: "No Pixel Clock found on Wi-Fi or USB.",
                clockHost: "192.168.68.92"
            ),
            PixelClockSetupResult(
                mode: .awtrixLightReady,
                probeStatus: .awtrixReady,
                message: "AWTRIX Light is ready.",
                clockHost: "192.168.68.92"
            )
        ]
        let model = PixelClockSettingsModel(
            initialConfig: .disabled,
            operations: ops,
            setupRetryAttempts: 2,
            setupRetryIntervalNanoseconds: 1_000_000
        )

        await model.setupAutomatically()

        XCTAssertEqual(ops.prepareCallCount, 2)
        XCTAssertEqual(ops.flashCallCount, 0)
        XCTAssertEqual(ops.pushCallCount, 1)
        XCTAssertEqual(model.firmware, .awtrixReady)
        XCTAssertFalse(model.isWaitingForConnection)
    }

    func test_pixelClockSettingsModel_prepareDoesNotEnterSetupRetryLoop() async {
        let ops = InMemoryPixelClockOperations(probeResult: .unreachable)
        ops.prepareResults = [
            PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: .unreachable,
                message: "No Pixel Clock found on Wi-Fi or USB.",
                clockHost: "192.168.68.92"
            ),
            PixelClockSetupResult(
                mode: .awtrixLightReady,
                probeStatus: .awtrixReady,
                message: "AWTRIX Light is ready.",
                clockHost: "192.168.68.92"
            )
        ]
        let model = PixelClockSettingsModel(
            initialConfig: .disabled,
            operations: ops,
            setupRetryAttempts: 150,
            setupRetryIntervalNanoseconds: 1_000_000
        )

        await model.prepare()

        XCTAssertEqual(ops.prepareCallCount, 1)
        XCTAssertEqual(ops.flashCallCount, 0)
        XCTAssertEqual(ops.pushCallCount, 0)
        XCTAssertEqual(model.setupResult?.mode, .unreachable)
        XCTAssertFalse(model.isWaitingForConnection)
    }

    func test_macAdapterSurfacesProbeStatusFromController() async {
        let settingsManager = SettingsManager()
        var config = settingsManager.pixelClockConfig
        config.host = "127.0.0.1"
        config.port = 1
        config.enabled = true
        settingsManager.pixelClockConfig = config

        let adapter = MacPixelClockOperationsAdapter(
            settingsManager: settingsManager,
            controller: nil
        )
        // Without a controller the adapter should fall back to the
        // currently-persisted probe status without crashing.
        let result = await adapter.probePixelClock(config: config)
        XCTAssertEqual(result, settingsManager.pixelClockConfig.lastProbeStatus)
    }
}
