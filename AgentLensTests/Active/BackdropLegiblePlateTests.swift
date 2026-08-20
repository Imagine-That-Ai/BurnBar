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

    // MARK: Skin pinning
    //
    // `DesignSystem.Colors` resolves through `Color.adaptive(editorial:light:
    // dark:)`, where the editorial hex wins over *any* `NSAppearance` once
    // `AppSkin.current == .editorial`. `AppSkin.current` reads
    // `UserDefaults.standard`, which in an app-hosted XCTest is the real
    // `com.openburnbar.app` domain — so an unpinned case resolves its colours
    // from whichever skin the developer last clicked in the shipped app, and
    // the same commit passes on one machine and fails on another.
    //
    // That is precisely how this file failed: it pinned `.darkCanvasFallback`
    // (the *light* ink family) while `surface` floated to editorial paper
    // (`#FFFEFB`), measuring white ink on white paper at 1.03:1. The app never
    // produces that pair — `BackdropReadabilityProfile.nativeFallback` maps
    // `.editorial` to `.lightCanvasFallback`, i.e. dark ink on paper — so the
    // failure was manufactured by the test, not by the deck. Pinning the skin
    // is what makes the profile argument mean anything at all.

    private var savedSkin: String?

    override func setUp() {
        super.setUp()
        savedSkin = UserDefaults.standard.string(forKey: AppSkin.storageKey)
        useSkin(.aurora)
    }

    override func tearDown() {
        if let savedSkin {
            UserDefaults.standard.set(savedSkin, forKey: AppSkin.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSkin.storageKey)
        }
        super.tearDown()
    }

    /// Pin the skin the token layer resolves against, so a case states the
    /// world it asserts about instead of inheriting the developer's.
    private func useSkin(_ skin: AppSkin) {
        UserDefaults.standard.set(skin.rawValue, forKey: AppSkin.storageKey)
    }

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

    /// The same contract under **Editorial**, which is a different pairing
    /// rather than the same one in another colour.
    ///
    /// Editorial is light-locked: `surface` becomes paper (`#FFFEFB`) whatever
    /// the system appearance says, and `nativeFallback` answers that by pinning
    /// the profile to `.lightCanvasFallback` — the *dark* ink family. So the
    /// readable combination here is dark ink on paper, and the failure mode is
    /// the mirror image of Aurora's: ink too light rather than too dark.
    ///
    /// This case exists because the skin was previously unpinned, which meant
    /// an Editorial machine ran the Aurora assertions against paper and failed,
    /// while the pairing Editorial actually ships was never asserted anywhere.
    func testEditorialInkClearsContrastOnPaperForEveryBand() throws {
        useSkin(.editorial)
        let profile = BackdropReadabilityProfile.nativeFallback(
            colorScheme: .light,
            appearanceSkin: .editorial,
            liveBackdropActive: true
        )
        XCTAssertEqual(
            profile, .lightCanvasFallback,
            "Editorial must resolve the dark ink family; otherwise this case asserts the wrong pairing"
        )

        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .aqua)
        let backdrop = canvas(luminance: profile.maxLuminance)
        let accents: [(String, Color)] = ControlGroup.allCases.map { ($0.title, $0.accent) }
            + [("attention", DesignSystem.Colors.warning)]

        for (name, accent) in accents {
            let accentRGB = try rgb(accent, appearance: .aqua)
            for wash in [0.035, 0.05, 0.09] {
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
                        try rgb(color, appearance: .aqua),
                        composited
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio, BackdropContrast.normalTextRatio,
                        "editorial \(name) band, wash \(wash), role \(role): \(ratio):1"
                    )
                }
                let iconRatio = BackdropContrast.ratio(
                    try rgb(ink.icon, appearance: .aqua),
                    composited
                )
                XCTAssertGreaterThanOrEqual(
                    iconRatio, BackdropContrast.largeTextRatio,
                    "editorial \(name) band, wash \(wash), icon: \(iconRatio):1"
                )
            }
        }
    }

    /// The skin genuinely changes what the token layer returns, so a case that
    /// forgets to pin it is measuring the developer's preference.
    ///
    /// Without this, a regression that made `Color.adaptive` ignore the skin
    /// would leave every other case here still green — they would simply all
    /// resolve Aurora and never notice Editorial had stopped working.
    func testSurfaceResolvesPerSkinRatherThanPerAppearance() throws {
        useSkin(.aurora)
        let aurora = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)
        useSkin(.editorial)
        let editorial = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)

        XCTAssertLessThan(
            BackdropContrast.relativeLuminance(aurora), 0.1,
            "Aurora surface should be a dark slab"
        )
        XCTAssertGreaterThan(
            BackdropContrast.relativeLuminance(editorial), 0.8,
            "Editorial surface should be paper even under .darkAqua — it is light-locked"
        )
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

    /// The empty Control Deck: a bright kernel sample publishes `tone: .dark`
    /// (near-black ink). That ink is readable on Aurora itself — the page
    /// title stays visible — and invisible on a dark `surface` slab. This is
    /// the pair the running deck actually painted.
    func testKernelSampledDarkInkDisappearsOnADarkSurfacePlate() throws {
        let profile = BackdropReadabilityProfile.lightCanvasFallback
        let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)
        let composited = plate(
            over: canvas(luminance: 0.72),
            profile: profile,
            surface: surface,
            substrate: BackdropSubstrate.liveElevated,
            accent: try rgb(DesignSystem.Colors.whimsy, appearance: .darkAqua),
            wash: 0.05
        )
        let ratio = BackdropContrast.ratio(
            try rgb(ink.primary, appearance: .darkAqua),
            composited
        )
        XCTAssertLessThan(
            ratio,
            BackdropContrast.normalTextRatio,
            "kernel-sampled dark ink on a dark plate is the empty-deck bug; got \(ratio):1"
        )
    }

    /// The plate override must ignore the kernel sample and use appearance
    /// tokens, so a bright Aurora still renders readable tile copy.
    func testPlateLocalInkClearsContrastOnADarkSurfaceEvenWhenSamplerPicksDarkInk() throws {
        let ink = BackdropInk.resolveForPlate(skin: .aurora, colorScheme: .dark)
        let surface = try rgb(DesignSystem.Colors.surface, appearance: .darkAqua)
        let composited = plate(
            over: canvas(luminance: 0.72),
            profile: .lightCanvasFallback,
            surface: surface,
            substrate: BackdropSubstrate.liveElevated,
            accent: try rgb(DesignSystem.Colors.whimsy, appearance: .darkAqua),
            wash: 0.05
        )
        for (role, color) in [
            ("primary", ink.primary), ("secondary", ink.secondary), ("subtle", ink.subtle)
        ] {
            let ratio = BackdropContrast.ratio(try rgb(color, appearance: .darkAqua), composited)
            XCTAssertGreaterThanOrEqual(
                ratio, BackdropContrast.normalTextRatio,
                "plate-local \(role) is \(ratio):1 on a dark tile over a bright kernel"
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

    /// Chrome sits at the top of the window, so it takes the top of the range.
    ///
    /// It is named apart from `liveElevated` because the constraints differ (a
    /// bar crosses the whole kernel gradient rather than one band of it), but it
    /// still has to live inside the same glass window — an opaque bar is a
    /// titlebar, not glass.
    func testChromeSubstrateSitsAtTheTopOfTheGlassWindow() {
        XCTAssertGreaterThanOrEqual(BackdropSubstrate.chrome, BackdropSubstrate.live)
        XCTAssertLessThanOrEqual(BackdropSubstrate.chrome, 0.88)
    }

    /// The command deck and status rail contract, in both appearances.
    ///
    /// The deck previously drew as pure clear glass with no substrate at all —
    /// `shape.fill(.clear).liquidGlassEffect(...)` — and its eyebrow copy used
    /// `textMuted`. Both halves are asserted here so the bars cannot regress to
    /// either one: chrome ink over a chrome plate, at the worst backdrop each
    /// profile claims to cover.
    func testChromeInkClearsContrastOverWorstCaseBackdropInBothAppearances() throws {
        for (label, appearance, profile) in [
            (
                "dark",
                NSAppearance.Name.darkAqua,
                BackdropReadabilityProfile.nativeFallback(
                    colorScheme: .dark,
                    appearanceSkin: .aurora,
                    liveBackdropActive: true
                )
            ),
            (
                "light",
                NSAppearance.Name.aqua,
                BackdropReadabilityProfile.nativeFallback(
                    colorScheme: .light,
                    appearanceSkin: .aurora,
                    liveBackdropActive: true
                )
            )
        ] {
            let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
            let surface = try rgb(DesignSystem.Colors.surface, appearance: appearance)
            // The chrome plate carries no accent wash, so the composite ends at
            // the slab. Pass the surface as its own accent at zero wash.
            let composited = plate(
                over: canvas(luminance: profile.maxLuminance),
                profile: profile,
                surface: surface,
                substrate: BackdropSubstrate.chrome,
                accent: surface,
                wash: 0
            )

            for (role, color) in [
                ("primary", ink.primary), ("secondary", ink.secondary), ("subtle", ink.subtle)
            ] {
                let ratio = BackdropContrast.ratio(try rgb(color, appearance: appearance), composited)
                XCTAssertGreaterThanOrEqual(
                    ratio, BackdropContrast.normalTextRatio,
                    "\(label) chrome, role \(role): \(ratio):1"
                )
            }
            let iconRatio = BackdropContrast.ratio(
                try rgb(ink.icon, appearance: appearance),
                composited
            )
            XCTAssertGreaterThanOrEqual(
                iconRatio, BackdropContrast.largeTextRatio,
                "\(label) chrome, icon: \(iconRatio):1"
            )
        }
    }

    /// The chrome bars must not fall back to the token that started all of this.
    ///
    /// The deck's eyebrow strings ("BURN RATE", "Updated", "Spend is live") were
    /// `textMuted`, which no plate can rescue. Assert the ink the bars now draw
    /// with is a different colour from that token in both appearances, so a
    /// revert to it is a test failure rather than a visual regression somebody
    /// has to notice.
    func testChromeSubtleInkIsNotTheHairlineToken() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let muted = try rgb(DesignSystem.Colors.textMuted, appearance: appearance)
            for live in [true, false] {
                let ink = BackdropInk.resolve(
                    liveBackdropActive: live,
                    profile: BackdropReadabilityProfile.nativeFallback(
                        colorScheme: appearance == .darkAqua ? .dark : .light,
                        appearanceSkin: .aurora,
                        liveBackdropActive: live
                    )
                )
                XCTAssertNotEqual(
                    try rgb(ink.subtle, appearance: appearance),
                    muted,
                    "chrome subtle ink resolved to the hairline token (live: \(live))"
                )
            }
        }
    }

    // MARK: The section primitive's own recipe

    /// Every `DashboardSection` a layout can build, in both appearances.
    ///
    /// The eight layouts are compositions of one container, which means the
    /// container's plate recipe is the single point where all of them succeed or
    /// fail together. `DashboardSection` has two substrate rungs (`.comfortable`
    /// and `.flush` take `live`; `.compact` takes `liveElevated` because it
    /// carries the smallest type in the app) and three wash rungs, and
    /// `.featured` at `0.10` is brighter than any wash the Control Deck produces
    /// — so the existing tile cases above do not cover it.
    ///
    /// Asserted at the top of each profile's luminance band, which is the
    /// worst case for the ink family that profile selects.
    func testSectionInkClearsContrastAtEveryDensityAndEmphasis() throws {
        // Mirrors `DashboardSection.substrate` and `DashboardSection.washOpacity`.
        let densities: [(String, Double)] = [
            ("comfortable", BackdropSubstrate.live),
            ("flush", BackdropSubstrate.live),
            ("compact", BackdropSubstrate.liveElevated)
        ]
        let emphases: [(String, Double)] = [
            ("quiet", 0.03), ("standard", 0.055), ("featured", 0.10)
        ]
        // The accents layouts actually pass a section, warm and cool.
        let accents: [(String, Color)] = [
            ("ember", DesignSystem.Colors.ember),
            ("amber", DesignSystem.Colors.amber),
            ("whimsy", DesignSystem.Colors.whimsy),
            ("blaze", DesignSystem.Colors.blaze),
            ("success", DesignSystem.Colors.success),
            ("warning", DesignSystem.Colors.warning),
            ("error", DesignSystem.Colors.error)
        ]

        for skin in [AppSkin.aurora, .editorial] {
            useSkin(skin)
            for scheme in [ColorScheme.light, .dark] {
                let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
                let profile = BackdropReadabilityProfile.nativeFallback(
                    colorScheme: scheme,
                    appearanceSkin: skin,
                    liveBackdropActive: true
                )
                let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
                let surface = try rgb(DesignSystem.Colors.surface, appearance: appearance)
                let backdrop = canvas(luminance: profile.maxLuminance)

                for (densityName, substrate) in densities {
                    for (emphasisName, wash) in emphases {
                        for (accentName, accent) in accents {
                            let composited = plate(
                                over: backdrop,
                                profile: profile,
                                surface: surface,
                                substrate: substrate,
                                accent: try rgb(accent, appearance: appearance),
                                wash: wash
                            )
                            let where_ = """
                            \(skin.rawValue)/\(scheme == .dark ? "dark" : "light") \
                            \(densityName)/\(emphasisName)/\(accentName)
                            """
                            for (role, color) in [
                                ("primary", ink.primary),
                                ("secondary", ink.secondary),
                                ("subtle", ink.subtle)
                            ] {
                                let ratio = BackdropContrast.ratio(
                                    try rgb(color, appearance: appearance),
                                    composited
                                )
                                XCTAssertGreaterThanOrEqual(
                                    ratio, BackdropContrast.normalTextRatio,
                                    "\(where_), role \(role): \(ratio):1"
                                )
                            }
                            let iconRatio = BackdropContrast.ratio(
                                try rgb(ink.icon, appearance: appearance),
                                composited
                            )
                            XCTAssertGreaterThanOrEqual(
                                iconRatio, BackdropContrast.largeTextRatio,
                                "\(where_), icon: \(iconRatio):1"
                            )
                        }
                    }
                }
            }
        }
    }

    /// A section's own hairline has to be visible without competing with its
    /// content. `DashboardSectionRule` and the share bars in
    /// `DashboardRankedRow` both draw with `ink.hairline`, so it needs to clear
    /// the non-text bar on the plate it divides — the previous divider token was
    /// `textMuted` at a fractional alpha, which on a live backdrop was nothing.
    func testSectionHairlineIsVisibleOnItsOwnPlate() throws {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let profile = BackdropReadabilityProfile.nativeFallback(
                colorScheme: scheme,
                appearanceSkin: .aurora,
                liveBackdropActive: true
            )
            let ink = BackdropInk.resolve(liveBackdropActive: true, profile: profile)
            let surface = try rgb(DesignSystem.Colors.surface, appearance: appearance)
            let composited = plate(
                over: canvas(luminance: profile.maxLuminance),
                profile: profile,
                surface: surface,
                substrate: BackdropSubstrate.live,
                accent: try rgb(DesignSystem.Colors.ember, appearance: appearance),
                wash: 0.055
            )
            let hairline = try flattened(ink.hairline, over: composited, appearance: appearance)
            let ratio = BackdropContrast.ratio(hairline, composited)
            // A rule is decoration, not information, so it is graded well below
            // the text bar — but it must be a measurable step, not a no-op.
            XCTAssertGreaterThan(
                ratio, 1.08,
                "section hairline is \(ratio):1 on its own plate — invisible"
            )
            XCTAssertLessThan(
                ratio, BackdropContrast.largeTextRatio,
                "section hairline is \(ratio):1 — loud enough to compete with content"
            )
        }
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
