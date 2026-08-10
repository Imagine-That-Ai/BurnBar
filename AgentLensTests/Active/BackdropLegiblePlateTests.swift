import AppKit
import OpenBurnBarUI
import SwiftUI
import XCTest

@testable import OpenBurnBar

/// Proves the two halves of the backdrop-legibility contract, together.
///
/// The Control Deck shipped readable on a static canvas and unreadable the
/// moment a WebGL kernel was switched on, because both halves were missing and
/// each one alone is insufficient:
///
///   * The plate had no opaque substrate, so the animated mesh arrived at the
///     text unattenuated. Glass refracts; it does not darken.
///   * The ink was `DesignSystem.Colors.textMuted`, which cannot clear 4.5:1
///     against *any* background this app draws — including the app's own
///     `surface`. `testMutedTokenCannotClearBodyTextContrast` pins that fact so
///     nobody reintroduces it believing a thicker plate will save them.
///
/// The composite modelled here is deliberately conservative: backdrop → page
/// scrim → substrate slab → accent wash. It omits the glass layer, which blurs
/// and tints but does not systematically brighten, so a real plate is at least
/// as opaque as the one asserted against.
final class BackdropLegiblePlateTests: XCTestCase {

    // MARK: Colour resolution

    /// Resolve a SwiftUI `Color` to sRGB under an explicit appearance.
    ///
    /// Resolved live rather than pinned as a hex literal so a token edit in
    /// `DesignSystem` fails this test instead of silently drifting past it.
    private func rgba(
        _ color: Color,
        appearance name: NSAppearance.Name
    ) throws -> (rgb: BackdropRGB, alpha: Double) {
        var resolved: NSColor?
        let appearance = try XCTUnwrap(NSAppearance(named: name), "appearance \(name.rawValue)")
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let value = try XCTUnwrap(resolved, "\(color) is not representable in sRGB")
        return (
            BackdropRGB(
                Double(value.redComponent) * 255,
                Double(value.greenComponent) * 255,
                Double(value.blueComponent) * 255
            ),
            Double(value.alphaComponent)
        )
    }

    private func rgb(_ color: Color, appearance name: NSAppearance.Name) throws -> BackdropRGB {
        try rgba(color, appearance: name).rgb
    }

    /// Flatten a partly transparent colour against what is behind it.
    ///
    /// `NSColor` reports unpremultiplied components, so reading `.redComponent`
    /// off a `.opacity(0.7)` colour silently returns the *opaque* value and any
    /// contrast assertion built on it measures a colour that is never drawn.
    private func flattened(
        _ color: Color,
        over background: BackdropRGB,
        appearance name: NSAppearance.Name
    ) throws -> BackdropRGB {
        let (rgb, alpha) = try rgba(color, appearance: name)
        return BackdropContrast.composite(foreground: rgb, background: background, alpha: alpha)
    }

    /// A neutral canvas at an exact relative luminance, found by bisection.
    ///
    /// Every `BackdropReadabilityProfile` publishes the luminance band it was
    /// measured over; testing at the *top* of that band is the honest
    /// worst case for a light foreground family.
    private func canvas(luminance target: Double) -> BackdropRGB {
        var low = 0.0
        var high = 255.0
        for _ in 0..<48 {
            let mid = (low + high) / 2
            if BackdropContrast.relativeLuminance(BackdropRGB(mid, mid, mid)) < target {
                low = mid
            } else {
                high = mid
            }
        }
        return BackdropRGB(low, low, low)
    }

    /// backdrop → page scrim → substrate slab → accent wash.
    private func plate(
        over backdrop: BackdropRGB,
        profile: BackdropReadabilityProfile,
        surface: BackdropRGB,
        substrate: Double,
        accent: BackdropRGB,
        wash: Double
    ) -> BackdropRGB {
        let scrimmed = BackdropContrast.composite(
            foreground: profile.foreground.scrim,
            background: backdrop,
            alpha: profile.scrimOpacity
        )
        let slabbed = BackdropContrast.composite(
            foreground: surface,
            background: scrimmed,
            alpha: substrate
        )
        return BackdropContrast.composite(foreground: accent, background: slabbed, alpha: wash)
    }

    // MARK: The invariant that forced the ink change

