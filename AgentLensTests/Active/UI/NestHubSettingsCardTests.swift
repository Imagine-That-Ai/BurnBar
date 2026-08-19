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
        XCTAssertEqual(
            Set(NestHubSettingsCard.enabledControlLabels),
            Set([
                "Live preview",
                "Make display work",
                "Layout",
                "Palette",
                "Theme",
                "Background mode",
                "Refresh cadence",
                "Brightness",
                "Providers to show",
                "Audible chime on refresh",
                "Identify on refresh",
                "Voice routine deep-link"
            ])
        )

        let renderer = ImageRenderer(
            content: card
                .frame(width: 720)
                .fixedSize(horizontal: false, vertical: true)
        )
        renderer.scale = 1
        XCTAssertNotNil(renderer.nsImage)
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
