package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * A persistent dashboard composed of insight widgets.
 * Mirrors Swift InsightCanvas.
 */
@Serializable
data class InsightCanvas(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val summary: String? = null,
    val symbolName: String = "sparkles.tv",
    val theme: InsightTheme = InsightTheme.AURORA,
    val widgets: List<InsightWidget> = emptyList(),
    val layout: InsightLayout = InsightLayout(),
    val filter: InsightFilter = InsightFilter(),
    val modelTag: InsightModelTag? = null,
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val createdAt: String = "",
    val updatedAt: String = "",
    val lastRefreshedAt: String? = null,
    val origin: Origin = Origin.UserCreated,
    val sortIndex: Int = 0
) {
    @Serializable
    sealed class Origin {
        @Serializable data object UserCreated : Origin()
        @Serializable data class Template(val id: String) : Origin()
        @Serializable data class Composed(val prompt: String) : Origin()
        @Serializable data class Imported(val filename: String) : Origin()
    }

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
    }

    fun add(widget: InsightWidget): InsightCanvas {
        val newLayout = layout.placeNew(widget.id, widget.kind.defaultSpanColumns to widget.kind.defaultSpanRows)
        return copy(widgets = widgets + widget, layout = newLayout, updatedAt = nowISO())
    }

    fun remove(widgetID: String): InsightCanvas {
        return copy(
            widgets = widgets.filter { it.id != widgetID },
            layout = layout.remove(widgetID),
            updatedAt = nowISO()
        )
    }

    fun replace(widget: InsightWidget): InsightCanvas {
        val idx = widgets.indexOfFirst { it.id == widget.id }
        if (idx < 0) return this
        return copy(widgets = widgets.toMutableList().apply { this[idx] = widget }, updatedAt = nowISO())
    }

    /** Update a single widget in place via a mutation function. */
    fun update(widgetID: String, mutate: (InsightWidget) -> InsightWidget): InsightCanvas {
        val idx = widgets.indexOfFirst { it.id == widgetID }
        if (idx < 0) return this
        val updated = mutate(widgets[idx])
        return copy(widgets = widgets.toMutableList().apply { this[idx] = updated }, updatedAt = nowISO())
    }
}

private fun nowISO(): String = java.time.Instant.now().toString()
