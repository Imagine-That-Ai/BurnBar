package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisContext
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightEvidence
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightWidgetSpec
import com.openburnbar.data.insights.InsightAnalysisAuditEntry
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.data.repos.InsightAnalysisAuditLogRepository
import com.openburnbar.data.repos.InsightAnalysisCacheRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

interface InsightAnalysisEngine {
    suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult
}

interface InsightAnalysisModelGateway {
    val providerKey: String
    val displayName: String
    val models: List<InsightModelTag>
    suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult
}

/**
 * Android orchestrator. Enforces local-only mode, dispatches to the selected
 * registered user-owned model gateway, and wraps every run in the analysis
 * cache and audit log so it is content-addressed and attributable.
 *
 * `auditLog` and `cache` are optional so the engine can be constructed
 * cheaply in previews/tests where filesystem access isn't desired.
 */
class AndroidInsightAnalysisEngine(
    private val auditLog: InsightAnalysisAuditLogRepository? = null,
    private val cache: InsightAnalysisCacheRepository? = null,
    private val fallback: InsightAnalysisEngine = RuleBasedInsightAnalysisEngine(InsightAnalysisPlatform.ANDROID),
    private val gateways: Map<String, InsightAnalysisModelGateway> = emptyMap(),
    private val restrictToLocalOnly: Boolean = false,
) : InsightAnalysisEngine {
    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult {
        val cacheKey = InsightAnalysisCacheRepository.key(
            prompt = request.prompt,
            digestContentHash = request.context.digest.contentHash,
            modelID = request.selectedModel.modelID,
            instruction = request.instruction,
        )
        cache?.lookup(cacheKey)?.let { return it.result }

        val auditID = UUID.randomUUID().toString()
        val startedAt = Instant.now().toString()
        val timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d
        val startedEntry = InsightAnalysisAuditEntry(
            id = auditID,
            requestID = request.id,
            platform = InsightAnalysisPlatform.ANDROID,
            selectedModel = request.selectedModel,
            egressTier = request.selectedModel.egressTier,
            timeWindow = timeWindow,
            contextBudget = request.context.budgetReport,
            includedDataSources = request.context.budgetReport.includedDataSources,
            truncationSummary = request.context.budgetReport.truncationSummary,
            promptHash = promptHashOf(request.prompt),
            resultHash = "",
            status = InsightAnalysisAuditEntry.Status.STARTED,
            startedAt = startedAt,
            ranAt = startedAt,
        )
        auditLog?.upsertLatest(startedEntry)

        return try {
            val raw = executeSelectedModel(request)
            val result = raw.copy(auditID = auditID)
            val completedAt = Instant.now().toString()
            val completedEntry = startedEntry.copy(
                selectedModel = result.modelTag,
                egressTier = result.modelTag.egressTier,
                timeWindow = result.timeWindow,
                contextBudget = result.contextBudget,
                includedDataSources = result.contextBudget.includedDataSources,
                truncationSummary = result.contextBudget.truncationSummary,
                resultHash = result.resultHash,
                status = InsightAnalysisAuditEntry.Status.SUCCEEDED,
                completedAt = completedAt,
                tokenUsage = result.tokenUsage,
                estimatedCostUSD = result.estimatedCostUSD,
                ranAt = completedAt,
            )
            auditLog?.upsertLatest(completedEntry)
            cache?.store(InsightAnalysisCacheRepository.cachedNow(cacheKey, result))
            result
        } catch (t: Throwable) {
            val failedAt = Instant.now().toString()
            val failed = startedEntry.copy(
                status = InsightAnalysisAuditEntry.Status.FAILED,
                completedAt = failedAt,
                errorDescription = t.message ?: t.javaClass.simpleName,
                ranAt = failedAt,
            )
            auditLog?.upsertLatest(failed)
            throw t
        }
    }

    companion object {
        private fun promptHashOf(prompt: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest(prompt.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
    }

    private suspend fun executeSelectedModel(request: InsightAnalysisRequest): InsightAnalysisResult {
        if (restrictToLocalOnly && request.selectedModel.egressTier != InsightEgressTier.LOCAL_ONLY) {
            error("${request.selectedModel.displayName} cannot be used while local-only mode is enabled.")
        }
        if (request.selectedModel.providerKey == "local-rules") {
            return fallback.analyze(request)
        }
        val gateway = gateways[request.selectedModel.providerKey]
            ?: error("No Android Insights gateway is configured for ${request.selectedModel.providerKey}.")
        return gateway.analyze(request)
    }
}

class OllamaInsightAnalysisGateway(
    private val baseURL: String = "http://127.0.0.1:11434",
    private val client: OkHttpClient = OkHttpClient(),
) : InsightAnalysisModelGateway {
    override val providerKey: String = "ollama"
    override val displayName: String = "Ollama"
    override val models: List<InsightModelTag> = listOf(
        InsightModelTag(
            providerKey = providerKey,
            modelID = "llama3.1",
            displayName = "Ollama llama3.1",
            egressTier = InsightEgressTier.LOCAL_ONLY,
            stampedAt = Instant.now().toString(),
        )
    )

    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult = withContext(Dispatchers.IO) {
        val startedAt = Instant.now().toString()
        val body = JSONObject().apply {
            put("model", request.selectedModel.modelID)
            put("stream", false)
            put("format", "json")
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "system")
                    put("content", analysisSystemPrompt(request))
                })
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request))
                })
            })
        }
        val httpRequest = Request.Builder()
            .url(baseURL.trimEnd('/') + "/api/chat")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        client.newCall(httpRequest).execute().use { response ->
            if (!response.isSuccessful) error("Ollama returned HTTP ${response.code}")
            val raw = response.body?.string().orEmpty()
            val root = JSONObject(raw)
            val content = root.optJSONObject("message")?.optString("content")
                ?: root.optString("content", raw)
            val usage = InsightTokenUsage(
                providerKey = providerKey,
                modelID = request.selectedModel.modelID,
                inputTokens = root.optInt("prompt_eval_count", 0),
                outputTokens = root.optInt("eval_count", 0),
                estimatedCostUSD = 0.0,
                startedAt = startedAt,
                completedAt = Instant.now().toString(),
            )
            InsightAnalysisResultJsonDecoder.decode(content, request, usage)
        }
    }

    private fun analysisSystemPrompt(request: InsightAnalysisRequest): String =
        """
        You are OpenBurnBar Insights. Analyze the user's AI usage digest and return one JSON object only.
        Explain what changed, why it matters, what caused it, what is wasteful, what is risky, and what the user should do next.
        Never include secrets, credentials, raw files, or full transcripts. Only cite evidence IDs present in evidenceIndex.
        Return keys: executiveSummary, findings, anomalies, recommendations, generatedWidgets, followUpQuestions, citations.
        Generated widgets must use known widget kinds and must include citations. Max generated widgets: ${request.maxGeneratedWidgets}.
        """.trimIndent()
}

