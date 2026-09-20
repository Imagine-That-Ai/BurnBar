import SwiftUI

// MARK: - Aurora Glass Variant

/// Visual flavor for an Aurora glass surface. Each variant tunes tint so the
/// same component can render hero, standard, urgent, success, or Hermes
/// contexts without bespoke views per case.
enum AuroraGlassVariant {
    /// Headline cards (Pulse Hero, Burn ring constellation).
    case hero
    /// Default content surface.
    case standard
    /// Compact chip / pill / inline glass.
    case compact
    /// Quota or threshold breach — warm warning tint.
    case urgent
    /// Positive milestone — green tint.
    case success
    /// Hermes mode.
    case hermes
}

// MARK: - LiquidGlassFallback
//
// iOS 26: system `glassEffect` only. No sheen fill, no white stroke, no
// material plate under glass — those collapse refraction into glassmorphism.
// iOS 17/18: ultraThinMaterial, still no decorative gradients.

struct LiquidGlassFallback: ViewModifier {
    let variant: AuroraGlassVariant
    let cornerRadius: CGFloat
    let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(opaqueFill, in: shape)
        } else if #available(iOS 26.0, *) {
            content.liquidGlassEffect(resolvedStyle, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    @available(iOS 26.0, *)
    private var resolvedStyle: LiquidGlassStyle {
        var style = LiquidGlassStyle.regular
        switch variant {
        case .urgent:
            style = style.tint(MobileTheme.warning.opacity(0.28))
        case .success:
            style = style.tint(MobileTheme.success.opacity(0.24))
        case .hero:
            style = style.tint(MobileTheme.ember.opacity(0.10))
        case .standard, .compact, .hermes:
            break
        }
        if isInteractive {
            style = style.interactive()
        }
        return style
    }

    private var opaqueFill: Color {
        switch variant {
        case .hero, .standard, .hermes: return MobileTheme.Colors.surface
        case .compact: return MobileTheme.Colors.surfaceElevated
        case .urgent: return MobileTheme.warning.opacity(0.12)
        case .success: return MobileTheme.success.opacity(0.12)
        }
    }
}

// MARK: - View Sugar

extension View {
    /// Apply Aurora glass to any view. Default = `.standard, cornerRadius: 16`.
    func auroraGlass(
        _ variant: AuroraGlassVariant = .standard,
        cornerRadius: CGFloat = AuroraDesign.Shape.standardCorner,
        interactive: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassFallback(
                variant: variant,
                cornerRadius: cornerRadius,
                isInteractive: interactive
            )
        )
    }
}
