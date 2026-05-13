import SwiftUI
import OpenBurnBarCore

/// Custom SwiftUI `Layout` that places widgets into a 12-column grid
/// based on each widget's `InsightLayout.CellPlacement`.
///
/// The macOS shell wraps this in a `ScrollView` and feeds it the current
/// canvas. Drag/resize mutate the `InsightLayout` in the environment;
/// the layout re-runs and the widgets snap to their new cells.
struct InsightsCanvasGridLayout: Layout {
    let layout: InsightLayout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        let maxRow = layout.placements.values.reduce(0) { max($0, $1.row + $1.rowSpan) }
        let height = CGFloat(maxRow) * layout.rowHeight + max(0, CGFloat(maxRow - 1)) * layout.gap
        return CGSize(width: width, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidth = max(
            0,
            (bounds.width - CGFloat(layout.columnCount - 1) * layout.gap) / CGFloat(layout.columnCount)
        )
        for (idx, subview) in subviews.enumerated() {
            // We use a per-subview tag indexing into the layout's ordered widget IDs.
            // Caller supplies subviews in the same order as canvas.widgets so we
            // recover the placement via the layout key — but to keep ordering
            // self-contained we use subview index → ordered placement key.
            guard idx < orderedPlacementKeys.count else {
                subview.place(at: bounds.origin, proposal: .zero)
                continue
            }
            let key = orderedPlacementKeys[idx]
            guard let placement = layout.placements[key] else {
                subview.place(at: bounds.origin, proposal: .zero)
                continue
            }
            let x = bounds.minX + CGFloat(placement.column) * (columnWidth + layout.gap)
            let y = bounds.minY + CGFloat(placement.row) * (layout.rowHeight + layout.gap)
            let w = CGFloat(placement.colSpan) * columnWidth + CGFloat(max(0, placement.colSpan - 1)) * layout.gap
            let h = CGFloat(placement.rowSpan) * layout.rowHeight + CGFloat(max(0, placement.rowSpan - 1)) * layout.gap
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: h))
        }
    }

    private var orderedPlacementKeys: [UUID] {
        layout.placements.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

/// SwiftUI wrapper that arranges canvas widgets in a deterministic order
/// and feeds them to the grid layout. Order matches `canvas.widgets`
/// (declared by the data layer), and the layout reads positions from
/// `canvas.layout.placements[widget.id]`.
///
/// Supports drag-to-move: long-press + drag a widget and on release the
/// widget snaps to the nearest cell. Spans clamp to the 12-column grid.
struct InsightsCanvasGridView: View {
    let canvas: InsightCanvas
    let selectedWidgetID: UUID?
    let onSelectWidget: (UUID) -> Void
    let onConfigureWidget: (UUID) -> Void
    let onCitationTapped: (InsightCitation) -> Void
    let onMoveWidget: (UUID, Int, Int) -> Void

    @State private var draggingWidgetID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let ordered = canvas.widgets.sorted { $0.id.uuidString < $1.id.uuidString }
            InsightsCanvasGridLayout(layout: canvas.layout) {
                ForEach(ordered) { widget in
                    widgetTile(widget: widget)
                }
            }
            .onAppear { containerWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, newWidth in containerWidth = newWidth }
        }
    }

    @ViewBuilder
    private func widgetTile(widget: InsightWidget) -> some View {
        let isDragged = draggingWidgetID == widget.id
        InsightWidgetRenderer(
            widget: widget,
            isSelected: widget.id == selectedWidgetID,
            onConfigure: { onConfigureWidget(widget.id) },
            onCitationTapped: onCitationTapped
        )
        .offset(isDragged ? dragTranslation : .zero)
        .opacity(isDragged ? 0.85 : 1.0)
        .scaleEffect(isDragged ? 1.02 : 1.0)
        .shadow(radius: isDragged ? 12 : 0, y: isDragged ? 6 : 0)
        .zIndex(isDragged ? 10 : 0)
        .onTapGesture { onSelectWidget(widget.id) }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { gesture in
                    if draggingWidgetID != widget.id {
                        draggingWidgetID = widget.id
                        onSelectWidget(widget.id)
                    }
                    dragTranslation = gesture.translation
                }
                .onEnded { gesture in
                    guard let placement = canvas.layout.placements[widget.id] else {
                        draggingWidgetID = nil
                        dragTranslation = .zero
                        return
                    }
                    let columnWidth = max(
                        1,
                        (containerWidth - CGFloat(canvas.layout.columnCount - 1) * canvas.layout.gap)
                            / CGFloat(canvas.layout.columnCount)
                    )
                    let dx = Int((gesture.translation.width / (columnWidth + canvas.layout.gap)).rounded())
                    let dy = Int((gesture.translation.height / (canvas.layout.rowHeight + canvas.layout.gap)).rounded())
                    let newColumn = max(0, min(canvas.layout.columnCount - placement.colSpan,
                                                placement.column + dx))
                    let newRow = max(0, placement.row + dy)
                    onMoveWidget(widget.id, newColumn, newRow)
                    withAnimation(UnifiedDesignSystem.Animation.gentle) {
                        draggingWidgetID = nil
                        dragTranslation = .zero
                    }
                }
        )
        .animation(UnifiedDesignSystem.Animation.snappy, value: isDragged)
        .contentShape(Rectangle())
    }
}
