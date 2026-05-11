import XCTest
import SwiftUI
import ViewInspector
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class NestHubSettingsCardTests: XCTestCase {

    func test_nestHubHeaderUsesLegacyAccessibleString() throws {
        let settingsManager = SettingsManager()
        settingsManager.smartHubQuotaDisplayEnabled = true

        let card = NestHubSettingsCard(settingsManager: settingsManager)
        let sut = try card.inspect()

        // Existing `test_devicesSettingsExposeNestHubControls` regression
        // asserts this string — keep it visible in the parity card.
        XCTAssertNoThrow(try sut.find(text: "Nest Hub quota display"))
    }

    func test_disabledNestHubCardCollapsesControls() throws {
        let settingsManager = SettingsManager()
        settingsManager.smartHubQuotaDisplayEnabled = false

        let card = NestHubSettingsCard(settingsManager: settingsManager)
        let sut = try card.inspect()
        XCTAssertThrowsError(try sut.find(text: "Live preview"))
    }

    func test_enabledNestHubCardSurfacesParityControls() throws {
        let settingsManager = SettingsManager()
        settingsManager.smartHubQuotaDisplayEnabled = true

        let card = NestHubSettingsCard(settingsManager: settingsManager)
        let sut = try card.inspect()

        XCTAssertNoThrow(try sut.find(text: "Live preview"))
        XCTAssertNoThrow(try sut.find(text: "Layout"))
        XCTAssertNoThrow(try sut.find(text: "Palette"))
        XCTAssertNoThrow(try sut.find(text: "Theme"))
        XCTAssertNoThrow(try sut.find(text: "Background mode"))
        XCTAssertNoThrow(try sut.find(text: "Refresh cadence"))
        XCTAssertNoThrow(try sut.find(text: "Brightness"))
        XCTAssertNoThrow(try sut.find(text: "Providers to show"))
        XCTAssertNoThrow(try sut.find(text: "Audible chime on refresh"))
        XCTAssertNoThrow(try sut.find(text: "Identify on refresh"))
        XCTAssertNoThrow(try sut.find(text: "Voice routine deep-link"))
    }

    func test_smartDisplaysSectionHonorsReorderedOrder() throws {
        let settingsManager = SettingsManager()
        settingsManager.smartDisplayOrder = SmartDisplayOrder(kinds: [.pixelClock, .nestHub])

        let section = SmartDisplaysSection(settingsManager: settingsManager)
        let sut = try section.inspect()

        // Both section labels remain accessible regardless of order.
        XCTAssertNoThrow(try sut.find(text: MacCopy.googleNestHubSectionTitle))
        XCTAssertNoThrow(try sut.find(text: MacCopy.pixelClockSectionTitle))
    }
}
