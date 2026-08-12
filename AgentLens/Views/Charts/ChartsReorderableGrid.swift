import SwiftUI
import UniformTypeIdentifiers

// MARK: - Charts Reorderable Grid
//
// Two-column flow of chart cards. Full-width cards (span 2) occupy a row;
// half-width cards pair up. Reordering uses native drag & drop — drag any
// card onto another and it takes that card's position (the same semantic as
// the insights canvas move, without the pixel math).

struct ChartsReorderableGrid: View {
    let layout: ChartsPageLayout
    let snapshot: ChartsSnapshot
    let onMove: (ChartKind, ChartKind) -> Void
    let onHide: (ChartKind) -> Void
    let onToggleSpan: (ChartKind) -> Void

    @State private var dropTargetKind: ChartKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = Self.rows(for: layout.visibleConfigs)
        VStack(spacing: DesignSystem.Spacing.md) {
            ForEach(rows, id: \.id) { row in
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ForEach(row.configs) { config in
                        card(config)
                    }
                    if row.configs.count == 1 && row.configs[0].span == 1 {
                        // Odd half-width card — hold the column so widths stay stable.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: layout.configs)
    }

    @ViewBuilder
    private func card(_ config: ChartCardConfig) -> some View {
        let isTarget = dropTargetKind == config.kind
        ChartCardView(
            config: config,
            snapshot: snapshot,
            onHide: { onHide(config.kind) },
            onToggleSpan: { onToggleSpan(config.kind) }
        )
        .overlay {
            if isTarget {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .stroke(DesignSystem.Colors.ember.opacity(0.8), lineWidth: 2)
            }
        }
        .scaleEffect(isTarget && !reduceMotion ? 1.01 : 1.0)
        .draggable(config.kind.rawValue) {
            // Compact drag preview keeps the gesture readable.
            HStack(spacing: 6) {
                Image(systemName: config.kind.systemImage)
                Text(config.kind.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(DesignSystem.Colors.surface))
        }
        .dropDestination(for: String.self) { items, _ in
            dropTargetKind = nil
            guard let raw = items.first, let dragged = ChartKind(rawValue: raw),
                  dragged != config.kind else { return false }
            onMove(dragged, config.kind)
            return true
        } isTargeted: { targeted in
            dropTargetKind = targeted ? config.kind : nil
        }
        .accessibilityHint("Drag onto another chart to reorder. Use the context menu to hide or resize.")
    }

    // MARK: Row packing

    struct Row: Identifiable {
        let id: String
        let configs: [ChartCardConfig]
    }

    /// Packs configs into rows: span-2 cards get their own row; span-1 cards
    /// pair with the next span-1 card in order.
    ///
    /// The rule itself now lives in `CardRowPacker`, shared with the Control
    /// Deck's grid, which needs the identical packing at two, three, and four
    /// columns. At `columns: 2` the shared packer reproduces the previous
    /// hand-rolled algorithm index for index — `CardRowPackerTests` pins that,
    /// and the row ids below are built exactly as before so `ForEach` identity
    /// (and therefore the reorder animation) is unchanged.
    static func rows(for configs: [ChartCardConfig]) -> [Row] {
        CardRowPacker.rows(spans: configs.map(\.span), columns: 2).map { indices in
            let rowConfigs = indices.compactMap { configs.indices.contains($0) ? configs[$0] : nil }
            return Row(id: rowConfigs.map(\.id).joined(separator: "+"), configs: rowConfigs)
        }
    }
}
