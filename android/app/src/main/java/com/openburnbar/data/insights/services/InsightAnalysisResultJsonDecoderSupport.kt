package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisContext
import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightMissionCandidate
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.data.insights.InsightWidgetKind
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

internal fun decodeInsightAnalysisResultJson(content: String, request: InsightAnalysisRequest, usage: InsightTokenUsage?): InsightAnalysisResult {
    val root = extractInsightJsonObject(content)
    val resolver = InsightCitationResolver(request.context)
    val citations = root.optJSONArray("citations").toInsightCitationRefs().map { resolver.resolve(it) }
    val findings = decodeInsightFindings(root, resolver)
    val anomalies = decodeInsightAnomalies(root, resolver)
    val recommendations = decodeInsightRecommendations(root, resolver)
    val missions = decodeInsightMissionCandidates(root, resolver)
    val widgets = decodeInsightGeneratedWidgets(root, request, recommendations, resolver)
    val followUps = decodeInsightFollowUpQuestions(root)
    val result =
        InsightAnalysisResult(
            requestID = request.id,
            platform = InsightAnalysisPlatform.ANDROID,
            timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d,
            executiveSummary = root.optString("executiveSummary", "Insights analysis completed."),
            modelTag = request.selectedModel,
            contextBudget = request.context.budgetReport,
            findings = findings,
            anomalies = anomalies,
            recommendations = recommendations,
            missionCandidates = missions,
            generatedWidgets = widgets,
            followUpQuestions = followUps,
            citations = if (citations.isEmpty()) request.context.evidenceIndex.map { it.citation } else citations,
            tokenUsage = usage,
            estimatedCostUSD = usage?.estimatedCostUSD,
        )
    return result.copy(resultHash = insightAnalysisSha256(result.copy(resultHash = "").toString()))
}

private fun decodeInsightFindings(root: JSONObject, resolver: InsightCitationResolver): List<InsightFinding> =
    root.optJSONArray("findings").toInsightJsonObjects().map { obj ->
        InsightFinding(
            title = obj.optString("title", "Finding"),
            whyItMatters = obj.optString("whyItMatters", obj.optString("why_it_matters", "")),
            evidence = obj.optJSONArray("evidence").toInsightCitationRefs().map { resolver.resolve(it) },
            confidence = insightJsonConfidence(obj.optString("confidence")),
            severity = insightJsonSeverity(obj.optString("severity")),
            recommendedAction = obj.optString("recommendedAction", obj.optString("recommended_action", "Review the cited evidence.")),
        )
    }

private fun decodeInsightAnomalies(root: JSONObject, resolver: InsightCitationResolver): List<InsightAnomaly> =
    root.optJSONArray("anomalies").toInsightJsonObjects().map { obj ->
        InsightAnomaly(
            title = obj.optString("title", "Anomaly"),
            occurredAt = obj.optString("occurredAt").takeIf { it.isNotBlank() },
            detail = obj.optString("detail", ""),
            score = obj.optDouble("score", 0.0),
            evidence = obj.optJSONArray("evidence").toInsightCitationRefs().map { resolver.resolve(it) },
            confidence = insightJsonConfidence(obj.optString("confidence")),
        )
    }

private fun decodeInsightRecommendations(root: JSONObject, resolver: InsightCitationResolver): List<InsightRecommendation> =
    root.optJSONArray("recommendations").toInsightJsonObjects().map { obj ->
        InsightRecommendation(
            title = obj.optString("title", "Recommendation"),
            rationale = obj.optString("rationale", ""),
            recommendedAction = obj.optString("recommendedAction", obj.optString("recommended_action", "Review the cited evidence.")),
            estimatedImpact = obj.optString("estimatedImpact").takeIf { it.isNotBlank() },
            evidence = obj.optJSONArray("evidence").toInsightCitationRefs().map { resolver.resolve(it) },
            confidence = insightJsonConfidence(obj.optString("confidence")),
            severity = insightJsonSeverity(obj.optString("severity")),
        )
    }

