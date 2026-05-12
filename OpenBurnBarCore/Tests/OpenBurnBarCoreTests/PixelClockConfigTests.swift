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
}
