package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * A unified filter applied at either the canvas or the widget level.
 * Widget-level filters override the canvas-level filter when set.
 */
@Serializable
data class InsightFilter(
    val window: InsightTimeWindow = InsightTimeWindow.Last7d,
    val providers: Set<String> = emptySet(),
    val models: Set<String> = emptySet(),
    val projects: Set<String> = emptySet(),
    val focuses: Set<String> = emptySet(),
    val useCases: Set<String> = emptySet(),
    val minCostUSD: Double? = null,
    val maxCostUSD: Double? = null
) {
    /** Merge with a widget override: widget keys win when non-empty. */
    fun overlaidBy(widget: InsightFilter?): InsightFilter {
        widget ?: return this
        return InsightFilter(
            window = widget.window,
            providers = widget.providers.ifEmpty { providers },
            models = widget.models.ifEmpty { models },
            projects = widget.projects.ifEmpty { projects },
            focuses = widget.focuses.ifEmpty { focuses },
            useCases = widget.useCases.ifEmpty { useCases },
            minCostUSD = widget.minCostUSD ?: minCostUSD,
            maxCostUSD = widget.maxCostUSD ?: maxCostUSD
        )
    }
}