private object InsightAnalysisResultJsonDecoder {
    fun decode(content: String, request: InsightAnalysisRequest, usage: InsightTokenUsage?): InsightAnalysisResult {
        val root = extractObject(content)
        val resolver = CitationResolver(request.context)
        val citations = root.optJSONArray("citations").toCitationRefs().map { resolver.resolve(it) }
        val findings = root.optJSONArray("findings").toObjects().map { obj ->
            InsightFinding(
                title = obj.optString("title", "Finding"),
                whyItMatters = obj.optString("whyItMatters", obj.optString("why_it_matters", "")),
                evidence = obj.optJSONArray("evidence").toCitationRefs().map { resolver.resolve(it) },
                confidence = confidence(obj.optString("confidence")),
                severity = severity(obj.optString("severity")),
                recommendedAction = obj.optString("recommendedAction", obj.optString("recommended_action", "Review the cited evidence."))
            )
        }
        val anomalies = root.optJSONArray("anomalies").toObjects().map { obj ->
            InsightAnomaly(
                title = obj.optString("title", "Anomaly"),
                occurredAt = obj.optString("occurredAt").takeIf { it.isNotBlank() },
                detail = obj.optString("detail", ""),
                score = obj.optDouble("score", 0.0),
                evidence = obj.optJSONArray("evidence").toCitationRefs().map { resolver.resolve(it) },
                confidence = confidence(obj.optString("confidence"))
            )
        }
        val recommendations = root.optJSONArray("recommendations").toObjects().map { obj ->
            InsightRecommendation(
                title = obj.optString("title", "Recommendation"),
                rationale = obj.optString("rationale", ""),
                recommendedAction = obj.optString("recommendedAction", obj.optString("recommended_action", "Review the cited evidence.")),
                estimatedImpact = obj.optString("estimatedImpact").takeIf { it.isNotBlank() },
                evidence = obj.optJSONArray("evidence").toCitationRefs().map { resolver.resolve(it) },
                confidence = confidence(obj.optString("confidence")),
                severity = severity(obj.optString("severity"))
            )
        }
        val widgets = root.optJSONArray("generatedWidgets").toObjects()
            .take(request.maxGeneratedWidgets)
            .map { obj ->
                generatedWidget(
                    kind = widgetKind(obj.optString("kind")),
                    title = obj.optString("title", "Generated widget"),
                    reason = obj.optString("reason", ""),
                    citations = obj.optJSONArray("citations").toCitationRefs().map { resolver.resolve(it) },
                    modelTag = request.selectedModel,
                    recommendation = recommendations.firstOrNull()
                )
            }
        val followUps = root.optJSONArray("followUpQuestions").toObjects().map { obj ->
            InsightFollowUpQuestion(
                question = obj.optString("question"),
                rationale = obj.optString("rationale").takeIf { it.isNotBlank() }
            )
        }
        val result = InsightAnalysisResult(
            requestID = request.id,
            platform = InsightAnalysisPlatform.ANDROID,
            timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d,
            executiveSummary = root.optString("executiveSummary", "Insights analysis completed."),
            modelTag = request.selectedModel,
            contextBudget = request.context.budgetReport,
            findings = findings,
            anomalies = anomalies,
            recommendations = recommendations,
            generatedWidgets = widgets,
            followUpQuestions = followUps,
            citations = if (citations.isEmpty()) request.context.evidenceIndex.map { it.citation } else citations,
            tokenUsage = usage,
            estimatedCostUSD = usage?.estimatedCostUSD,
        )
        return result.copy(resultHash = sha256(result.copy(resultHash = "").toString()))
    }

