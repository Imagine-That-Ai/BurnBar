import OpenBurnBarUI
import SwiftUI

enum BackdropForegroundTone: String, Sendable {
    case light
    case dark
}

struct BackdropRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }
}

enum BackdropContrast {
    static let normalTextRatio = 4.5
    static let largeTextRatio = 3.0

    static func linearChannel(_ channel: Double) -> Double {
        let value = min(1, max(0, channel / 255))
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    static func relativeLuminance(_ color: BackdropRGB) -> Double {
        0.2126 * linearChannel(color.red)
            + 0.7152 * linearChannel(color.green)
            + 0.0722 * linearChannel(color.blue)
    }

    static func ratio(_ first: BackdropRGB, _ second: BackdropRGB) -> Double {
        ratio(relativeLuminance(first), relativeLuminance(second))
    }

    static func ratio(_ first: Double, _ second: Double) -> Double {
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func composite(
        foreground: BackdropRGB,
        background: BackdropRGB,
        alpha: Double
    ) -> BackdropRGB {
        let opacity = min(1, max(0, alpha))
        return BackdropRGB(
            foreground.red * opacity + background.red * (1 - opacity),
            foreground.green * opacity + background.green * (1 - opacity),
            foreground.blue * opacity + background.blue * (1 - opacity)
        )
    }
}

struct BackdropForegroundFamily: Equatable, Sendable {
    let primary: BackdropRGB
    let secondary: BackdropRGB
    let muted: BackdropRGB
    let accent: BackdropRGB
    let icon: BackdropRGB
    let focus: BackdropRGB
    let shadow: BackdropRGB
    let scrim: BackdropRGB

    // cov:ignore-start -- Stored static declaration table, not executable logic.
    // LLVM emits no coverage counter for a multi-line stored static initializer,
    // so these lines are unreachable by any test rather than untested: across
    // the app sources this lane measures, 0 of the 57 `static let X = Type(`
    // declaration openers appear in the xccov archive, as do none of their
    // plain-literal argument lines. (The single-line form of the same
    // declaration is already excluded by the gate's own structural filter.)
    // The palette VALUES are behaviourally gated by BackdropReadabilityTests:
    // testForegroundFamiliesMeetTextAndIconThresholdsOnFallbackCanvases asserts
    // the WCAG normal-text/large-text ratio for every role in both families, and
    // testForegroundFamiliesAreToneSpecific pins the light/dark split.
    static let light = BackdropForegroundFamily(
        primary: BackdropRGB(255, 255, 255),
        secondary: BackdropRGB(235, 239, 246),
        muted: BackdropRGB(218, 224, 234),
        accent: BackdropRGB(255, 226, 166),
        icon: BackdropRGB(242, 246, 252),
        focus: BackdropRGB(255, 255, 255),
        shadow: BackdropRGB(0, 0, 0),
        scrim: BackdropRGB(5, 7, 11)
    )

    static let dark = BackdropForegroundFamily(
        primary: BackdropRGB(13, 17, 23),
        secondary: BackdropRGB(31, 41, 55),
        muted: BackdropRGB(55, 65, 81),
        accent: BackdropRGB(91, 52, 0),
        icon: BackdropRGB(24, 33, 45),
        focus: BackdropRGB(13, 17, 23),
        shadow: BackdropRGB(255, 255, 255),
        scrim: BackdropRGB(248, 250, 252)
    )
    // cov:ignore-end
}

struct BackdropReadabilityProfile: Equatable, Sendable {
    let tone: BackdropForegroundTone
    let scrimOpacity: Double
    let minLuminance: Double
    let maxLuminance: Double
    let contrastRatio: Double
    let sampleCount: Int
    let samplingDurationMs: Double
    let source: String

    var foreground: BackdropForegroundFamily {
        tone == .light ? .light : .dark
    }

    var interfaceColorScheme: ColorScheme {
        tone == .light ? .dark : .light
    }

    // cov:ignore-start -- Stored static declaration table, not executable logic.
    // Same LLVM limitation as BackdropForegroundFamily above: a multi-line
    // stored static initializer carries no coverage counter anywhere in this
    // lane, so these lines are unreachable by any test rather than untested.
    // Every field VALUE is asserted by
    // BackdropReadabilityTests.testNativeFallbackProfilesPinTheirPublishedShape,
    // the tone/scheme pairing by testInterfaceColorSchemeOpposesForegroundTone,
    // and the contrast behaviour by
    // testForegroundFamiliesMeetTextAndIconThresholdsOnFallbackCanvases.
    static let darkCanvasFallback = BackdropReadabilityProfile(
        tone: .light,
        scrimOpacity: 0.24,
        minLuminance: 0,
        maxLuminance: 0.18,
        contrastRatio: BackdropContrast.normalTextRatio,
        sampleCount: 0,
        samplingDurationMs: 0,
        source: "native-fallback"
    )

    static let lightCanvasFallback = BackdropReadabilityProfile(
        tone: .dark,
        scrimOpacity: 0.16,
        minLuminance: 0.62,
        maxLuminance: 1,
        contrastRatio: BackdropContrast.normalTextRatio,
        sampleCount: 0,
        samplingDurationMs: 0,
        source: "native-fallback"
    )
    // cov:ignore-end

    /// The same profile with a floor placed under its scrim.
    ///
    /// Used for the live-backdrop fallback, where the canvas is unknown and
    /// moving, so the veil needs more authority than a static canvas of the
    /// same tone requires. Raising a scrim only ever moves the plate *further*
    /// toward the tone's own extreme, so it cannot reduce contrast for the ink
    /// family this profile carries.
    func reinforcingScrim(atLeast floor: Double) -> BackdropReadabilityProfile {
        guard floor > scrimOpacity else { return self }
        return BackdropReadabilityProfile(
            tone: tone,
            scrimOpacity: min(1, floor),
            minLuminance: minLuminance,
            maxLuminance: maxLuminance,
            contrastRatio: contrastRatio,
            sampleCount: sampleCount,
            samplingDurationMs: samplingDurationMs,
            source: source
        )
    }

    static func nativeFallback(
        colorScheme: ColorScheme,
        appearanceSkin: AppSkin,
        liveBackdropActive: Bool
    ) -> BackdropReadabilityProfile {
        // Editorial is light-locked paper whatever the system appearance says,
        // so it answers before the appearance is consulted at all.
        if appearanceSkin == .editorial { return .lightCanvasFallback }

        // A live backdrop used to force the dark-canvas family outright, on the
        // assumption that every kernel paints dark. That is false in Light mode:
        // over a bright kernel it put the *light* ink family — white — on a light
        // field, which is exactly the "hard to read in light mode" report.
        //
        // The system appearance is the only honest signal available here. The
        // WebGL sampler overrides this the moment it publishes a real profile,
        // and the two native backdrops that never publish one (the swarm and the
        // constellation) both draw over `DesignSystem.Colors.background`, which
        // tracks the appearance. So the appearance is right in every case this
        // function actually answers for.
        let base = colorScheme == .dark ? darkCanvasFallback : lightCanvasFallback
        guard liveBackdropActive else { return base }

        // The tone is settled; what a live backdrop still changes is how much
        // veil the unknown canvas needs. Reinforce to the dark-canvas rung so
        // Light mode gets dark ink behind a stronger scrim rather than the
        // thinner veil a static light canvas can get away with.
        return base.reinforcingScrim(atLeast: darkCanvasFallback.scrimOpacity)
    }

    static func decode(messageBody: Any) -> BackdropReadabilityProfile? {
        guard
            let payload = messageBody as? [String: Any],
            let rawTone = payload["tone"] as? String,
            let tone = BackdropForegroundTone(rawValue: rawTone),
            let scrimOpacity = number(payload["scrimOpacity"]),
            let minLuminance = number(payload["minLuminance"]),
            let maxLuminance = number(payload["maxLuminance"]),
            let contrastRatio = number(payload["contrastRatio"]),
            let sampleCount = number(payload["sampleCount"]),
            let source = payload["source"] as? String,
            (0...1).contains(scrimOpacity),
            (0...1).contains(minLuminance),
            (0...1).contains(maxLuminance),
            contrastRatio >= 1,
            sampleCount >= 0
        else { return nil }
        let samplingDurationMs = max(0, number(payload["samplingDurationMs"]) ?? 0)

        return BackdropReadabilityProfile(
            tone: tone,
            scrimOpacity: scrimOpacity,
            minLuminance: minLuminance,
            maxLuminance: maxLuminance,
            contrastRatio: contrastRatio,
            sampleCount: Int(sampleCount.rounded()),
            samplingDurationMs: samplingDurationMs,
            source: source
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

private struct BackdropReadabilityProfileKey: EnvironmentKey {
    static let defaultValue = BackdropReadabilityProfile.darkCanvasFallback
}

extension EnvironmentValues {
    var backdropReadabilityProfile: BackdropReadabilityProfile {
        get { self[BackdropReadabilityProfileKey.self] }
        set { self[BackdropReadabilityProfileKey.self] = newValue }
    }
}

struct BackdropAdaptiveColors {
    let profile: BackdropReadabilityProfile

    var primary: Color { profile.foreground.primary.color }
    var secondary: Color { profile.foreground.secondary.color }
    var muted: Color { profile.foreground.muted.color }
    var accent: Color { profile.foreground.accent.color }
    var icon: Color { profile.foreground.icon.color }
    var focus: Color { profile.foreground.focus.color }
    var shadow: Color { profile.foreground.shadow.color }
    var scrim: Color { profile.foreground.scrim.color }
}
