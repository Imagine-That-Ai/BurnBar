import SwiftUI
import OpenBurnBarCore

// MARK: - Pro Theme
//
// The visual identity of OpenBurnBar Cloud surfaces. Designed as a
// "luxury island in utilitarian sea": Pro deliberately breaks from the
// daily-driver charcoal/cream utilitarian shell into obsidian + mercury foil
// + serif display, creating an "I WANT THAT" contrast. Free users encounter
// Pro as a whisper, a moment, or the poster — each a small refined object
// of desire.
//
// Composes existing primitives (`MobileTheme`, `AuroraDesign`,
// `UnifiedDesignSystem.mercuryGradient`) rather than introducing new tokens
// for free. Only the obsidian palette is net-new.

enum ProTheme {

    // MARK: - Palette
    enum Palette {
        /// Deep near-black background reserved for Pro surfaces. Different
        /// from the warm charcoal of the utilitarian shell so the contrast
        /// reads as a different, more desirable world.
        static let obsidian = Color(red: 0.040, green: 0.040, blue: 0.052)
        /// Slightly lifted obsidian for layered cards.
        static let obsidianElevated = Color(red: 0.070, green: 0.070, blue: 0.085)
        /// Warm silver — delegates to existing Hermes mercury.
        static let mercury = UnifiedDesignSystem.Colors.hermesMercury
        /// Platinum gold accent — delegates to existing aureate.
        static let aureate = UnifiedDesignSystem.Colors.hermesAureate
        /// Single ember pop reserved for CTAs and the crest center dot.
        static let emberPop = UnifiedDesignSystem.Colors.ember
        /// Foil-edge stroke (gradient). Composes existing aureate/mercury.
        static let aureateStroke = LinearGradient(
            colors: [
                aureate.opacity(0.95),
                mercury.opacity(0.98),
                aureate.opacity(0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        /// Darkened aurora ribbon — descends from the top edge of posters.
        /// Composed entirely from existing brand colors so we ship no new
        /// hex values.
        static let darkAuroraRibbon = LinearGradient(
            colors: [
                emberPop.opacity(0.32),
                UnifiedDesignSystem.Colors.amber.opacity(0.18),
                mercury.opacity(0.14),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Membership (adaptive)
    //
    // The redesigned Cloud destination wears two coats: an Obsidian
    // Black-Card in dark mode and a Warm Ember / botanical-letterpress
    // certificate in light mode. Every token below is adaptive via
    // `Color(light:dark:)`, so a single view tree renders luxuriously in
    // both appearances. Dark keeps the mercury/platinum foil; light gets a
    // brushed-gold leaf foil.
    enum Membership {
        /// Page backdrop fill. Obsidian near-black (dark) / warm parchment
        /// (light). Paired with `backdropGlow` for the ember vignette.
        static let backdrop = Color(light: "EDE7DA", dark: "0A0A0E")
        /// Primary card stock — the surface a tier/certificate card sits on.
        static let surface = Color(light: "F7F2E9", dark: "0B0B0F")
        /// Lifted card stock for nested rows / flagship interior.
        static let surfaceElevated = Color(light: "FBF8F1", dark: "121218")
        /// Engraved primary text (warm off-white / botanical ink).
        static let engraving = Color(light: "1C2014", dark: "F0EBE2")
        /// Secondary engraving — captions, metrics.
        static let engravingSoft = Color(light: "4A5442", dark: "B8B0A6")
        /// Muted engraving — disclosures, tertiary meta.
        static let engravingMuted = Color(light: "7A8572", dark: "8A8278")

        /// Foil leaf for headlines / price numerals.
        static let foilLeaf = Color(light: "A67C2E", dark: "C8BFB5")
        /// Brighter foil highlight for seals + active accents.
        static let foilHighlight = Color(light: "C9A24B", dark: "D7CFC4")

        /// Foil edge gradient — brushed gold (light) / platinum-mercury (dark).
        static let foilEdge = LinearGradient(
            colors: [
                Color(light: "E8D08A", dark: "D7CFC4").opacity(0.95),
                Color(light: "C9A24B", dark: "C8BFB5").opacity(0.98),
                Color(light: "A67C2E", dark: "A2ACBA").opacity(0.95)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Hairline divider tuned for each stock.
        static let hairline = Color(light: "C9A24B", dark: "A2ACBA")

        /// Ember vignette glow behind the backdrop (corner-anchored).
        static let backdropGlow = RadialGradient(
            colors: [
                Color(light: "C9A24B", dark: "E0A030").opacity(0.16),
                Color.clear
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: 520
        )

        /// Flagship halo behind the Cloud Pro tier card.
        static let flagshipGlow = RadialGradient(
            colors: [
                UnifiedDesignSystem.Colors.ember.opacity(0.30),
                UnifiedDesignSystem.Colors.amber.opacity(0.18),
                Color.clear
            ],
            center: .top,
            startRadius: 0,
            endRadius: 360
        )

        /// Inner letterpress shadow tint (light mode debossing; near-clear
        /// in dark so obsidian stays flat).
        static let letterpress = Color(light: "1C2014", dark: "000000")
    }

    // MARK: - Type voice
    /// Pro uses a serif display voice — deliberately distinct from the
    /// utilitarian SF Pro Rounded body voice. Body copy stays Rounded for
    /// legibility; serif is reserved for headlines and posters.
    enum Typography {
        /// 44pt heavy serif — the Pro voice. Hero headlines and posters.
        static let displaySerif = Font.system(size: 44, weight: .heavy, design: .serif)
        /// 28pt bold serif — secondary hero on poster cards.
        static let titleSerif = Font.system(size: 28, weight: .bold, design: .serif)
        /// 20pt semibold serif — section headers inside posters.
        static let headlineSerif = Font.system(size: 20, weight: .semibold, design: .serif)
        /// 22pt semibold monospaced — price strings ("$4.99 / mo").
        static let priceMono = Font.system(size: 22, weight: .semibold, design: .monospaced)
    }

    // MARK: - Motion
    enum Motion {
        /// One-shot specular sweep across the hero card on first render.
        static let specular = Animation.linear(duration: 2.8)
        /// Continuous mercury shimmer — matches existing 3s cycle.
        static let mercuryShimmer = UnifiedDesignSystem.Animation.mercuryShimmer
        /// Slow breathing for `ProBadgeDot` whisper.
        static let breathing = Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        /// Settling animation for poster moment transitions.
        static let posterSettle = Animation.spring(response: 0.55, dampingFraction: 0.78)
    }

    // MARK: - Layout
    enum Layout {
        static let cardRadius: CGFloat = MobileTheme.Radius.xl
        static let bandRadius: CGFloat = MobileTheme.Radius.lg
        static let foilStroke: CGFloat = 1.0
        static let crestLarge: CGFloat = 48
        static let crestMedium: CGFloat = 36
        static let crestSmall: CGFloat = 24
        static let badgeDot: CGFloat = 6
    }
}