    private fun generatedWidget(
        kind: InsightWidgetKind,
        title: String,
        reason: String,
        citations: List<InsightCitation>,
        modelTag: InsightModelTag,
        recommendation: InsightRecommendation?,
    ): InsightGeneratedWidget {
        val (binding, data) = when (kind) {
            InsightWidgetKind.RECOMMENDATION -> {
                val value = InsightWidgetData.Recommendation(
                    headline = title,
                    rationale = reason,
                    action = recommendation?.recommendedAction ?: reason,
                    estimatedImpact = recommendation?.estimatedImpact,
                    citations = citations,
                )
                InsightDataBinding.Recommendation(value) to value
            }
            InsightWidgetKind.NARRATIVE -> {
                val value = InsightWidgetData.Narrative(
                    headline = title,
                    body = reason,
                    citations = citations,
                )
                InsightDataBinding.Narrative(value) to value
            }
            else -> defaultBinding(kind) to null
        }
        return InsightGeneratedWidget(
            widget = InsightWidget(
                kind = kind,
                title = title,
                spec = defaultSpec(kind),
                dataBinding = binding,
                data = data,
                freshness = com.openburnbar.data.insights.InsightFreshness.FRESH,
                modelTag = modelTag,
                lastComputedAt = Instant.now().toString(),
                rationale = reason,
            ),
            reason = reason,
            citations = citations,
        )
    }

