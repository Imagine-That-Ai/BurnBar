import SwiftUI

/// Shared "liquid glass" plate for individual Insights cards, tiles, and rows.
///
/// When a live pixel backdrop is active (website / kernel backdrop) the card
/// surface becomes a real `.ultraThinMaterial` plate topped by the same warm
/// sheen `UnifiedGlassCard` uses, so the animated backdrop refracts through
/// instead of being hidden behind an opaque `surface` fill. Without a live
/// backdrop the treatment is byte-for-byte the previous solid surface, keeping
/// iPhone/iPad and static-skin rendering unchanged.
///
/// Callers keep their own accent stroke by passing it as `stroke`; the modifier
/// draws it as an inset `strokeBorder` on top of the plate.
public extension View {
    func glassCardSurface(
        cornerRadius: CGFloat,
        live: Bool,
        stroke: Color,
        lineWidth: CGFloat = 0.5
    ) -> some View {
        modifier(
            GlassCardSurfaceModifier(
                cornerRadius: cornerRadius,
                live: live,
                stroke: stroke,
                lineWidth: lineWidth
            )
        )
    }
}

struct GlassCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let live: Bool
    let stroke: Color
    var lineWidth: CGFloat = 0.5

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if live {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(sheenGradient)
                    }
                } else {
                    shape.fill(UnifiedDesignSystem.Colors.surface)
                }
            }
            .overlay(shape.strokeBorder(stroke, lineWidth: lineWidth))
    }

    /// Warm sheen ride-over, matching `UnifiedGlassCard.glassSheenGradient`
    /// (non-cooking mode) so glassy Insights cards read as the same material.
    private var sheenGradient: LinearGradient {
        if colorScheme == .light {
            return LinearGradient(
                colors: [
                    UnifiedDesignSystem.Colors.ember.opacity(0.07),
                    Color.clear,
                    UnifiedDesignSystem.Colors.blaze.opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear,
                    UnifiedDesignSystem.Colors.ember.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
