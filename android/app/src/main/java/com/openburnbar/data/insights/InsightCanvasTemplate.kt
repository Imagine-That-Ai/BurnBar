package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Stamp-from-the-shelf canvas blueprint.
 * Mirrors Swift InsightCanvasTemplate — each template instantiates as a fully
 * editable InsightCanvas with fresh UUIDs.
 */
@Serializable
data class InsightCanvasTemplate(
    val id: String,
    val title: String,
    val summary: String,
    val symbolName: String,
    val theme: InsightTheme,
    val widgets: List<InsightWidget>,
    val layout: InsightLayout,
    val filter: InsightFilter
) {
    fun instantiate(): InsightCanvas {
        val oldToNew = mutableMapOf<String, String>()
        val renumberedWidgets = widgets.map { w ->
            val newId = java.util.UUID.randomUUID().toString()
            oldToNew[w.id] = newId
            w.copy(id = newId, freshness = InsightFreshness.STALE, lastComputedAt = null)
        }
        var renumberedLayout = InsightLayout(
            columnCount = layout.columnCount,
            rowHeight = layout.rowHeight,
            gap = layout.gap
        )
        for ((oldID, placement) in layout.placements) {
            val newID = oldToNew[oldID] ?: continue
            renumberedLayout = renumberedLayout.copy(
                placements = renumberedLayout.placements.toMutableMap().apply { put(newID, placement) }
            )
        }
        for (widget in renumberedWidgets) {
            if (widget.id !in renumberedLayout.placements) {
                renumberedLayout = renumberedLayout.placeNew(
                    widget.id,
                    widget.kind.defaultSpanColumns to widget.kind.defaultSpanRows
                )
            }
        }
        return InsightCanvas(
            title = title,
            summary = summary,
            symbolName = symbolName,
            theme = theme,
            widgets = renumberedWidgets,
            layout = renumberedLayout,
            filter = filter,
            origin = InsightCanvas.Origin.Template(id = id)
        )
    }
}