private fun decodeInsightMissionCandidates(root: JSONObject, resolver: InsightCitationResolver): List<InsightMissionCandidate> =
    root.optJSONArray("missionCandidates").toInsightJsonObjects().map { obj ->
        InsightMissionCandidate(
            title = obj.optString("title", "Mission"),
            summary = obj.optString("summary", ""),
            projectID = obj.optString("projectID").takeIf { it.isNotBlank() },
            projectDisplayName = obj.optString("projectDisplayName").takeIf { it.isNotBlank() },
            lens = insightJsonMissionLens(obj.optString("lens")),
            priority = insightJsonMissionPriority(obj.optString("priority")),
            confidence = insightJsonConfidence(obj.optString("confidence")),
            expectedImpact = obj.optString("expectedImpact", obj.optString("expected_impact", "")),
            effort = insightJsonMissionEffort(obj.optString("effort")),
            acceptanceCriteria =
            obj.optJSONArray("acceptanceCriteria").toInsightStrings()
                .ifEmpty { obj.optJSONArray("acceptance_criteria").toInsightStrings() },
            sourceInsightIDs =
            obj.optJSONArray("sourceInsightIDs").toInsightStrings()
                .ifEmpty { obj.optJSONArray("source_insight_ids").toInsightStrings() },
            evidence = obj.optJSONArray("evidence").toInsightCitationRefs().map { resolver.resolve(it) },
            dispatchMetadata =
            obj.optJSONObject("dispatchMetadata").toInsightStringMap()
                .ifEmpty { obj.optJSONObject("dispatch_metadata").toInsightStringMap() },
        )
    }

private fun decodeInsightGeneratedWidgets(
    root: JSONObject,
    request: InsightAnalysisRequest,
    recommendations: List<InsightRecommendation>,
    resolver: InsightCitationResolver,
): List<InsightGeneratedWidget> = root.optJSONArray("generatedWidgets").toInsightJsonObjects()
    .take(request.maxGeneratedWidgets)
    .map { obj ->
        decodeInsightGeneratedWidget(
            kind = insightJsonWidgetKind(obj.optString("kind")),
            title = obj.optString("title", "Generated widget"),
            reason = obj.optString("reason", ""),
            citations = obj.optJSONArray("citations").toInsightCitationRefs().map { resolver.resolve(it) },
            modelTag = request.selectedModel,
            recommendation = recommendations.firstOrNull(),
        )
    }

private fun decodeInsightFollowUpQuestions(root: JSONObject): List<InsightFollowUpQuestion> =
    root.optJSONArray("followUpQuestions").toInsightJsonObjects().map { obj ->
        InsightFollowUpQuestion(
            question = obj.optString("question"),
            rationale = obj.optString("rationale").takeIf { it.isNotBlank() },
        )
    }

internal data class InsightCitationRef(val id: String?, val label: String)

internal class InsightCitationResolver(context: InsightAnalysisContext) {
    private val byID = context.evidenceIndex.associateBy { it.id.lowercase() }
    private val byCitationID = context.evidenceIndex.associateBy { it.citation.id.lowercase() }
    private val byLabel = context.evidenceIndex.associateBy { it.citation.label.lowercase() }

    fun resolve(ref: InsightCitationRef): InsightCitation {
        val id = ref.id?.lowercase()
        if (id != null) {
            byID[id]?.let { return it.citation }
            byCitationID[id]?.let { return it.citation }
        }
        byLabel[ref.label.lowercase()]?.let { return it.citation }
        return InsightCitation(
            id = ref.id ?: "query:${ref.label}",
            kind = InsightCitation.Kind.Query(ref.id ?: ref.label),
            label = ref.label,
        )
    }
}

internal fun JSONArray?.toInsightJsonObjects(): List<JSONObject> {
    if (this == null) return emptyList()
    return (0 until length()).mapNotNull { optJSONObject(it) }
}

internal fun JSONArray?.toInsightCitationRefs(): List<InsightCitationRef> = toInsightJsonObjects().map {
    InsightCitationRef(
        id = it.optString("id").takeIf { value -> value.isNotBlank() },
        label = it.optString("label", it.optString("id", "Evidence")),
    )
}

internal fun JSONArray?.toInsightStrings(): List<String> {
    if (this == null) return emptyList()
    return (0 until length()).mapNotNull { optString(it).takeIf { value -> value.isNotBlank() } }
}

internal fun JSONObject?.toInsightStringMap(): Map<String, String> {
    if (this == null) return emptyMap()
    return keys().asSequence().mapNotNull { key ->
        optString(key).takeIf { it.isNotBlank() }?.let { key to it }
    }.toMap()
}

internal fun extractInsightJsonObject(content: String): JSONObject {
    val trimmed =
        content.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
    val start = trimmed.indexOf('{')
    val end = trimmed.lastIndexOf('}')
    require(start >= 0 && end >= start) { "Model response did not contain JSON." }
    return JSONObject(trimmed.substring(start, end + 1))
}