    /// The token that made the deck unreadable, and why no plate can rescue it.
    func testMutedTokenCannotClearBodyTextContrast() throws {
        let muted = try rgb(DesignSystem.Colors.textMuted, appearance: .darkAqua)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)

        let onOwnSurface = BackdropContrast.ratio(muted, surface)
        XCTAssertLessThan(
            onOwnSurface,
            BackdropContrast.normalTextRatio,
            """
            `textMuted` now clears 4.5:1 on the app's own surface (\(onOwnSurface)). \
            If that is a deliberate token change, this test should be deleted and \
            `BackdropInk.resolve` may use it again. Until then it is a hairline token.
            """
        )

        // And it fails on the page background too, so both canvases the app
        // actually paints are out of reach. (It does clear 4.5:1 against pure
        // black — 4.57 — which is exactly the kind of number that makes this
        // token look survivable in isolation. The app never draws pure black.)
        let background = try rgb(DesignSystem.Colors.background, appearance: .darkAqua)
        XCTAssertLessThan(
            BackdropContrast.ratio(muted, background),
            BackdropContrast.normalTextRatio
        )
    }

    /// The replacement rung must clear the bar on the static canvas it serves.
    func testStaticInkClearsContrastOnTheAppsOwnSurface() throws {
        let ink = BackdropInk.resolve(liveBackdropActive: false, profile: .darkCanvasFallback)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)

        for (role, color) in [
            ("primary", ink.primary), ("secondary", ink.secondary), ("subtle", ink.subtle)
        ] {
            let ratio = BackdropContrast.ratio(try rgb(color, appearance: .darkAqua), surface)
            XCTAssertGreaterThanOrEqual(
                ratio, BackdropContrast.normalTextRatio,
                "static ink role \(role) is \(ratio):1 on surface"
            )
        }
    }

    // MARK: The live-backdrop contract

    /// Every text role stays readable on a deck tile over the worst backdrop
    /// the profile claims to cover, for every band accent and every wash rung.
    func testLiveInkClearsContrastOnEveryBandOverWorstCaseBackdrop() throws {
        let profile = BackdropReadabilityProfile.darkCanvasFallback
        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)
        let backdrop = canvas(luminance: profile.maxLuminance)

        // Every wash opacity `ControlTilePlate` can produce over a live
        // backdrop, brightest last.
        let washes: [Double] = [0.035, 0.05, 0.09]
        let accents: [(String, Color)] = ControlGroup.allCases.map { ($0.title, $0.accent) }
            + [("attention", DesignSystem.Colors.warning)]

        for (name, accent) in accents {
            let accentRGB = try rgb(accent, appearance: .darkAqua)
            for wash in washes {
                let composited = plate(
                    over: backdrop,
                    profile: profile,
                    surface: surface,
                    substrate: BackdropSubstrate.liveElevated,
                    accent: accentRGB,
                    wash: wash
                )
                for (role, color) in [
                    ("primary", ink.primary), ("secondary", ink.secondary), ("subtle", ink.subtle)
                ] {
                    let ratio = BackdropContrast.ratio(
                        try rgb(color, appearance: .darkAqua),
                        composited
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio, BackdropContrast.normalTextRatio,
                        "\(name) band, wash \(wash), role \(role): \(ratio):1"
                    )
                }
                let iconRatio = BackdropContrast.ratio(
                    try rgb(ink.icon, appearance: .darkAqua),
                    composited
                )
                XCTAssertGreaterThanOrEqual(
                    iconRatio, BackdropContrast.largeTextRatio,
                    "\(name) band, wash \(wash), icon: \(iconRatio):1"
                )
            }
        }
    }

    /// The shared substrate floor has to hold too — it is what any surface
    /// adopting `.backdropLegiblePlate()` without an override will get.
    func testSharedSubstrateFloorClearsContrast() throws {
        let profile = BackdropReadabilityProfile.darkCanvasFallback
        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)
        let composited = plate(
            over: canvas(luminance: profile.maxLuminance),
            profile: profile,
            surface: surface,
            substrate: BackdropSubstrate.live,
            accent: try rgb(DesignSystem.Colors.warning, appearance: .darkAqua),
            wash: 0.09
        )
        for (role, color) in [
            ("primary", ink.primary), ("secondary", ink.secondary), ("subtle", ink.subtle)
        ] {
            let ratio = BackdropContrast.ratio(try rgb(color, appearance: .darkAqua), composited)
            XCTAssertGreaterThanOrEqual(
                ratio, BackdropContrast.normalTextRatio,
                "shared substrate, role \(role): \(ratio):1"
            )
        }
    }

    /// The light-canvas profile resolves to the *dark* foreground family, which
    /// has to clear the bar on a light plate. Same contract, opposite polarity —
    /// light ink on paper would be the mirror image of the bug this fixes.
    ///
    /// Note this exercises the light `surface`, not the Editorial hex:
    /// `Color.adaptive(editorial:light:dark:)` only resolves its editorial arm
    /// when `AppSkin.current` is `.editorial`, and a unit test does not set the
    /// skin. The polarity assertion is the point.
    func testDarkFamilyClearsContrastOnALightPlate() throws {
        let profile = BackdropReadabilityProfile.lightCanvasFallback
        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
        let paper = try rgb(DesignSystem.Colors.surface, appearance: .aqua)

        for (role, color) in [
            ("primary", ink.primary), ("secondary", ink.secondary), ("subtle", ink.subtle)
        ] {
            let ratio = BackdropContrast.ratio(try rgb(color, appearance: .aqua), paper)
            XCTAssertGreaterThanOrEqual(
                ratio, BackdropContrast.normalTextRatio,
                "editorial role \(role): \(ratio):1"
            )
        }
    }

    // MARK: Substrate bounds

    /// The substrate is a trade, and both ends of it are load-bearing: too low
    /// and the ink fails, too high and the plate stops being glass. Pin the
    /// window so a future "just bump it" edit has to argue with a test.
    func testSubstrateOpacitiesStayInsideTheGlassWindow() {
        // Floor: below this the kernel's own hue bleeds through hard enough
        // that two tiles in one band stop matching each other.
        XCTAssertGreaterThanOrEqual(BackdropSubstrate.live, 0.65)
        // Ceiling: at 1.0 there is no backdrop left and the surface is an
        // opaque rectangle. Some of the kernel has to survive or the whole
        // live-backdrop feature is decorative.
        XCTAssertLessThanOrEqual(BackdropSubstrate.liveElevated, 0.88)
        XCTAssertGreaterThan(BackdropSubstrate.liveElevated, BackdropSubstrate.live)
    }

    /// The inactive dot tint is non-text, so it is graded at 3:1 — but it still
    /// has to be visible, which the token it replaced was not.
    func testInactiveDotTintClearsNonTextContrast() throws {
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)
        // Flattened, because the tint carries alpha — the whole reason its
        // predecessor was invisible was the 0.5 nobody composited.
        let inactive = try flattened(ControlDeckInk.inactive, over: surface, appearance: .darkAqua)
        let ratio = BackdropContrast.ratio(inactive, surface)
        XCTAssertGreaterThanOrEqual(
            ratio, BackdropContrast.largeTextRatio,
            "inactive dot is \(ratio):1 against the plate it sits on"
        )

        // The token it replaced, measured the same honest way, is why.
        let previous = try flattened(
            DesignSystem.Colors.textMuted.opacity(0.5),
            over: surface,
            appearance: .darkAqua
        )
        XCTAssertLessThan(
            BackdropContrast.ratio(previous, surface),
            BackdropContrast.largeTextRatio
        )

        // And it has to survive the *brighter* of the two plates it sits on.
        // This is the assertion that rules out a fractional alpha: every value
        // that looks appropriately quiet on flat `surface` falls under 3:1 here.
        let profile = BackdropReadabilityProfile.darkCanvasFallback
        let livePlate = plate(
            over: canvas(luminance: profile.maxLuminance),
            profile: profile,
            surface: surface,
            substrate: BackdropSubstrate.liveElevated,
            accent: try rgb(DesignSystem.Colors.warning, appearance: .darkAqua),
            wash: 0.09
        )
        let onLivePlate = try flattened(
            ControlDeckInk.inactive,
            over: livePlate,
            appearance: .darkAqua
        )
        let liveRatio = BackdropContrast.ratio(onLivePlate, livePlate)
        XCTAssertGreaterThanOrEqual(
            liveRatio, BackdropContrast.largeTextRatio,
            "inactive dot is \(liveRatio):1 on a tile plate over a live backdrop"
        )
    }
}
