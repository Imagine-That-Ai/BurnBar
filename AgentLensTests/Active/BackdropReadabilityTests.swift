import AppKit
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

    /// A live backdrop must not force the light ink family in Light mode.
    ///
    /// This is the defect behind "hard to read in light mode": the fallback
    /// returned `.darkCanvasFallback` — the *white* family — for any live
    /// backdrop regardless of appearance, so Light mode over a bright kernel
    /// drew white text on a light field. The sampler overrides this when it
    /// publishes, but the native swarm and constellation backdrops never do.
    func testLiveBackdropFallbackFollowsAppearanceRatherThanAssumingDarkCanvas() {
        let light = BackdropReadabilityProfile.nativeFallback(
            colorScheme: .light,
            appearanceSkin: .aurora,
            liveBackdropActive: true
        )
        XCTAssertEqual(
            light.tone, .dark,
            "a live backdrop in Light mode must resolve the dark ink family"
        )
        XCTAssertEqual(light.foreground, .dark)

        let dark = BackdropReadabilityProfile.nativeFallback(
            colorScheme: .dark,
            appearanceSkin: .aurora,
            liveBackdropActive: true
        )
        XCTAssertEqual(dark.tone, .light)
    }

    /// The live fallback reinforces the scrim rather than merely picking a tone.
    ///
    /// Tone answers *which* ink; the scrim answers how much veil an unknown,
    /// moving canvas needs. Light mode previously got neither, so assert it now
    /// gets the same veil authority the dark canvas always had.
    func testLiveBackdropFallbackReinforcesScrimWithoutChangingTone() {
        let staticLight = BackdropReadabilityProfile.nativeFallback(
            colorScheme: .light,
            appearanceSkin: .aurora,
            liveBackdropActive: false
        )
        let liveLight = BackdropReadabilityProfile.nativeFallback(
            colorScheme: .light,
            appearanceSkin: .aurora,
            liveBackdropActive: true
        )
        XCTAssertEqual(staticLight, .lightCanvasFallback)
        XCTAssertEqual(liveLight.tone, staticLight.tone)
        XCTAssertGreaterThan(liveLight.scrimOpacity, staticLight.scrimOpacity)
        XCTAssertEqual(
            liveLight.scrimOpacity,
            BackdropReadabilityProfile.darkCanvasFallback.scrimOpacity,
            accuracy: 0.000_001
        )

        // Reinforcing is a floor, never a cap: the dark canvas already sits at
        // the floor, so it must come back untouched and stay equatable to the
        // published constant other call sites compare against.
        XCTAssertEqual(
            BackdropReadabilityProfile.nativeFallback(
                colorScheme: .dark,
                appearanceSkin: .aurora,
                liveBackdropActive: true
            ),
            .darkCanvasFallback
        )
    }

    func testReinforcingScrimIsAFloorAndClampsToUnity() {
        let base = BackdropReadabilityProfile.lightCanvasFallback
        XCTAssertEqual(base.reinforcingScrim(atLeast: 0.05), base, "a lower floor is a no-op")
        XCTAssertEqual(base.reinforcingScrim(atLeast: 0.4).scrimOpacity, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(base.reinforcingScrim(atLeast: 9).scrimOpacity, 1, accuracy: 0.000_001)
        // Everything except the scrim survives, or the ink family silently flips.
        XCTAssertEqual(base.reinforcingScrim(atLeast: 0.4).tone, base.tone)
        XCTAssertEqual(base.reinforcingScrim(atLeast: 0.4).source, base.source)
    }

    /// A reinforced light-canvas profile must still clear the bar it was
    /// reinforced for. Raising a near-white scrim over a light canvas can only
    /// brighten the plate, which helps dark ink — assert that rather than
    /// assuming it.
    func testReinforcedLightCanvasStillClearsContrast() {
        assertContrast(
            profile: BackdropReadabilityProfile.nativeFallback(
                colorScheme: .light,
                appearanceSkin: .aurora,
                liveBackdropActive: true
            ),
            background: BackdropRGB(245, 247, 250)
        )
    }

    func testNativeFallbackFollowsSystemColorSchemeWithoutLiveBackdrop() {
        XCTAssertEqual(
            BackdropReadabilityProfile.nativeFallback(
                colorScheme: .dark,
                appearanceSkin: .aurora,
                liveBackdropActive: false
            ),
            .darkCanvasFallback
        )
        XCTAssertEqual(
            BackdropReadabilityProfile.nativeFallback(
                colorScheme: .light,
                appearanceSkin: .aurora,
                liveBackdropActive: false
            ),
            .lightCanvasFallback
        )
    }

    func testNativeFallbackProfilesPinTheirPublishedShape() {
        let darkCanvas = BackdropReadabilityProfile.darkCanvasFallback
        XCTAssertEqual(darkCanvas.tone, .light)
        XCTAssertEqual(darkCanvas.scrimOpacity, 0.24, accuracy: 0.000_001)
        XCTAssertEqual(darkCanvas.minLuminance, 0, accuracy: 0.000_001)
        XCTAssertEqual(darkCanvas.maxLuminance, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(darkCanvas.contrastRatio, BackdropContrast.normalTextRatio, accuracy: 0.000_001)
        XCTAssertEqual(darkCanvas.sampleCount, 0)
        XCTAssertEqual(darkCanvas.samplingDurationMs, 0, accuracy: 0.000_001)
        XCTAssertEqual(darkCanvas.source, "native-fallback")

        let lightCanvas = BackdropReadabilityProfile.lightCanvasFallback
        XCTAssertEqual(lightCanvas.tone, .dark)
        XCTAssertEqual(lightCanvas.scrimOpacity, 0.16, accuracy: 0.000_001)
        XCTAssertEqual(lightCanvas.minLuminance, 0.62, accuracy: 0.000_001)
        XCTAssertEqual(lightCanvas.maxLuminance, 1, accuracy: 0.000_001)
        XCTAssertEqual(lightCanvas.contrastRatio, BackdropContrast.normalTextRatio, accuracy: 0.000_001)
        XCTAssertEqual(lightCanvas.sampleCount, 0)
        XCTAssertEqual(lightCanvas.samplingDurationMs, 0, accuracy: 0.000_001)
        XCTAssertEqual(lightCanvas.source, "native-fallback")
    }

    func testForegroundFamiliesAreToneSpecific() {
        XCTAssertEqual(BackdropReadabilityProfile.darkCanvasFallback.foreground, .light)
        XCTAssertEqual(BackdropReadabilityProfile.lightCanvasFallback.foreground, .dark)
        XCTAssertNotEqual(BackdropForegroundFamily.light, BackdropForegroundFamily.dark)
        // A light-canvas family must be darker than a dark-canvas family, or the
        // tone switch is inverted and every surface loses contrast at once.
        XCTAssertLessThan(
            BackdropContrast.relativeLuminance(BackdropForegroundFamily.dark.primary),
            BackdropContrast.relativeLuminance(BackdropForegroundFamily.light.primary)
        )
    }

    func testInterfaceColorSchemeOpposesForegroundTone() {
        // A light foreground family implies a dark canvas, so the interface
        // controls drawn over it must render in the .dark scheme (and vice
        // versa). Inverting this is what makes system controls disappear.
        XCTAssertEqual(BackdropReadabilityProfile.darkCanvasFallback.tone, .light)
        XCTAssertEqual(BackdropReadabilityProfile.darkCanvasFallback.interfaceColorScheme, .dark)
        XCTAssertEqual(BackdropReadabilityProfile.lightCanvasFallback.tone, .dark)
        XCTAssertEqual(BackdropReadabilityProfile.lightCanvasFallback.interfaceColorScheme, .light)
    }

    func testBackdropRGBProjectsNormalizedSRGBColor() throws {
        let resolved = try XCTUnwrap(
            NSColor(BackdropRGB(255, 128, 0).color).usingColorSpace(.sRGB)
        )
        XCTAssertEqual(Double(resolved.redComponent), 1, accuracy: 0.001)
        XCTAssertEqual(Double(resolved.greenComponent), 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(Double(resolved.blueComponent), 0, accuracy: 0.001)
        XCTAssertEqual(BackdropRGB(10, 20, 30).color, BackdropRGB(10, 20, 30).color)
        XCTAssertNotEqual(BackdropRGB(10, 20, 30).color, BackdropRGB(30, 20, 10).color)
    }

    func testAdaptiveColorsMapEveryForegroundRole() {
        let family = BackdropForegroundFamily.light
        let colors = BackdropAdaptiveColors(profile: .darkCanvasFallback)
        XCTAssertEqual(colors.primary, family.primary.color)
        XCTAssertEqual(colors.secondary, family.secondary.color)
        XCTAssertEqual(colors.muted, family.muted.color)
        XCTAssertEqual(colors.accent, family.accent.color)
        XCTAssertEqual(colors.icon, family.icon.color)
        XCTAssertEqual(colors.focus, family.focus.color)
        XCTAssertEqual(colors.shadow, family.shadow.color)
        XCTAssertEqual(colors.scrim, family.scrim.color)
        // Roles must not collapse onto one another: a copy-paste swap here is
        // invisible in a screenshot but flattens the whole hierarchy.
        XCTAssertNotEqual(colors.primary, colors.muted)
        XCTAssertNotEqual(colors.accent, colors.icon)
        XCTAssertNotEqual(colors.shadow, colors.scrim)

        let inverted = BackdropAdaptiveColors(profile: .lightCanvasFallback)
        XCTAssertEqual(inverted.primary, BackdropForegroundFamily.dark.primary.color)
        XCTAssertNotEqual(inverted.primary, colors.primary)
    }

    func testEnvironmentCarriesReadabilityProfileWithDarkCanvasDefault() {
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.backdropReadabilityProfile, .darkCanvasFallback)
        environment.backdropReadabilityProfile = .lightCanvasFallback
        XCTAssertEqual(environment.backdropReadabilityProfile, .lightCanvasFallback)
        XCTAssertEqual(environment.backdropReadabilityProfile.interfaceColorScheme, .light)
    }

    func testDecodeRejectsNonNumericNumberFields() {
        // Every numeric field runs through the private `number(_:)` coercion.
        // A string payload (what a malformed JS bridge message actually sends)
        // must fail every cast and fail the decode closed rather than defaulting.
        for field in [
            "scrimOpacity", "minLuminance", "maxLuminance", "contrastRatio", "sampleCount"
        ] {
            var payload: [String: Any] = [
                "tone": "light",
                "scrimOpacity": 0.2,
                "minLuminance": 0.1,
                "maxLuminance": 0.9,
                "contrastRatio": 5.1,
                "sampleCount": 12,
                "source": "canvas"
            ]
            payload[field] = "not-a-number"
            XCTAssertNil(
                BackdropReadabilityProfile.decode(messageBody: payload),
                "decode must reject a non-numeric \(field)"
            )
        }
        XCTAssertNil(BackdropReadabilityProfile.decode(messageBody: "not-a-dictionary"))
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