internal fun insightJsonConfidence(raw: String): InsightConfidence = when (raw.lowercase()) {
    "high" -> InsightConfidence.HIGH
    "low" -> InsightConfidence.LOW
    else -> InsightConfidence.MEDIUM
}

internal fun insightJsonSeverity(raw: String): InsightSeverity = when (raw.lowercase()) {
    "critical" -> InsightSeverity.CRITICAL
    "high" -> InsightSeverity.HIGH
    "low" -> InsightSeverity.LOW
    "info" -> InsightSeverity.INFO
    else -> InsightSeverity.MEDIUM
}

internal fun insightJsonMissionLens(raw: String): InsightMissionCandidate.Lens = when (raw.replace("_", "").replace("-", "").lowercase()) {
    "accretion" -> InsightMissionCandidate.Lens.ACCRETION
    "diligence" -> InsightMissionCandidate.Lens.DILIGENCE
    "techdebt" -> InsightMissionCandidate.Lens.TECH_DEBT
    "routing" -> InsightMissionCandidate.Lens.ROUTING
    "quota" -> InsightMissionCandidate.Lens.QUOTA
    "focus" -> InsightMissionCandidate.Lens.FOCUS
    else -> InsightMissionCandidate.Lens.FOCUS
}

internal fun insightJsonMissionPriority(raw: String): InsightMissionCandidate.Priority = when (raw.lowercase()) {
    "critical" -> InsightMissionCandidate.Priority.CRITICAL
    "high" -> InsightMissionCandidate.Priority.HIGH
    "low" -> InsightMissionCandidate.Priority.LOW
    else -> InsightMissionCandidate.Priority.MEDIUM
}

internal fun insightJsonMissionEffort(raw: String): InsightMissionCandidate.Effort = when (raw.lowercase()) {
    "large" -> InsightMissionCandidate.Effort.LARGE
    "small" -> InsightMissionCandidate.Effort.SMALL
    else -> InsightMissionCandidate.Effort.MEDIUM
}

internal fun insightJsonWidgetKind(raw: String): InsightWidgetKind = when (raw) {
    "kpiTile" -> InsightWidgetKind.KPI_TILE
    "timeSeriesLine" -> InsightWidgetKind.TIME_SERIES_LINE
    "timeSeriesArea" -> InsightWidgetKind.TIME_SERIES_AREA
    "streamGraph" -> InsightWidgetKind.STREAM_GRAPH
    "barRanking" -> InsightWidgetKind.BAR_RANKING
    "donut" -> InsightWidgetKind.DONUT
    "treemap" -> InsightWidgetKind.TREEMAP
    "heatmap" -> InsightWidgetKind.HEATMAP
    "scatter" -> InsightWidgetKind.SCATTER
    "sankey" -> InsightWidgetKind.SANKEY
    "radar" -> InsightWidgetKind.RADAR
    "cohort" -> InsightWidgetKind.COHORT
    "funnel" -> InsightWidgetKind.FUNNEL
    "quotaPulse" -> InsightWidgetKind.QUOTA_PULSE
    "forecast" -> InsightWidgetKind.FORECAST
    "anomalyTable" -> InsightWidgetKind.ANOMALY_TABLE
    "recommendation" -> InsightWidgetKind.RECOMMENDATION
    "useCaseCluster" -> InsightWidgetKind.USE_CASE_CLUSTER
    "agentFocusMatrix" -> InsightWidgetKind.AGENT_FOCUS_MATRIX
    "modelFocusMatrix" -> InsightWidgetKind.MODEL_FOCUS_MATRIX
    "drilldownList" -> InsightWidgetKind.DRILLDOWN_LIST
    "mermaid" -> InsightWidgetKind.MERMAID
    "ascii" -> InsightWidgetKind.ASCII
    "composed" -> InsightWidgetKind.COMPOSED
    else -> InsightWidgetKind.NARRATIVE
}

internal fun insightAnalysisSha256(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }

