import SwiftUI

// MARK: - Spend Lens
//
// One lens, three modes for the burn-over-time card:
//   combined — the classic single curve (API + plan value as one number)
//   split    — two labeled mini-charts: real API dollars vs plan-covered value
//   overlay  — one graph, both series broken out on a shared axis
//
// Real dollars always carry the ember accent; plan-covered value renders in
// glacier blue and never steals focus. `unknown` cost is surfaced in copy when
// non-zero — it is never silently folded into either side.

enum SpendLensMode: String, CaseIterable, Identifiable {
    case combined
    case split
    case overlay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .combined: return "All"
        case .split: return "Split"
        case .overlay: return "Overlay"
        }
    }

    var help: String {
        switch self {
        case .combined: return "API and subscription spend as one curve"
        case .split: return "Real API dollars and plan-covered value side by side"
        case .overlay: return "Both series broken out on one graph"
        }
    }
}

extension DesignSystem.Colors {
    /// Plan-covered (subscription) spend accent — cool against ember's heat.
    static var planSpend: Color { glacier }
}

/// Liquid-glass segmented capsule. Follows the ChartCardView recipe: glass
/// carries the light, accent washes stay at 0.08 — the selection is a lens,
/// not a painted slab.
struct SpendLensPicker: View {
    @Binding var mode: SpendLensMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SpendLensMode.allCases) { candidate in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        mode = candidate
                    }
                } label: {
                    Text(candidate.label)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(
                            mode == candidate
                                ? DesignSystem.Colors.textPrimary
                                : DesignSystem.Colors.textMuted
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if mode == candidate {
                                Capsule().fill(
                                    DesignSystem.Colors.ember
                                        .opacity(colorScheme == .dark ? 0.16 : 0.10)
                                )
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(candidate.help)
            }
        }
        .padding(2)
        .background {
            let shape = Capsule()
            if #available(macOS 26, *) {
                shape
                    .fill(DesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.05 : 0.03))
                    .liquidGlassEffect(.regular, in: shape)
            } else {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(DesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.05 : 0.03))
                }
            }
        }
        .overlay(Capsule().stroke(DesignSystem.Colors.ember.opacity(0.18), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spend lens")
    }
}

/// The burn-over-time body under a spend lens. Combined mode is rendered by
/// the caller (the classic single line); this view owns split and overlay.
struct SpendLensBurnBody: View {
    let snapshot: ChartsSnapshot
    let mode: SpendLensMode

    /// Below half a cent, disclosing an unclassified bucket costs more
    /// attention than the money is worth. Shared by the pane, the legend, and
    /// the card headline so all three agree about when it exists.
    static let disclosureFloor: Double = 0.005

    private var sharedCeiling: Double {
        let apiMax = snapshot.apiBurnSeries.map(\.value).max() ?? 0
        let subMax = snapshot.subscriptionBurnSeries.map(\.value).max() ?? 0
        return max(apiMax, subMax)
    }

    var body: some View {
        switch mode {
        case .combined:
            ChartKitLine(values: snapshot.burnSeries.map(\.value), accent: DesignSystem.Colors.ember)
        case .split:
            HStack(spacing: DesignSystem.Spacing.md) {
                splitPane(
                    title: "API",
                    total: snapshot.apiCost,
                    values: snapshot.apiBurnSeries.map(\.value),
                    accent: DesignSystem.Colors.ember
                )
                splitPane(
                    title: "PLAN",
                    total: snapshot.subscriptionCost,
                    values: snapshot.subscriptionBurnSeries.map(\.value),
                    accent: DesignSystem.Colors.planSpend
                )
                // Unclassified spend gets its own pane rather than being
                // dropped. Split used to render API and Plan only, so this
                // money vanished from the curves *and* the headline while
                // Overlay showed it — the two modes disagreed about how much
                // had been spent. The pane appears only when there is
                // something to disclose, so the usual two-pane split is
                // unchanged.
                if snapshot.unknownBillingCost > Self.disclosureFloor {
                    splitPane(
                        title: "UNCLASSIFIED",
                        total: snapshot.unknownBillingCost,
                        values: snapshot.unknownBurnSeries.map(\.value),
                        accent: DesignSystem.Colors.textSecondary
                    )
                }
            }
        case .overlay:
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    // Plan value sits behind: line-only, quieter, same axis.
                    ChartKitLine(
                        values: snapshot.subscriptionBurnSeries.map(\.value),
                        accent: DesignSystem.Colors.planSpend,
                        fillsArea: false,
                        yMax: sharedCeiling
                    )
                    .opacity(0.85)
                    // Real dollars in front, carrying the area fill.
                    ChartKitLine(
                        values: snapshot.apiBurnSeries.map(\.value),
                        accent: DesignSystem.Colors.ember,
                        yMax: sharedCeiling
                    )
                }
                HStack(spacing: DesignSystem.Spacing.md) {
                    legendChip("API \(snapshot.apiCost.formatAsCost())", DesignSystem.Colors.ember)
                    legendChip("Plan \(snapshot.subscriptionCost.formatAsCost())", DesignSystem.Colors.planSpend)
                    if snapshot.unknownBillingCost > Self.disclosureFloor {
                        legendChip(
                            "Unclassified \(snapshot.unknownBillingCost.formatAsCost())",
                            DesignSystem.Colors.textMuted
                        )
                    }
                }
            }
        }
    }

    private func splitPane(title: String, total: Double, values: [Double], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer(minLength: 4)
                Text(total.formatAsCost())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            ChartKitLine(values: values, accent: accent)
        }
        .frame(maxWidth: .infinity)
    }

    private func legendChip(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }
}
