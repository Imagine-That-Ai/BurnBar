import SwiftUI
import OpenBurnBarCore

// MARK: - Concept Stat Tile
//
// Compact glass KPI tile shared across the dashboard layout concepts: an
// uppercase accent label over a large monospaced value, optionally a caption.
// Mirrors the prototype's "BURN · TODAY / $2,784.83" cards. Wraps the shared
// `GlassCard` so it inherits the app's liquid-glass plate + transparency
// preference and Reduce Transparency fallback automatically.

struct ConceptStatTile: View {
    let label: String
    let value: String
    var caption: String?
    var accent: Color = DesignSystem.Colors.ember
    /// Visual weight — `.hero` for the headline burn card, `.compact` for KPI rows.
    var prominence: Prominence = .compact

    enum Prominence { case hero, compact }

    private var valueFont: Font {
        switch prominence {
        case .hero:    return .system(size: 32, weight: .bold, design: .monospaced)
        case .compact: return DesignSystem.Typography.monoLarge
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(label)
                    .font(DesignSystem.Typography.tiny)
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(accent)

                Text(value)
                    .font(valueFont)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: value)

                if let caption {
                    Text(caption)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
