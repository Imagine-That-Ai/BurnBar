import SwiftUI
import UniformTypeIdentifiers

// MARK: - Charts Reorderable Grid
//
// N-column flow of chart cards (2 or 3 columns, from `ChartsAppearance`).
// Cards occupy `span` columns; rows flush when full. Reordering uses native
// drag & drop — drag any card onto another and it takes that card's
// position. Cards enter with a staggered rise on first appearance (gated by
// `accessibilityReduceMotion`).

struct ChartsReorderableGrid: View {
    let layout: ChartsPageLayout
    let snapshot: ChartsSnapshot
    let appearance: ChartsAppearance
    let onMove: (ChartKind, ChartKind) -> Void
    let onHide: (ChartKind) -> Void
    let onToggleSpan: (ChartKind) -> Void

    @State private var dropTargetKind: ChartKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columns: Int { appearance.columns }

    var body: some View {
        let rows = Self.rows(for: layout.visibleConfigs, columns: columns)
        Grid(alignment: .top, horizontalSpacing: DesignSystem.Spacing.md, verticalSpacing: DesignSystem.Spacing.md) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.configs.enumerated()), id: \.element.id) { cardIndex, config in
                        card(config)
                            .gridCellColumns(min(config.span, columns))
                            .staggeredAppearance(
                                index: rowIndex * columns + cardIndex,
                                reduceMotion: reduceMotion
                            )
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
            appearance: appearance,
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

    /// Packs configs into rows of `columns` slots: each card occupies
    /// `min(span, columns)` slots; a row flushes when the next card would
    /// overflow it. With the default 2 columns this reproduces the original
    /// pairing behavior exactly.
    static func rows(for configs: [ChartCardConfig], columns: Int = 2) -> [Row] {
        let columns = max(1, columns)
        var rows: [Row] = []
        var current: [ChartCardConfig] = []
        var used = 0
        for config in configs {
            let span = min(max(1, config.span), columns)
            if used + span > columns, !current.isEmpty {
                rows.append(Row(id: current.map(\.id).joined(separator: "+"), configs: current))
                current = []
                used = 0
            }
            current.append(config)
            used += span
        }
        if !current.isEmpty {
            rows.append(Row(id: current.map(\.id).joined(separator: "+"), configs: current))
        }
        return rows
    }
}

// MARK: - Staggered entrance

/// Rises a card into place with a small per-index delay on first appear.
/// No-ops under Reduce Motion.
private struct StaggeredAppearance: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .onAppear {
                guard !appeared, !reduceMotion else { return }
                withAnimation(DesignSystem.Animation.gentle.delay(Double(index) * 0.045)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func staggeredAppearance(index: Int, reduceMotion: Bool) -> some View {
        modifier(StaggeredAppearance(index: index, reduceMotion: reduceMotion))
    }
}