internal fun decodeInsightGeneratedWidget(
    kind: InsightWidgetKind,
    title: String,
    reason: String,
    citations: List<InsightCitation>,
    modelTag: com.openburnbar.data.insights.InsightModelTag,
    recommendation: InsightRecommendation?,
): InsightGeneratedWidget {
    val (binding, data) =
        when (kind) {
            InsightWidgetKind.RECOMMENDATION -> {
                val value =
                    com.openburnbar.data.insights.InsightWidgetData.Recommendation(
                        headline = title,
                        rationale = reason,
                        action = recommendation?.recommendedAction ?: reason,
                        estimatedImpact = recommendation?.estimatedImpact,
                        citations = citations,
                    )
                com.openburnbar.data.insights.InsightDataBinding.Recommendation(value) to value
            }
            InsightWidgetKind.NARRATIVE -> {
                val value =
                    com.openburnbar.data.insights.InsightWidgetData.Narrative(
                        headline = title,
                        body = reason,
                        citations = citations,
                    )
                com.openburnbar.data.insights.InsightDataBinding.Narrative(value) to value
            }
            else -> insightJsonDefaultBinding(kind) to null
        }
    return InsightGeneratedWidget(
        widget =
        com.openburnbar.data.insights.InsightWidget(
            kind = kind,
            title = title,
            spec = insightJsonDefaultSpec(kind),
            dataBinding = binding,
            data = data,
            freshness = com.openburnbar.data.insights.InsightFreshness.FRESH,
            modelTag = modelTag,
            lastComputedAt = java.time.Instant.now().toString(),
            rationale = reason,
        ),
        reason = reason,
        citations = citations,
    )
}

private fun insightJsonDefaultBinding(kind: InsightWidgetKind): com.openburnbar.data.insights.InsightDataBinding = when (kind) {
    InsightWidgetKind.BAR_RANKING ->
        com.openburnbar.data.insights.InsightDataBinding.Ranking(
            "cost",
            com.openburnbar.data.insights.InsightWidgetSpec.Dimension.MODEL,
            INSIGHT_DEFAULT_RANKING_LIMIT,
            InsightTimeWindow.Last7d,
        )
    InsightWidgetKind.TIME_SERIES_LINE, InsightWidgetKind.TIME_SERIES_AREA, InsightWidgetKind.STREAM_GRAPH ->
        com.openburnbar.data.insights.InsightDataBinding.TimeSeries(
            "cost",
            com.openburnbar.data.insights.InsightWidgetSpec.Dimension.PROVIDER,
            InsightTimeWindow.Last7d,
        )
    InsightWidgetKind.QUOTA_PULSE -> com.openburnbar.data.insights.InsightDataBinding.Quota(null)
    InsightWidgetKind.ANOMALY_TABLE -> com.openburnbar.data.insights.InsightDataBinding.Anomaly(InsightTimeWindow.Last7d)
    else ->
        com.openburnbar.data.insights.InsightDataBinding.Narrative(
            com.openburnbar.data.insights.InsightWidgetData.Narrative(
                insightJsonTitleFor(kind),
                "Generated by the selected Insights model.",
            ),
        )
}

private fun insightJsonDefaultSpec(kind: InsightWidgetKind): com.openburnbar.data.insights.InsightWidgetSpec = when (kind) {
    InsightWidgetKind.BAR_RANKING -> com.openburnbar.data.insights.InsightWidgetSpec.Ranking(com.openburnbar.data.insights.InsightWidgetSpec.RankingSpec())
    InsightWidgetKind.TIME_SERIES_LINE -> com.openburnbar.data.insights.InsightWidgetSpec.TimeSeries(
        com.openburnbar.data.insights.InsightWidgetSpec.TimeSeriesSpec(),
    )
    InsightWidgetKind.TIME_SERIES_AREA ->
        com.openburnbar.data.insights.InsightWidgetSpec.TimeSeries(
            com.openburnbar.data.insights.InsightWidgetSpec.TimeSeriesSpec(
                style = com.openburnbar.data.insights.InsightWidgetSpec.TimeSeriesSpec.Style.AREA,
            ),
        )
    InsightWidgetKind.QUOTA_PULSE -> com.openburnbar.data.insights.InsightWidgetSpec.QuotaPulse(
        com.openburnbar.data.insights.InsightWidgetSpec.QuotaPulseSpec(),
    )
    InsightWidgetKind.ANOMALY_TABLE -> com.openburnbar.data.insights.InsightWidgetSpec.AnomalyTable(
        com.openburnbar.data.insights.InsightWidgetSpec.AnomalyTableSpec(),
    )
    InsightWidgetKind.RECOMMENDATION -> com.openburnbar.data.insights.InsightWidgetSpec.Recommendation(
        com.openburnbar.data.insights.InsightWidgetSpec.RecommendationSpec(),
    )
    else -> com.openburnbar.data.insights.InsightWidgetSpec.Narrative(com.openburnbar.data.insights.InsightWidgetSpec.NarrativeSpec())
}

private fun insightJsonTitleFor(kind: InsightWidgetKind): String = kind.displayName