    private fun extractObject(content: String): JSONObject {
        val trimmed = content.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        val start = trimmed.indexOf('{')
        val end = trimmed.lastIndexOf('}')
        require(start >= 0 && end >= start) { "Model response did not contain JSON." }
        return JSONObject(trimmed.substring(start, end + 1))
    }

    private data class CitationRef(val id: String?, val label: String)

    private fun JSONArray?.toObjects(): List<JSONObject> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { optJSONObject(it) }
    }

    private fun JSONArray?.toCitationRefs(): List<CitationRef> =
        toObjects().map {
            CitationRef(
                id = it.optString("id").takeIf { value -> value.isNotBlank() },
                label = it.optString("label", it.optString("id", "Evidence"))
            )
        }

    private class CitationResolver(context: InsightAnalysisContext) {
        private val byID = context.evidenceIndex.associateBy { it.id.lowercase() }
        private val byCitationID = context.evidenceIndex.associateBy { it.citation.id.lowercase() }
        private val byLabel = context.evidenceIndex.associateBy { it.citation.label.lowercase() }

        fun resolve(ref: CitationRef): InsightCitation {
            val id = ref.id?.lowercase()
            if (id != null) {
                byID[id]?.let { return it.citation }
                byCitationID[id]?.let { return it.citation }
            }
            byLabel[ref.label.lowercase()]?.let { return it.citation }
            return InsightCitation(
                id = ref.id ?: "query:${ref.label}",
                kind = InsightCitation.Kind.Query(ref.id ?: ref.label),
                label = ref.label
            )
        }
    }

    private fun confidence(raw: String): InsightConfidence =
        when (raw.lowercase()) {
            "high" -> InsightConfidence.HIGH
            "low" -> InsightConfidence.LOW
            else -> InsightConfidence.MEDIUM
        }

    private fun severity(raw: String): InsightSeverity =
        when (raw.lowercase()) {
            "critical" -> InsightSeverity.CRITICAL
            "high" -> InsightSeverity.HIGH
            "low" -> InsightSeverity.LOW
            "info" -> InsightSeverity.INFO
            else -> InsightSeverity.MEDIUM
        }

    private fun widgetKind(raw: String): InsightWidgetKind =
        when (raw) {
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

    private fun defaultBinding(kind: InsightWidgetKind): InsightDataBinding =
        when (kind) {
            InsightWidgetKind.BAR_RANKING -> InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.MODEL, 8, InsightTimeWindow.Last7d)
            InsightWidgetKind.TIME_SERIES_LINE, InsightWidgetKind.TIME_SERIES_AREA, InsightWidgetKind.STREAM_GRAPH ->
                InsightDataBinding.TimeSeries("cost", InsightWidgetSpec.Dimension.PROVIDER, InsightTimeWindow.Last7d)
            InsightWidgetKind.QUOTA_PULSE -> InsightDataBinding.Quota(null)
            InsightWidgetKind.ANOMALY_TABLE -> InsightDataBinding.Anomaly(InsightTimeWindow.Last7d)
            else -> InsightDataBinding.Narrative(InsightWidgetData.Narrative(titleFor(kind), "Generated by the selected Insights model."))
        }

    private fun defaultSpec(kind: InsightWidgetKind): InsightWidgetSpec =
        when (kind) {
            InsightWidgetKind.BAR_RANKING -> InsightWidgetSpec.Ranking(InsightWidgetSpec.RankingSpec())
            InsightWidgetKind.TIME_SERIES_LINE -> InsightWidgetSpec.TimeSeries(InsightWidgetSpec.TimeSeriesSpec())
            InsightWidgetKind.TIME_SERIES_AREA -> InsightWidgetSpec.TimeSeries(InsightWidgetSpec.TimeSeriesSpec(style = InsightWidgetSpec.TimeSeriesSpec.Style.AREA))
            InsightWidgetKind.QUOTA_PULSE -> InsightWidgetSpec.QuotaPulse(InsightWidgetSpec.QuotaPulseSpec())
            InsightWidgetKind.ANOMALY_TABLE -> InsightWidgetSpec.AnomalyTable(InsightWidgetSpec.AnomalyTableSpec())
            InsightWidgetKind.RECOMMENDATION -> InsightWidgetSpec.Recommendation(InsightWidgetSpec.RecommendationSpec())
            else -> InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec())
        }

    private fun titleFor(kind: InsightWidgetKind): String = kind.displayName

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}

