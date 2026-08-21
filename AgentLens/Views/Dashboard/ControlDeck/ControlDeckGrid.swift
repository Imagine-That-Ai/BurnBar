import SwiftUI
import UniformTypeIdentifiers

// MARK: - Control Deck Grid
//
// One band's tiles, packed into rows by the shared `CardRowPacker` (the same
// rule the Charts gallery uses) and reorderable by drag.
//
// Reorder is **within this band only**: the grid is instantiated per group and
// `ControlDeckLayout.move(_:toPositionOf:)` refuses a cross-group move anyway,
// so a tile physically cannot leave its band. The bands are the map.
//
// Keyboard parity is not optional: drag-and-drop is unreachable from the
// keyboard, so every reorder and visibility action is also exposed as an
// `.accessibilityAction`, mirroring the context menu.

struct ControlDeckGrid<Tile: View>: View {
    let configs: [ControlTileConfig]
    let columns: Int
    /// The measured content column width. Zero before the first layout pass, in
    /// which case tiles fall back to an equal split for one frame.
    let contentWidth: CGFloat
    let accent: Color
    let onMove: (ControlKind, ControlKind) -> Void
    let onHide: (ControlKind) -> Void
    let onToggleSpan: (ControlKind) -> Void
    @ViewBuilder let tile: (ControlTileConfig) -> Tile

    @State private var dropTargetKind: ControlKind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spans: [Int] { configs.map(\.span) }

    var body: some View {
        let rows = CardRowPacker.rows(spans: spans, columns: columns)
        VStack(spacing: DesignSystem.Spacing.md) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let widths = renderedSpans(in: row)
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    ForEach(row, id: \.self) { index in
                        if configs.indices.contains(index) {
                            let config = configs[index]
                            if contentWidth > 0 {
                                // Explicit width: a span-2 tile really is
                                // twice a span-1 tile plus the gutter it
                                // swallows.
                                card(config)
                                    .frame(
                                        width: CardRowPacker.width(
                                            span: widths[index] ?? config.span,
                                            columns: columns,
                                            contentWidth: contentWidth,
                                            gutter: DesignSystem.Spacing.md
                                        )
                                    )
                            } else {
                                card(config).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : DesignSystem.Animation.gentle, value: configs)
    }

    /// The span each tile in a row is actually drawn at.
    ///
    /// The packer deliberately never reorders — the user's arrangement is the
    /// contract — so a band whose spans do not divide the column count leaves a
    /// hole at the end of the row. Five of the six bands do exactly that at four
    /// columns, which is why the deck read as a broken grid: ragged rows with
    /// dead space punched out of the right-hand side.
    ///
    /// Rather than reshuffle (which would make drag-to-reorder lie), the last
    /// tile in an underfull row absorbs the leftover columns. Order is
    /// preserved, every row reaches the edge of the content column, and the
    /// tile that grows is the one the eye already treats as the end of the row.
    private func renderedSpans(in row: [Int]) -> [Int: Int] {
        guard let last = row.last, configs.indices.contains(last) else { return [:] }
        let used = row.reduce(0) { total, index in
            guard configs.indices.contains(index) else { return total }
            return total + min(columns, max(1, configs[index].span))
        }
        let slack = columns - used
        guard slack > 0 else { return [:] }
        return [last: min(columns, max(1, configs[last].span) + slack)]
    }

    @ViewBuilder
    private func card(_ config: ControlTileConfig) -> some View {
        let isTarget = dropTargetKind == config.kind
        tile(config)
            .overlay {
                if isTarget {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .stroke(accent.opacity(0.8), lineWidth: 2)
                }
            }
            .scaleEffect(isTarget && !reduceMotion ? 1.01 : 1.0)
            .draggable(config.kind.rawValue) {
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
                guard let raw = items.first,
                      let dragged = ControlKind(rawValue: raw),
                      dragged != config.kind,
                      dragged.group == config.kind.group else { return false }
                onMove(dragged, config.kind)
                return true
            } isTargeted: { targeted in
                dropTargetKind = targeted ? config.kind : nil
            }
            .contextMenu {
                Button(config.span >= ControlDeckLayout.maxSpan ? "Make Compact" : "Make Wide") {
                    onToggleSpan(config.kind)
                }
                Button("Hide Tile") { onHide(config.kind) }
            }
            .accessibilityAction(named: config.span >= ControlDeckLayout.maxSpan ? "Make compact" : "Make wide") {
                onToggleSpan(config.kind)
            }
            .accessibilityAction(named: "Hide tile") { onHide(config.kind) }
            .accessibilityAction(named: "Move up") { moveRelative(config.kind, offset: -1) }
            .accessibilityAction(named: "Move down") { moveRelative(config.kind, offset: 1) }
    }

    /// Keyboard/VoiceOver equivalent of a drag: swap with the neighbour in this
    /// band. Silently no-ops at the ends rather than wrapping, which would move
    /// a tile the full width of the band on one keystroke.
    private func moveRelative(_ kind: ControlKind, offset: Int) {
        guard let index = configs.firstIndex(where: { $0.kind == kind }) else { return }
        let target = index + offset
        guard configs.indices.contains(target) else { return }
        onMove(kind, configs[target].kind)
    }
}
