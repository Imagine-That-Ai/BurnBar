import SwiftUI
import XCTest
@testable import OpenBurnBar

final class BackdropReadabilityTests: XCTestCase {
    func testSRGBLuminanceAndContrastEndpoints() {
        XCTAssertEqual(BackdropContrast.linearChannel(0), 0, accuracy: 0.000_001)
        XCTAssertEqual(BackdropContrast.linearChannel(255), 1, accuracy: 0.000_001)
        XCTAssertEqual(
            BackdropContrast.relativeLuminance(BackdropRGB(0, 0, 0)),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BackdropContrast.relativeLuminance(BackdropRGB(255, 255, 255)),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            BackdropContrast.ratio(BackdropRGB(0, 0, 0), BackdropRGB(255, 255, 255)),
            21,
            accuracy: 0.000_001
        )
    }

    func testAlphaCompositingClampsOpacity() {
        XCTAssertEqual(
            BackdropContrast.composite(
                foreground: BackdropRGB(255, 0, 0),
                background: BackdropRGB(0, 0, 255),
                alpha: 0.5
            ),
            BackdropRGB(127.5, 0, 127.5)
        )
        XCTAssertEqual(
            BackdropContrast.composite(
                foreground: BackdropRGB(255, 0, 0),
                background: BackdropRGB(0, 0, 255),
                alpha: -1
            ),
            BackdropRGB(0, 0, 255)
        )
    }

    func testReadabilityMessageDecodesDefensively() throws {
        let profile = try XCTUnwrap(BackdropReadabilityProfile.decode(messageBody: [
            "tone": "dark",
            "scrimOpacity": 0.22,
            "minLuminance": 0.12,
            "maxLuminance": 0.91,
            "contrastRatio": 4.72,
            "sampleCount": 18,
            "samplingDurationMs": 0.18,
            "source": "canvas"
        ]))
        XCTAssertEqual(profile.tone, .dark)
        XCTAssertEqual(profile.sampleCount, 18)
        XCTAssertEqual(profile.samplingDurationMs, 0.18)
        XCTAssertEqual(profile.source, "canvas")
        XCTAssertNil(BackdropReadabilityProfile.decode(messageBody: ["tone": "unknown"]))
        XCTAssertNil(BackdropReadabilityProfile.decode(messageBody: [
            "tone": "light",
            "scrimOpacity": 2,
            "minLuminance": 0,
            "maxLuminance": 1,
            "contrastRatio": 4.5,
            "sampleCount": 1,
            "source": "canvas"
        ]))
    }

    func testNativeFallbacksAreDeterministicForBackdropAndSkin() {
        XCTAssertEqual(
            BackdropReadabilityProfile.nativeFallback(
                colorScheme: .dark,
                appearanceSkin: .aurora,
                liveBackdropActive: true
            ),
            .darkCanvasFallback
        )
        XCTAssertEqual(
            BackdropReadabilityProfile.nativeFallback(
                colorScheme: .dark,
                appearanceSkin: .editorial,
                liveBackdropActive: false
            ),
            .lightCanvasFallback
        )
    }

    func testForegroundFamiliesMeetTextAndIconThresholdsOnFallbackCanvases() {
        assertContrast(profile: .darkCanvasFallback, background: BackdropRGB(10, 14, 24))
        assertContrast(profile: .lightCanvasFallback, background: BackdropRGB(245, 247, 250))
    }

    private func assertContrast(
        profile: BackdropReadabilityProfile,
        background: BackdropRGB,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let family = profile.foreground
        let effective = BackdropContrast.composite(
            foreground: family.scrim,
            background: background,
            alpha: profile.scrimOpacity
        )
        XCTAssertGreaterThanOrEqual(
            BackdropContrast.ratio(family.muted, effective),
            BackdropContrast.normalTextRatio,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            BackdropContrast.ratio(family.icon, effective),
            BackdropContrast.largeTextRatio,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            BackdropContrast.ratio(family.accent, effective),
            BackdropContrast.normalTextRatio,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            BackdropContrast.ratio(family.focus, effective),
            BackdropContrast.largeTextRatio,
            file: file,
            line: line
        )
    }
}