class RuleBasedInsightAnalysisEngine(
    private val platform: InsightAnalysisPlatform
) : InsightAnalysisEngine {
    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult {
        val result = buildResult(request, platform)
        return result.copy(resultHash = sha256(result.copy(resultHash = "").toString()))
    }

    companion object {
        fun materializeCanvas(result: InsightAnalysisResult, prompt: String): InsightCanvas {
            var canvas = InsightCanvas(
                title = "Intelligence Brief",
                summary = result.executiveSummary,
                symbolName = "sparkles.tv",
                theme = InsightTheme.AURORA,
                widgets = emptyList(),
                filter = com.openburnbar.data.insights.InsightFilter(window = result.timeWindow),
                modelTag = result.modelTag,
                origin = com.openburnbar.data.insights.InsightCanvas.Origin.Composed(prompt)
            )
            result.generatedWidgets.forEach { generated ->
                canvas = canvas.add(generated.widget.copy(modelTag = result.modelTag))
            }
            return canvas
        }

        private fun buildResult(
            request: InsightAnalysisRequest,
            platform: InsightAnalysisPlatform
        ): InsightAnalysisResult {
            val digest = request.context.digest
            val topProvider = digest.providers.maxByOrNull { it.costUSD }
            val topModel = digest.models.maxByOrNull { it.costUSD }
            val citations = request.context.evidenceIndex.map { it.citation }
                .ifEmpty { listOf(InsightCitation("empty-context", InsightCitation.Kind.Query("empty-insight-context"), "No synced activity")) }
            val headline = if (digest.totals.sessionCount > 0) {
                "${currency(digest.totals.costUSD)} analyzed across ${digest.totals.sessionCount} sessions"
            } else {
                "No synced activity in this window"
            }
            val body = if (digest.totals.sessionCount > 0) {
                "The main thing to inspect is whether ${topProvider?.displayName ?: "your top provider"} is doing the right work for its cost profile."
            } else {
                "Insights has no usable rows for this window yet. Refresh sync or choose a broader window."
            }
            val narrative = InsightWidgetData.Narrative(
                headline = headline,
                body = body,
                bullets = listOf(
                    "${digest.totals.sessionCount} sessions and ${digest.totals.totalTokens} tokens.",
                    "${topProvider?.displayName ?: "No provider"} led provider spend."
                ),
                citations = citations.take(3),
                sparkline = digest.daily.map { it.costUSD }
            )
            val narrativeWidget = generatedWidget(
                kind = InsightWidgetKind.NARRATIVE,
                title = "What changed",
                dataBinding = InsightDataBinding.Narrative(narrative),
                data = narrative,
                reason = "Default brief lead finding.",
                modelTag = request.selectedModel,
                citations = citations.take(3)
            )
            val widgets = mutableListOf(narrativeWidget)
            val findings = mutableListOf(
                InsightFinding(
                    title = headline,
                    whyItMatters = body,
                    evidence = citations.take(3),
                    confidence = if (digest.totals.sessionCount > 0) InsightConfidence.HIGH else InsightConfidence.LOW,
                    severity = InsightSeverity.MEDIUM,
                    recommendedAction = if (digest.totals.sessionCount > 0) {
                        "Open the generated provider ranking and compare the top model against cheaper configured routes."
                    } else {
                        "Refresh data or switch the window to 30 days."
                    },
                    generatedWidgetID = narrativeWidget.widget.id
                )
            )
            if (topProvider != null) {
                val providerCitation = InsightCitation("provider:${topProvider.id}", InsightCitation.Kind.Agent(topProvider.id), topProvider.displayName)
                val ranking = generatedWidget(
                    kind = InsightWidgetKind.BAR_RANKING,
                    title = "Provider spend ranking",
                    dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.PROVIDER, 5, request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d),
                    data = null,
                    reason = "Shows the provider driving the main cost signal.",
                    modelTag = request.selectedModel,
                    citations = listOf(providerCitation)
                )
                widgets.add(ranking)
                findings.add(
                    InsightFinding(
                        title = "${topProvider.displayName} is the main spend driver",
                        whyItMatters = "${topProvider.displayName} accounts for ${currency(topProvider.costUSD)} across ${topProvider.sessionCount} sessions.",
                        evidence = listOf(providerCitation),
                        confidence = InsightConfidence.HIGH,
                        severity = InsightSeverity.MEDIUM,
                        recommendedAction = "Compare ${topProvider.displayName}'s top models against lower-cost routes before the next heavy session.",
                        generatedWidgetID = ranking.widget.id
                    )
                )
            }
            widgets.add(
                generatedWidget(
                    kind = InsightWidgetKind.TIME_SERIES_LINE,
                    title = "Main supporting trend",
                    dataBinding = InsightDataBinding.TimeSeries("cost", InsightWidgetSpec.Dimension.PROVIDER, request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d),
                    data = null,
                    reason = "Shows whether the main finding is a spike or a sustained trend.",
                    modelTag = request.selectedModel,
                    citations = citations.take(3)
                )
            )
            val recommendations = topModel?.let {
                listOf(
                    InsightRecommendation(
                        title = "Check whether ${it.id} is the right default",
                        rationale = "${it.id} is the largest model cost contributor in this window.",
                        recommendedAction = "Compare this model against the current Hermes/router default for routine work.",
                        estimatedImpact = "Can reduce cost if high-capability models are handling low-risk tasks.",
                        evidence = listOf(InsightCitation("model:${it.id}", InsightCitation.Kind.Model(it.id), it.id)),
                        confidence = InsightConfidence.MEDIUM,
                        severity = InsightSeverity.MEDIUM
                    )
                )
            } ?: emptyList()
            return InsightAnalysisResult(
                requestID = request.id,
                platform = platform,
                timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d,
                executiveSummary = body,
                modelTag = request.selectedModel,
                contextBudget = request.context.budgetReport,
                findings = findings.take(3),
                recommendations = recommendations,
                generatedWidgets = widgets.take(request.maxGeneratedWidgets),
                followUpQuestions = listOf(
                    "Why did cost spike this week?",
                    "Which project wasted the most money?",
                    "Which model should I route routine work to instead?",
                    "Find quota risks in the next 24 hours."
                ).map { InsightFollowUpQuestion(question = it) },
                citations = citations
            )
        }

        private fun generatedWidget(
            kind: InsightWidgetKind,
            title: String,
            dataBinding: InsightDataBinding,
            data: InsightWidgetData?,
            reason: String,
            modelTag: InsightModelTag,
            citations: List<InsightCitation>
        ): InsightGeneratedWidget {
            val spec = when (kind) {
                InsightWidgetKind.NARRATIVE -> InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec())
                InsightWidgetKind.BAR_RANKING -> InsightWidgetSpec.Ranking(InsightWidgetSpec.RankingSpec())
                InsightWidgetKind.TIME_SERIES_LINE -> InsightWidgetSpec.TimeSeries(InsightWidgetSpec.TimeSeriesSpec())
                else -> InsightWidgetSpec.Narrative(InsightWidgetSpec.NarrativeSpec())
            }
            return InsightGeneratedWidget(
                widget = InsightWidget(
                    kind = kind,
                    title = title,
                    spec = spec,
                    dataBinding = dataBinding,
                    data = data,
                    freshness = com.openburnbar.data.insights.InsightFreshness.FRESH,
                    modelTag = modelTag,
                    rationale = reason
                ),
                reason = reason,
                citations = citations
            )
        }

        private fun currency(value: Double): String = "$" + String.format("%.2f", value)

        private fun sha256(value: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}

