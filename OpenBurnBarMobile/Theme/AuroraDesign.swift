import SwiftUI
import OpenBurnBarCore

// MARK: - Aurora Design Tokens
//
// Aurora Chrome — the iOS visual identity. Layered on top of MobileTheme,
// these tokens describe motion, gradients, and signature surfaces unique
// to the iOS rebuild. Anything not listed here delegates to `MobileTheme`
// (which delegates to `UnifiedDesignSystem`) so we keep one source of truth.

enum AuroraDesign {

    // MARK: - Hero Typography
    enum Typography {
        /// 44pt rounded bold — used by `RollingMetric` for headline numbers.
        static let displayHero = Font.system(size: 44, weight: .bold, design: .rounded)
        /// 32pt monospaced — used by inline cost/tokens that need digit-grid stability.
        static let monoDisplay = Font.system(size: 32, weight: .bold, design: .monospaced)
        /// 56pt rounded heavy — splash/onboarding only.
        static let titanic    = Font.system(size: 56, weight: .heavy, design: .rounded)
    }

    // MARK: - Aurora Gradients
    enum Gradients {

        /// Top-of-screen aurora ribbon — warm coral → amber → mercury sheen.
        static let auroraRibbon = LinearGradient(
            colors: [
                MobileTheme.ember.opacity(0.55),
                MobileTheme.amber.opacity(0.35),
                MobileTheme.hermesMercury.opacity(0.25),
                MobileTheme.whimsy.opacity(0.18)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        /// Card gradient with depth — three stops for a soft inner glow.
        static let heroCard = LinearGradient(
            colors: [
                MobileTheme.ember.opacity(0.18),
                MobileTheme.amber.opacity(0.08),
                MobileTheme.blaze.opacity(0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Specular highlight band — drifts on parallax.
        static let specular = LinearGradient(
            colors: [
                Color.white.opacity(0.0),
                Color.white.opacity(0.18),
                Color.white.opacity(0.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Mercury foil — used by Hermes surfaces and chrome highlights.
        static let mercuryFoil = LinearGradient(
            colors: [
                MobileTheme.hermesMercury.opacity(0.85),
                MobileTheme.hermesAureate.opacity(0.7),
                MobileTheme.hermesMercury.opacity(0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Provider-tinted aurora ring stroke for hero avatars.
        static func providerRing(for provider: AgentProvider) -> AngularGradient {
            let primary = MobileTheme.Colors.primary(for: provider)
            let accent  = MobileTheme.Colors.accent(for: provider)
            return AngularGradient(
                colors: [
                    primary.opacity(0.95),
                    accent.opacity(0.65),
                    primary.opacity(0.0),
                    accent.opacity(0.45),
                    primary.opacity(0.95)
                ],
                center: .center
            )
        }

        /// Generic ember angular ring.
        static let emberRing = AngularGradient(
            colors: [
                MobileTheme.ember,
                MobileTheme.amber,
                MobileTheme.blaze.opacity(0.0),
                MobileTheme.amber,
                MobileTheme.ember
            ],
            center: .center
        )
    }

    // MARK: - Animation
    enum Motion {
        /// Default settle — used everywhere unless a more specific token is needed.
        static let auroraSpring  = Animation.spring(response: 0.42, dampingFraction: 0.82)
        /// Snap-to-state — toggles, taps, chip-rail switches.
        static let auroraSnap    = Animation.spring(response: 0.28, dampingFraction: 0.78)
        /// Ambient drift used by the backdrop layer.
        static let auroraDrift   = Animation.linear(duration: 18).repeatForever(autoreverses: true)
        /// Aurora ribbon sweep across the top edge (slower for cinematic feel).
        static let auroraRibbon  = Animation.linear(duration: 22).repeatForever(autoreverses: true)
        /// Card hover — keep in sync with `UnifiedDesignSystem.Animation.hover`.
        static let cardHover     = Animation.spring(response: 0.25, dampingFraction: 0.82)
        /// Card press feedback.
        static let cardPress     = Animation.spring(response: 0.22, dampingFraction: 0.7)
        /// Hermes mercury shimmer (3s repeating).
        static let mercuryShimmer = Animation.linear(duration: 3).repeatForever(autoreverses: false)
    }

    // MARK: - Card Shape
    enum Shape {
        /// Rounded rectangle for hero glass cards (slightly larger than `.lg`).
        static let heroCorner: CGFloat = 22
        /// Rounded rectangle for standard cards (matches `MobileTheme.Radius.lg`).
        static let standardCorner: CGFloat = 16
        /// Rounded rectangle for compact glass chips.
        static let chipCorner: CGFloat = 12
    }

    // MARK: - Layout
    enum Layout {
        /// Stage padding used by Pulse hero strip.
        static let stagePadding: CGFloat = 20
        /// Card horizontal inset on iPhone.
        static let cardInset: CGFloat = 16
        /// Internal card padding for hero cards.
        static let heroPadding: CGFloat = 24
    }
}

// MARK: - Convenience Extensions on MobileTheme

extension MobileTheme {

    /// Aurora-flavored gradient slice used by section headers + delimiters.
    static let auroraSection = LinearGradient(
        colors: [ember.opacity(0.85), amber.opacity(0.65), Color.clear],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Hermes-ish mercury accent line for bottom of hero strip.
    static let mercuryAccent = LinearGradient(
        colors: [hermesMercury.opacity(0.7), hermesAureate.opacity(0.55), hermesMercury.opacity(0.7)],
        startPoint: .leading,
        endPoint: .trailing
    )
}
