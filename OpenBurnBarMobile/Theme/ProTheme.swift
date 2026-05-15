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
