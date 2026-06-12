
package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightModelTag
import java.security.MessageDigest

internal data class BoundInsightWidgetParams(
    val kind: InsightWidgetKind,
    val title: String,
    val dataBinding: InsightDataBinding,
    val data: InsightWidgetData?,
    val reason: String,
    val modelTag: InsightModelTag,
    val citations: List<InsightCitation>,
)

internal fun ruleBasedMaterializeCanvas(result: InsightAnalysisResult, prompt: String): InsightCanvas {
    var canvas =
        InsightCanvas(
            title = "Intelligence Brief",
            summary = result.executiveSummary,
            symbolName = "sparkles.tv",
            theme = InsightTheme.AURORA,
            widgets = emptyList(),
            filter = com.openburnbar.data.insights.InsightFilter(window = result.timeWindow),
            modelTag = result.modelTag,
            origin = com.openburnbar.data.insights.InsightCanvas.Origin.Composed(prompt),
        )
    result.generatedWidgets.forEach { generated ->
        canvas = canvas.add(generated.widget.copy(modelTag = result.modelTag))
    }
    return canvas
}

internal fun ruleBasedEnrichMissionCandidates(
    result: InsightAnalysisResult,
    request: InsightAnalysisRequest,
    platform: InsightAnalysisPlatform,
): InsightAnalysisResult {
    if (result.missionCandidates.isNotEmpty()) return result
    val baseline = buildRuleBasedInsightResult(request, platform)
    if (baseline.missionCandidates.isEmpty()) return result
    val enriched = result.copy(missionCandidates = baseline.missionCandidates, resultHash = "")
    return enriched.copy(resultHash = ruleBasedInsightSha256(enriched.toString()))
}

internal fun ruleBasedGeneratedWidget(params: BoundInsightWidgetParams): InsightGeneratedWidget {
    val spec =
        when (params.kind) {
            InsightWidgetKind.NARRATIVE -> InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec())
            InsightWidgetKind.BAR_RANKING -> InsightWidgetSpec.Ranking(InsightWidgetSpec.RankingSpec())
            InsightWidgetKind.TIME_SERIES_LINE -> InsightWidgetSpec.TimeSeries(InsightWidgetSpec.TimeSeriesSpec())
            else -> InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec())
        }
    return InsightGeneratedWidget(
        widget =
        InsightWidget(
            kind = params.kind,
            title = params.title,
            spec = spec,
            dataBinding = params.dataBinding,
            data = params.data,
            freshness = com.openburnbar.data.insights.InsightFreshness.FRESH,
            modelTag = params.modelTag,
            rationale = params.reason,
        ),
        reason = params.reason,
        citations = params.citations,
    )
}

internal fun ruleBasedCurrency(value: Double): String = "$" + String.format(java.util.Locale.US, "%.2f", value)

internal fun ruleBasedInsightSha256(value: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    return digest.joinToString("") { "%02x".format(it) }
}