object InsightAggregator {
    fun buildContext(
        digest: InsightDigest,
        includedDataSources: List<String>,
        priorRunSummaries: List<String> = emptyList(),
        evidencePacks: List<com.openburnbar.data.insights.InsightEvidencePack> = emptyList()
    ): InsightAnalysisContext {
        val encoded = kotlinx.serialization.json.Json.encodeToString(InsightDigest.serializer(), digest)
        val evidence = buildEvidenceIndex(digest) + evidencePacks.flatMap { it.evidence }
        val sources = (includedDataSources + evidencePacks.flatMap { it.includedDataSources }).distinct().sorted()
        val truncated = buildList {
            if (digest.providers.size >= 12 && "provider_summaries" in includedDataSources) add("provider_summaries")
            if (digest.models.size >= 16 && "model_summaries" in includedDataSources) add("model_summaries")
            if (digest.daily.size >= 90 && "daily_points" in includedDataSources) add("daily_points")
        }
        val budget = InsightContextBudgetReport(
            encodedBytes = encoded.toByteArray(Charsets.UTF_8).size,
            estimatedPromptTokens = (encoded.length / 4).coerceAtLeast(1),
            includedDataSources = sources,
            truncatedDataSources = truncated,
            truncationSummary = if (truncated.isEmpty()) "No truncation." else "Context was budgeted to ${InsightDigest.MAX_ENCODED_BYTES} bytes; long-tail ${truncated.joinToString()} data was summarized."
        )
        return InsightAnalysisContext(
            digest = digest,
            evidenceIndex = evidence,
            budgetReport = budget,
            priorRunSummaries = priorRunSummaries,
            evidencePacks = evidencePacks
        )
    }

