import SwiftUI

// MARK: - Charts chrome & ink
//
// One material, one rim, one accent. Every Charts surface shares the exact
// same glass plate — a dark neutral pane with a hairline lit top edge and no
// per-card colour. Colour enters a card only through its chart *ink*, never
// its plate, so the page reads as one coherent instrument rather than a bag
// of tinted slabs.

/// The single, uniform glass treatment every Charts surface shares: real
/// Liquid Glass on macOS 26 with a lit hairline rim, a hand-tuned material
/// stack on older systems. No accent tint on the plate.
struct ChartGlassCard: ViewModifier {
    var cornerRadius: CGFloat = DesignSystem.Radius.lg
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if #available(macOS 26, *) {
                    shape
                        .fill(.clear)
                        .liquidGlassEffect(.regular, in: shape)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.42 : 0.55))
                    }
                }
            }
            .overlay {
                // A single rim that is lit at the top edge and settles into the
                // neutral border below — the tell of real glass, no colour.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.14 : 0.55),
                            DesignSystem.Colors.border.opacity(0.5)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .clipShape(shape)
            // A quiet drop shadow lifts every card off whatever backdrop the
            // active layout is running — essential on the lighter Atelier wash
            // where a flat plate would vanish. Static, so no idle cost.
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12),
                radius: 12,
                y: 5
            )
    }
}

extension View {
    func chartGlassCard(cornerRadius: CGFloat = DesignSystem.Radius.lg) -> some View {
        modifier(ChartGlassCard(cornerRadius: cornerRadius))
    }
}

/// The Charts ink language. Cool silver is the default voice; ember is the
/// app's single signature accent, spent only on the burn/spend hero series and
/// on emphasis marks. Directional greens/ambers appear only on deltas.
enum ChartInk {
    /// Cool off-white — the near-monochrome silver the app's kernel is tuned to.
    static let neutral = DesignSystem.Colors.textPrimary
    /// The ember signature, for the spend-amount hero series and emphasis.
    static let signature = DesignSystem.Colors.ember
    /// Spend fell (good).
    static let down = DesignSystem.Colors.success
    /// Spend rose (worth a glance).
    static let up = DesignSystem.Colors.amber

    /// A monochrome ramp for stacked/segmented series that must stay legible
    /// without turning into confetti — five shades of one silver.
    static let neutralRamp: [Color] = [
        DesignSystem.Colors.textPrimary.opacity(0.92),
        DesignSystem.Colors.textPrimary.opacity(0.70),
        DesignSystem.Colors.textPrimary.opacity(0.52),
        DesignSystem.Colors.textPrimary.opacity(0.38),
        DesignSystem.Colors.textPrimary.opacity(0.27)
    ]
}
