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

    func test_pixelClockCardMainPathIsFlashingWhenEnabledBeforeAWTRIXReady() throws {
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

        XCTAssertNoThrow(try sut.find(text: "Flash and Finish Setup"))
        XCTAssertNoThrow(try sut.find(text: "Detect after flash"))
        XCTAssertNoThrow(try sut.find(text: "Customize display"))
        XCTAssertNoThrow(try sut.find(text: "Advanced"))
    }

    func test_pixelClockSettingsModel_stockFirmwareWarningHasExactSpecCopy() async {
        let ops = InMemoryPixelClockOperations(probeResult: .stockUlanziFirmware)
        let model = PixelClockSettingsModel(initialConfig: .disabled, operations: ops)
        await model.probe()
        XCTAssertEqual(
            model.firmwareWarningMessage,
            "Stock Ulanzi needs Awtrix Simulator pointed at this Mac's IP, not the clock IP."
        )
    }

    func test_pixelClockPaletteSupportsPrideRainbowDisplayName() {
        // Picker iterates `PixelClockPalette.allCases`. Rainbow's display
        // name is the user-visible string the picker option will render.
        let names = PixelClockPalette.allCases.map(\.displayName)
        XCTAssertTrue(names.contains("Pride rainbow"))
        XCTAssertTrue(PixelClockPalette.rainbow.isRainbow)
    }

    func test_smartHubPaletteSupportsPrideRainbowDisplayName() {
        let names = SmartHubDisplayPalette.allCases.map(\.displayName)
        XCTAssertTrue(names.contains("Pride rainbow"))
        XCTAssertTrue(SmartHubDisplayPalette.rainbow.isRainbow)
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