    private fun buildEvidenceIndex(digest: InsightDigest): List<InsightEvidence> {
        val out = mutableListOf<InsightEvidence>()
        digest.providers.take(8).forEach { provider ->
            val citation = InsightCitation("provider:${provider.id}", InsightCitation.Kind.Agent(provider.id), provider.displayName)
            out.add(InsightEvidence("provider:${provider.id}", citation, "provider_summaries", "${provider.displayName}: ${provider.sessionCount} sessions, ${provider.totalTokens} tokens.", provider.costUSD))
        }
        digest.models.take(8).forEach { model ->
            val citation = InsightCitation("model:${model.id}", InsightCitation.Kind.Model(model.id), model.id)
            out.add(InsightEvidence("model:${model.id}", citation, "model_summaries", "${model.id}: ${model.sessionCount} sessions, ${model.totalTokens} tokens.", model.costUSD))
        }
        digest.quotaSnapshots.take(8).forEach { quota ->
            val citation = InsightCitation("quota:${quota.id}", InsightCitation.Kind.Quota(quota.providerID, quota.bucketName), "${quota.providerID} ${quota.bucketName}")
            out.add(InsightEvidence("quota:${quota.id}", citation, "quota_snapshots", "${quota.providerID} ${quota.bucketName}: ${quota.used} used.", quota.limit?.let { if (it > 0) quota.used / it else 0.0 }))
        }
        return out
    }
}
