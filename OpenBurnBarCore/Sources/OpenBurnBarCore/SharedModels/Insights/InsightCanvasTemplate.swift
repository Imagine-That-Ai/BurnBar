import Foundation

/// Stamp-from-the-shelf canvas blueprint.
///
/// Templates ship as Swift literals (registered in
/// `InsightCanvasTemplate.builtIn`) so the first-run experience is
/// instantly useful — no LLM round-trip required. Each template
/// instantiates as a fully editable `InsightCanvas`; the resulting canvas
/// loses no expressivity vs. a hand-built one.
public struct InsightCanvasTemplate: Codable, Hashable, Sendable, Identifiable {
    public let id: String                // stable string id
    public let title: String
    public let summary: String
    public let symbolName: String
    public let theme: InsightTheme
    public let widgets: [InsightWidget]
    public let layout: InsightLayout
    public let filter: InsightFilter

    public init(
        id: String,
        title: String,
        summary: String,
        symbolName: String,
        theme: InsightTheme,
        widgets: [InsightWidget],
        layout: InsightLayout,
        filter: InsightFilter
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbolName = symbolName
        self.theme = theme
        self.widgets = widgets
        self.layout = layout
        self.filter = filter
    }

    /// Stamp this template into a fresh canvas with new widget IDs and a
    /// rebuilt layout so two instances of the same template never clash.
    public func instantiate() -> InsightCanvas {
        // Re-id widgets so multiple instantiations of the same template
        // don't share UUIDs.
        var renumberedWidgets: [InsightWidget] = []
        var renumberedLayout = InsightLayout(
            columnCount: layout.columnCount,
            rowHeight: layout.rowHeight,
            gap: layout.gap
        )

        var oldToNew: [UUID: UUID] = [:]
        for w in widgets {
            let newID = UUID()
            oldToNew[w.id] = newID
            var copy = w
            // Replace the id by constructing a new widget with the new id.
            copy = InsightWidget(
                id: newID,
                kind: w.kind,
                title: w.title,
                subtitle: w.subtitle,
                spec: w.spec,
                dataBinding: w.dataBinding,
                data: w.data,
                filter: w.filter,
                freshness: .stale,
                modelTag: w.modelTag,
                lockedAt: w.lockedAt,
                lastComputedAt: nil,
                schemaVersion: w.schemaVersion,
                rationale: w.rationale
            )
            renumberedWidgets.append(copy)
        }

        // Translate any pre-defined placements from the template.
        for (oldID, placement) in layout.placements {
            if let newID = oldToNew[oldID] {
                renumberedLayout.placements[newID] = placement
            }
        }

        // Auto-place any widget that lacks an explicit placement. Most
        // templates ship with an empty layout and rely on this — the
        // result is a deterministic row-major flow using each widget's
        // default span.
        for widget in renumberedWidgets where renumberedLayout.placements[widget.id] == nil {
            renumberedLayout.placeNew(widgetID: widget.id, defaultSpan: widget.kind.defaultSpan)
        }

        return InsightCanvas(
            title: title,
            summary: summary,
            symbolName: symbolName,
            theme: theme,
            widgets: renumberedWidgets,
            layout: renumberedLayout,
            filter: filter,
            origin: .template(id: id)
        )
    }
}
