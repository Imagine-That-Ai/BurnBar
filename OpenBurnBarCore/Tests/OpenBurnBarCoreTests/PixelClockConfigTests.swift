import XCTest
@testable import OpenBurnBarCore

final class PixelClockConfigTests: XCTestCase {
    func testBrightnessDefaultsToSafeVisibleValue() throws {
        let config = PixelClockConfig(enabled: true)

        XCTAssertEqual(config.brightness, PixelClockConfig.safeDefaultBrightness)
        XCTAssertEqual(config.clampedBrightness, PixelClockConfig.safeDefaultBrightness)
    }

    func testBrightnessClampsToVisibleSafeRange() throws {
        XCTAssertEqual(
            PixelClockConfig(enabled: true, brightness: 0).clampedBrightness,
            PixelClockConfig.minimumVisibleBrightness
        )
        XCTAssertEqual(
            PixelClockConfig(enabled: true, brightness: 999).clampedBrightness,
            PixelClockConfig.safeMaximumBrightness
        )
    }

    func testDecodedMissingBrightnessUsesSafeDefault() throws {
        let data = #"{"enabled":true,"host":"192.168.68.92"}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(PixelClockConfig.self, from: data)

        XCTAssertEqual(config.brightness, PixelClockConfig.safeDefaultBrightness)
        XCTAssertEqual(config.clampedBrightness, PixelClockConfig.safeDefaultBrightness)
    }

    func testDecodedLegacyJSONFillsButtonBindingsAndSelectedIndexDefaults() throws {
        let data = #"{"enabled":true,"host":"192.168.68.92"}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(PixelClockConfig.self, from: data)

        XCTAssertEqual(config.selectedProviderIndex, 0)
        XCTAssertEqual(config.buttonBindings, .default)
        XCTAssertEqual(config.buttonBindings.left, .previousProvider)
        XCTAssertEqual(config.buttonBindings.select, .openHermes)
        XCTAssertEqual(config.buttonBindings.right, .nextProvider)
        XCTAssertNil(config.mutedUntil)
        XCTAssertFalse(config.isMuted())
    }

    func testButtonBindingsRoundTrip() throws {
        let config = PixelClockConfig(
            enabled: true,
            buttonBindings: PixelClockButtonBindings(
                left: .cycleLayout,
                select: .snoozeAlert,
                right: .cycleTimePeriod
            ),
            mutedUntil: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PixelClockConfig.self, from: data)

        XCTAssertEqual(decoded.buttonBindings.left, .cycleLayout)
        XCTAssertEqual(decoded.buttonBindings.select, .snoozeAlert)
        XCTAssertEqual(decoded.buttonBindings.right, .cycleTimePeriod)
        XCTAssertEqual(decoded.mutedUntil, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(decoded.isMuted(at: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(decoded.isMuted(at: Date(timeIntervalSince1970: 1_800_000_000)))
    }
}
