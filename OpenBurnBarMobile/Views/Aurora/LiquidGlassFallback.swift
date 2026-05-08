import SwiftUI

// MARK: - Aurora Glass Variant

/// Visual flavor for an Aurora glass surface. Each variant tunes tint, edge, and
/// sheen so the same component can render hero, standard, urgent, success, or
/// Hermes contexts without bespoke views per case.
enum AuroraGlassVariant {
    /// Headline cards (Pulse Hero, Burn ring constellation).
    case hero
    /// Default content surface.
    case standard
    /// Compact chip / pill / inline glass.
    case compact
    /// Quota or threshold breach — warm warning border.
    case urgent
    /// Positive milestone — green accent border.
    case success
    /// Hermes mode — mercury foil border.
    case hermes
}

// MARK: - LiquidGlassFallback
//
// One modifier that adopts iOS 26 `.glassEffect` when available and degrades
// to a hand-tuned `.ultraThinMaterial` + sheen + edge gradient on iOS 17/18.
// All Aurora surfaces should call `.auroraGlass(...)` instead of inlining
// branch logic — this keeps the glass system one knob to twist later.

struct LiquidGlassFallback: ViewModifier {
    let variant: AuroraGlassVariant
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background(backgroundLayer)
            .overlay(edgeLayer)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(opaqueFill)
        } else if #available(iOS 26.0, *) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(sheenGradient)
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(sheenGradient)
            }
        }
    }

    private var edgeLayer: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(edgeGradient, lineWidth: edgeWidth)
            .blendMode(.plusLighter)
    }

    // MARK: - Per-Variant Styling

    private var sheenGradient: LinearGradient {
        switch variant {
        case .hero:
            return LinearGradient(
                colors: [
                    MobileTheme.ember.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    Color.clear,
                    MobileTheme.amber.opacity(colorScheme == .dark ? 0.06 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .standard, .compact:
            return LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.45),
                    Color.clear,
                    MobileTheme.ember.opacity(colorScheme == .dark ? 0.03 : 0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .urgent:
            return LinearGradient(
                colors: [
                    MobileTheme.warning.opacity(0.18),
                    Color.clear,
                    MobileTheme.error.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .success:
            return LinearGradient(
                colors: [
                    MobileTheme.success.opacity(0.16),
                    Color.clear,
                    MobileTheme.success.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hermes:
            return LinearGradient(
                colors: [
                    MobileTheme.hermesMercury.opacity(0.12),
                    MobileTheme.hermesAureate.opacity(0.10),
                    MobileTheme.hermesMercury.opacity(0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var edgeGradient: LinearGradient {
        switch variant {
        case .hero:
            return LinearGradient(
                colors: [
                    MobileTheme.ember.opacity(0.55),
                    MobileTheme.amber.opacity(0.35),
                    MobileTheme.blaze.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .standard:
            return LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                    MobileTheme.Colors.border.opacity(0.45),
                    MobileTheme.ember.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .compact:
            return LinearGradient(
                colors: [
                    MobileTheme.Colors.border.opacity(0.45),
                    MobileTheme.Colors.borderSubtle.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .urgent:
            return LinearGradient(
                colors: [
                    MobileTheme.warning.opacity(0.85),
                    MobileTheme.error.opacity(0.65)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .success:
            return LinearGradient(
                colors: [
                    MobileTheme.success.opacity(0.7),
                    MobileTheme.success.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hermes:
            return AuroraDesign.Gradients.mercuryFoil
        }
    }

    private var edgeWidth: CGFloat {
        switch variant {
        case .hero:    return 1.0
        case .urgent, .success, .hermes: return 1.0
        case .standard, .compact: return 0.5
        }
    }

    private var opaqueFill: Color {
        switch variant {
        case .hero, .standard: return MobileTheme.Colors.surface
        case .compact:         return MobileTheme.Colors.surfaceElevated
        case .urgent:          return MobileTheme.warning.opacity(0.12)
        case .success:         return MobileTheme.success.opacity(0.12)
        case .hermes:          return MobileTheme.Colors.surface
        }
    }
}

// MARK: - View Sugar

extension View {
    /// Apply Aurora glass to any view. Default = `.standard, cornerRadius: 16`.
    func auroraGlass(
        _ variant: AuroraGlassVariant = .standard,
        cornerRadius: CGFloat = AuroraDesign.Shape.standardCorner
    ) -> some View {
        modifier(LiquidGlassFallback(variant: variant, cornerRadius: cornerRadius))
    }
}
