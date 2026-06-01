@file:Suppress("MatchingDeclarationName")

package com.openburnbar.data.insights.services.adapters

import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightLayout
import com.openburnbar.data.insights.InsightTheme

/**
 * Pure-Kotlin rule-based canvas builder. Zero-egress, zero-cost.
 * Produces a reasonable first canvas from the digest without calling any LLM.
 * Mirrors the Swift LocalRuleBasedAdapter heuristics.
 */
object LocalRuleBasedAdapter {
    fun buildCanvas(digest: InsightDigest, filter: InsightFilter = InsightFilter()): InsightCanvas {
        val widgets = mutableListOf<com.openburnbar.data.insights.InsightWidget>()
        val layout = InsightLayout()
        widgets.addAll(localRuleBasedKpiWidgets(digest))
        localRuleBasedCostTrendWidget(digest, filter)?.let { widgets.add(it) }
        localRuleBasedProviderDonutWidget(digest, filter)?.let { widgets.add(it) }
        localRuleBasedQuotaWidget(digest)?.let { widgets.add(it) }
        widgets.add(localRuleBasedOverviewWidget(digest))
        var canvasLayout = layout
        for (w in widgets) {
            canvasLayout = canvasLayout.placeNew(w.id, w.kind.defaultSpanColumns to w.kind.defaultSpanRows)
        }
        return InsightCanvas(
            title = "Today",
            summary = "Auto-generated overview",
            symbolName = "sparkles.tv",
            theme = InsightTheme.AURORA,
            widgets = widgets,
            layout = canvasLayout,
            filter = filter,
            origin = InsightCanvas.Origin.UserCreated,
        )
    }
}
