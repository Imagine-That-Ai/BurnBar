package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisContext
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightDataBinding
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightEvidence
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightMissionCandidate
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
import com.openburnbar.data.insights.ValueFormat
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
import java.util.concurrent.TimeUnit

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
        cache?.lookup(cacheKey)?.let { cached ->
            val result = ensureBriefingAnswer(
                RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
                result = cached.result,
                request = request,
                platform = InsightAnalysisPlatform.ANDROID
                ),
                request
            )
            if (result != cached.result) {
                cache.store(InsightAnalysisCacheRepository.cachedNow(cacheKey, result, cached.estimatedCostSavedUSD))
            }
            return result
        }

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
            val result = RuleBasedInsightAnalysisEngine.enrichMissionCandidates(
                result = raw,
                request = request,
                platform = InsightAnalysisPlatform.ANDROID
            ).copy(auditID = auditID)
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
            // Cache key is computed from the user's *selected* model.
            // Two reasons we may decline to cache:
            //   1. The orchestrator redirected this run through the
            //      BurnBar hosted fallback (or another route) when
            //      the selected gateway was unreachable — caching
            //      under the user's selection would serve the
            //      fallback after their own route recovers.
            //   2. The answering route IS the hosted route. Caching
            //      that result would let a once-Pro-now-cancelled
            //      caller keep getting hosted answers for the same
            //      question after their subscription lapsed. Pro is
            //      a live entitlement; we re-verify on every turn.
            val answeringRouteMatchesSelection =
                result.modelTag.providerKey == request.selectedModel.providerKey
                    && result.modelTag.modelID == request.selectedModel.modelID
            val isHostedRoute =
                result.modelTag.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY
            if (answeringRouteMatchesSelection && !isHostedRoute) {
                cache?.store(InsightAnalysisCacheRepository.cachedNow(cacheKey, result))
            }
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
            ?: return tryHostedThenLocalFallback(
                request,
                "No Android Insights gateway is configured for ${request.selectedModel.providerKey}.",
            )
        return try {
            val result = gateway.analyze(request)
            if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP && result.briefingAnswer == null) {
                val answerSource = if (
                    result.modelTag.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY
                ) {
                    InsightBriefingAnswer.Source.HOSTED_FALLBACK
                } else {
                    InsightBriefingAnswer.Source.MODEL_GATEWAY
                }
                result.copy(
                    briefingAnswer = InsightBriefingAnswer(
                        question = request.prompt,
                        answer = composeAnswerBody(result),
                        bullets = composeGroundedPoints(result),
                        citations = result.citations.take(3),
                        source = answerSource,
                        modelDisplayName = result.modelTag.displayName
                    )
                )
            } else {
                result
            }
        } catch (paywall: BurnBarProSubscriptionRequiredException) {
            // The selected gateway IS the hosted route and it threw
            // the Pro paywall (typically when the user explicitly
            // picked `burnbar-hosted` without a subscription).
            // Short-circuit to the upgrade disclosure instead of
            // re-invoking the same hosted gateway through
            // `tryHostedThenLocalFallback` — that second call would
            // 403 again and double the server-side rejection cost.
            if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) {
                composeSubscriptionRequiredFallback(request)
            } else {
                throw paywall
            }
        } catch (t: Throwable) {
            tryHostedThenLocalFallback(request, t.message ?: t.javaClass.simpleName)
        }
    }

    /**
     * After a user-owned gateway fails or is missing, try the
     * BurnBar-hosted fallback before degrading to local rules so the
     * user still gets an LLM answer when their own route is down.
     * Privacy mode short-circuits past the hosted attempt.
     */
    private suspend fun tryHostedThenLocalFallback(
        request: InsightAnalysisRequest,
        reason: String,
    ): InsightAnalysisResult {
        if (request.instruction != InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) {
            error(reason)
        }
        if (!restrictToLocalOnly) {
            val hosted = gateways[AndroidBurnBarHostedInsightGateway.PROVIDER_KEY]
            if (hosted != null) {
                try {
                    val hostedTag = hosted.models.first()
                    val hostedResult = hosted.analyze(request.copy(selectedModel = hostedTag))
                    val existing = hostedResult.briefingAnswer
                    return hostedResult.copy(
                        briefingAnswer = (existing ?: InsightBriefingAnswer(
                            question = request.prompt,
                            answer = composeAnswerBody(hostedResult),
                            bullets = composeGroundedPoints(hostedResult),
                            citations = hostedResult.citations.take(3),
                            source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                            modelDisplayName = hostedResult.modelTag.displayName,
                            isFallback = false,
                        )).copy(
                            source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                            isFallback = false,
                        )
                    )
                } catch (paywall: BurnBarProSubscriptionRequiredException) {
                    // Free-tier / anonymous caller hit the hosted
                    // paywall. Surface the dedicated "BurnBar Pro
                    // required" disclosure so the UI switches the CTA
                    // to "Upgrade to BurnBar Pro".
                    return composeSubscriptionRequiredFallback(request)
                } catch (_: Throwable) {
                    // Fall through to local rules — disclosed below.
                }
            }
        }
        val fallbackResult = fallback.analyze(request)
        val answer = fallbackResult.briefingAnswer ?: return fallbackResult
        return fallbackResult.copy(
            briefingAnswer = answer.copy(
                isFallback = true,
                modelDisplayName = "${request.selectedModel.displayName} → Local rules"
            )
        )
    }

    private suspend fun composeSubscriptionRequiredFallback(
        request: InsightAnalysisRequest
    ): InsightAnalysisResult {
        val base = fallback.analyze(request)
        val existing = base.briefingAnswer ?: return base
        return base.copy(
            briefingAnswer = existing.copy(
                isFallback = true,
                modelDisplayName = InsightBriefingAnswer.SUBSCRIPTION_REQUIRED_DISPLAY_NAME,
                answer = buildString {
                    appendLine("BurnBar Pro subscription required to run hosted Intelligence Brief answers. Connect your own LLM (Hermes, Claude, OpenAI, Ollama, Pi, etc.) or upgrade to BurnBar Pro to use our hosted MiniMax route.")
                    appendLine()
                    append(existing.answer)
                }.trim()
            )
        )
    }

    private suspend fun ensureBriefingAnswer(
        result: InsightAnalysisResult,
        request: InsightAnalysisRequest
    ): InsightAnalysisResult {
        if (request.instruction != InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP || result.briefingAnswer != null) {
            return result
        }
        if (result.modelTag.providerKey == "local-rules") {
            return result.copy(briefingAnswer = fallback.analyze(request).briefingAnswer)
        }
        // Attribute the cached briefing to the *actual* route that
        // produced the result, not blanket MODEL_GATEWAY. Pre-hosted
        // cache rows stamped by the BurnBar hosted gateway must show
        // up in the UI eyebrow and audit log as HOSTED_FALLBACK.
        val answerSource = if (
            result.modelTag.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY
        ) {
            InsightBriefingAnswer.Source.HOSTED_FALLBACK
        } else {
            InsightBriefingAnswer.Source.MODEL_GATEWAY
        }
        return result.copy(
            briefingAnswer = InsightBriefingAnswer(
                question = request.prompt,
                answer = composeAnswerBody(result),
                bullets = composeGroundedPoints(result),
                citations = result.citations.take(3),
                source = answerSource,
                modelDisplayName = result.modelTag.displayName
            )
        )
    }

    @Suppress("unused")
    @Deprecated(
        "Kept as a deprecated symbol for source compatibility with older test bundles. " +
            "Production callers should route through tryHostedThenLocalFallback to give the " +
            "BurnBar-hosted route a chance before degrading."
    )
    private suspend fun fallbackForQuestionOrThrow(request: InsightAnalysisRequest, reason: String): InsightAnalysisResult =
        tryHostedThenLocalFallback(request, reason)

    private fun composeAnswerBody(result: InsightAnalysisResult): String =
        buildList {
            if (result.executiveSummary.isNotBlank()) add(result.executiveSummary)
            result.findings.firstOrNull()?.let {
                if (!result.executiveSummary.lowercase().contains(it.title.lowercase())) add(it.whyItMatters)
                add(it.recommendedAction)
            }
        }.joinToString(" ")

    private fun composeGroundedPoints(result: InsightAnalysisResult): List<String> =
        (result.findings.take(3).map { it.title } +
            result.anomalies.take(2).map { "Spike: ${it.title}" } +
            result.recommendations.take(2).map { "Action: ${it.title}" }).take(4)
}

class OllamaInsightAnalysisGateway(
    private val baseURL: String = "http://127.0.0.1:11434",
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .build(),
    private val numPredict: Int = 1400,
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
            put("think", false)
            put("options", JSONObject().apply {
                put("temperature", 0.2)
                put("num_predict", numPredict)
            })
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
        When model benchmark evidence exists, compare observed model usage against score/rank, cost signal, latency, task category, freshness, and attribution.
        Never invent benchmark ranks, prices, or dollar savings. If exact prices are absent, say cost signal rather than savings.
        For UI/design work, separate design/coding benchmark fit from general reasoning fit.
        Treat Android, iOS, iPadOS, and macOS Insights as mission-control remotes for the user's local Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex agents.
        When a user asks for a mission, produce dispatch-ready work: recommended agent, target project, evidence to inspect, acceptance criteria, validation commands, risks, and what mobile should show when complete.
        Return missionCandidates separately from findings and recommendations. Missions must be concrete work packages, not duplicate insight prose.
        Use accretion, diligence, techDebt, routing, quota, and focus lenses to propose greater-purpose missions from the evidence.
        Recommend adjacent security, UI improvement, modernization, and cost-efficiency missions when the digest or benchmark evidence supports them.
        Return keys: executiveSummary, findings, anomalies, recommendations, missionCandidates, generatedWidgets, followUpQuestions, citations.
        Generated widgets must use known widget kinds and must include citations. Max generated widgets: ${request.maxGeneratedWidgets}.
        """.trimIndent()
}

object InsightAnalysisResultJsonDecoder {
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
        val missions = root.optJSONArray("missionCandidates").toObjects().map { obj ->
            InsightMissionCandidate(
                title = obj.optString("title", "Mission"),
                summary = obj.optString("summary", ""),
                projectID = obj.optString("projectID").takeIf { it.isNotBlank() },
                projectDisplayName = obj.optString("projectDisplayName").takeIf { it.isNotBlank() },
                lens = missionLens(obj.optString("lens")),
                priority = missionPriority(obj.optString("priority")),
                confidence = confidence(obj.optString("confidence")),
                expectedImpact = obj.optString("expectedImpact", obj.optString("expected_impact", "")),
                effort = missionEffort(obj.optString("effort")),
                acceptanceCriteria = obj.optJSONArray("acceptanceCriteria").toStrings()
                    .ifEmpty { obj.optJSONArray("acceptance_criteria").toStrings() },
                sourceInsightIDs = obj.optJSONArray("sourceInsightIDs").toStrings()
                    .ifEmpty { obj.optJSONArray("source_insight_ids").toStrings() },
                evidence = obj.optJSONArray("evidence").toCitationRefs().map { resolver.resolve(it) },
                dispatchMetadata = obj.optJSONObject("dispatchMetadata").toStringMap()
                    .ifEmpty { obj.optJSONObject("dispatch_metadata").toStringMap() }
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
            missionCandidates = missions,
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

    private fun JSONArray?.toStrings(): List<String> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { optString(it).takeIf { value -> value.isNotBlank() } }
    }

    private fun JSONObject?.toStringMap(): Map<String, String> {
        if (this == null) return emptyMap()
        return keys().asSequence().mapNotNull { key ->
            optString(key).takeIf { it.isNotBlank() }?.let { key to it }
        }.toMap()
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

    private fun missionLens(raw: String): InsightMissionCandidate.Lens =
        when (raw.replace("_", "").replace("-", "").lowercase()) {
            "accretion" -> InsightMissionCandidate.Lens.ACCRETION
            "diligence" -> InsightMissionCandidate.Lens.DILIGENCE
            "techdebt" -> InsightMissionCandidate.Lens.TECH_DEBT
            "routing" -> InsightMissionCandidate.Lens.ROUTING
            "quota" -> InsightMissionCandidate.Lens.QUOTA
            "focus" -> InsightMissionCandidate.Lens.FOCUS
            else -> InsightMissionCandidate.Lens.FOCUS
        }

    private fun missionPriority(raw: String): InsightMissionCandidate.Priority =
        when (raw.lowercase()) {
            "critical" -> InsightMissionCandidate.Priority.CRITICAL
            "high" -> InsightMissionCandidate.Priority.HIGH
            "low" -> InsightMissionCandidate.Priority.LOW
            else -> InsightMissionCandidate.Priority.MEDIUM
        }

    private fun missionEffort(raw: String): InsightMissionCandidate.Effort =
        when (raw.lowercase()) {
            "large" -> InsightMissionCandidate.Effort.LARGE
            "small" -> InsightMissionCandidate.Effort.SMALL
            else -> InsightMissionCandidate.Effort.MEDIUM
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

        fun enrichMissionCandidates(
            result: InsightAnalysisResult,
            request: InsightAnalysisRequest,
            platform: InsightAnalysisPlatform
        ): InsightAnalysisResult {
            if (result.missionCandidates.isNotEmpty()) return result
            val baseline = buildResult(request, platform)
            if (baseline.missionCandidates.isEmpty()) return result
            val enriched = result.copy(missionCandidates = baseline.missionCandidates, resultHash = "")
            return enriched.copy(resultHash = sha256(enriched.toString()))
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
            if (topProvider != null && digest.providers.isNotEmpty()) {
                val providerCitation = InsightCitation("provider:${topProvider.id}", InsightCitation.Kind.Agent(topProvider.id), topProvider.displayName)
                // Real ranking rows from the digest — top providers by cost.
                val rankingRows = digest.providers
                    .sortedByDescending { it.costUSD }
                    .take(5)
                    .map { p ->
                        InsightWidgetData.Ranking.Row(
                            id = "p:${p.id}",
                            label = p.displayName,
                            value = p.costUSD,
                            secondaryLabel = "${p.sessionCount} sessions",
                        )
                    }
                val rankingData = InsightWidgetData.Ranking(
                    rows = rankingRows,
                    valueFormat = ValueFormat.CURRENCY,
                    dimensionLabel = "Provider",
                )
                val ranking = generatedWidget(
                    kind = InsightWidgetKind.BAR_RANKING,
                    title = "Provider spend ranking",
                    dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.PROVIDER, 5, request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d),
                    data = rankingData,
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
            // Time series — real cost-per-day points from the digest.
            if (digest.daily.isNotEmpty()) {
                val tsData = InsightWidgetData.TimeSeries(
                    series = listOf(
                        InsightWidgetData.TimeSeries.Series(
                            id = "cost",
                            name = "Daily cost",
                            points = digest.daily.map {
                                InsightWidgetData.TimeSeries.Point(date = it.day, value = it.costUSD)
                            },
                        )
                    ),
                    xAxisLabel = "Date",
                    yAxisLabel = "Cost (USD)",
                    yFormat = ValueFormat.CURRENCY,
                )
                widgets.add(
                    generatedWidget(
                        kind = InsightWidgetKind.TIME_SERIES_LINE,
                        title = "Cost trend",
                        dataBinding = InsightDataBinding.TimeSeries("cost", InsightWidgetSpec.Dimension.PROVIDER, request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d),
                        data = tsData,
                        reason = "Shows whether the main finding is a spike or a sustained trend.",
                        modelTag = request.selectedModel,
                        citations = citations.take(3)
                    )
                )
            }
            // Donut — provider mix by cost share. Only when ≥2 providers, otherwise the donut degenerates.
            if (digest.providers.size >= 2) {
                val total = digest.providers.sumOf { it.costUSD }
                val slices = digest.providers
                    .sortedByDescending { it.costUSD }
                    .map {
                        InsightWidgetData.Distribution.Slice(
                            id = "slice:${it.id}",
                            label = it.displayName,
                            value = it.costUSD,
                        )
                    }
                widgets.add(
                    generatedWidget(
                        kind = InsightWidgetKind.DONUT,
                        title = "Provider cost share",
                        dataBinding = InsightDataBinding.Distribution("cost", InsightWidgetSpec.Dimension.PROVIDER, request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d),
                        data = InsightWidgetData.Distribution(
                            slices = slices,
                            valueFormat = ValueFormat.CURRENCY,
                            total = total,
                        ),
                        reason = "How spend splits across the providers in this window.",
                        modelTag = request.selectedModel,
                        citations = citations.take(3)
                    )
                )
            }
            // Top models bar — only when models present and distinct from the provider ranking above.
            if (digest.models.isNotEmpty()) {
                val modelRows = digest.models
                    .sortedByDescending { it.costUSD }
                    .take(5)
                    .map {
                        InsightWidgetData.Ranking.Row(
                            id = "m:${it.id}",
                            label = it.id,
                            value = it.costUSD,
                            secondaryLabel = "${it.sessionCount} sessions",
                        )
                    }
                widgets.add(
                    generatedWidget(
                        kind = InsightWidgetKind.BAR_RANKING,
                        title = "Top models by cost",
                        dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.MODEL, 5, request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d),
                        data = InsightWidgetData.Ranking(
                            rows = modelRows,
                            valueFormat = ValueFormat.CURRENCY,
                            dimensionLabel = "Model",
                        ),
                        reason = "Which models cost you the most in this window.",
                        modelTag = request.selectedModel,
                        citations = citations.take(3)
                    )
                )
            }
            val recommendations = topModel?.let {
                mutableListOf(
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
            } ?: mutableListOf()
            val benchmarkAdvice = modelBenchmarkAdvice(
                digest = digest,
                topModel = topModel,
                selectedModel = request.selectedModel,
                window = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d
            )
            findings.addAll(benchmarkAdvice.findings)
            recommendations.addAll(benchmarkAdvice.recommendations)
            widgets.addAll(benchmarkAdvice.widgets)
            val missionAdvice = missionIntelligence(
                digest = digest,
                topProvider = topProvider,
                topModel = topModel,
                sourceInsightIDs = findings.map { it.id }
            )
            findings.addAll(missionAdvice.findings)
            recommendations.addAll(missionAdvice.recommendations)
            val briefingAnswer = if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) {
                InsightBriefingAnswer(
                    question = request.prompt,
                    answer = "$headline. $body ${findings.firstOrNull()?.recommendedAction ?: "Review the cited evidence and choose the next action from the brief."}",
                    bullets = groundedPointsForReply(digest, topProvider, topModel),
                    citations = citations.take(3),
                    source = InsightBriefingAnswer.Source.LOCAL_RULES,
                    modelDisplayName = request.selectedModel.displayName
                )
            } else {
                null
            }
            return InsightAnalysisResult(
                requestID = request.id,
                platform = platform,
                timeWindow = request.currentCanvas?.filter?.window ?: InsightTimeWindow.Last7d,
                executiveSummary = body,
                modelTag = request.selectedModel,
                contextBudget = request.context.budgetReport,
                findings = findings.take(6),
                recommendations = recommendations,
                missionCandidates = missionAdvice.missions.take(5),
                generatedWidgets = widgets.take(request.maxGeneratedWidgets),
                followUpQuestions = listOf(
                    "Why did cost spike this week?",
                    "Which project wasted the most money?",
                    "Which model should I route routine work to instead?",
                    "Which benchmarked model is cheapest at similar performance?",
                    "Which model should handle UI and design tasks?",
                    "Find quota risks in the next 24 hours."
                ).map { InsightFollowUpQuestion(question = it) },
                citations = citations,
                briefingAnswer = briefingAnswer
            )
        }

        private fun groundedPointsForReply(
            digest: InsightDigest,
            topProvider: InsightDigest.ProviderSnapshot?,
            topModel: InsightDigest.ModelSnapshot?
        ): List<String> {
            val points = mutableListOf<String>()
            topProvider?.let { points.add("${it.displayName}: ${currency(it.costUSD)} · ${it.sessionCount} sessions") }
            topModel?.let { points.add("Top model: ${it.id} · ${currency(it.costUSD)}") }
            if (digest.daily.isNotEmpty()) {
                digest.daily.maxByOrNull { it.costUSD }?.let { points.add("Peak day ${it.day.take(10)} at ${currency(it.costUSD)}") }
            }
            if (points.isEmpty()) points.add("${digest.totals.sessionCount} sessions · ${currency(digest.totals.costUSD)} total")
            return points.take(4)
        }

        private data class MissionAdvice(
            val findings: List<InsightFinding>,
            val recommendations: List<InsightRecommendation>,
            val missions: List<InsightMissionCandidate>
        )

        private fun missionIntelligence(
            digest: InsightDigest,
            topProvider: InsightDigest.ProviderSnapshot?,
            topModel: InsightDigest.ModelSnapshot?,
            sourceInsightIDs: List<String>
        ): MissionAdvice {
            if (digest.totals.sessionCount <= 0 && digest.rowCount <= 0) {
                return MissionAdvice(emptyList(), emptyList(), emptyList())
            }
            val topProject = digest.projects.maxByOrNull { it.costUSD }
            val projectName = topProject?.displayName ?: "the busiest project"
            val projectCost = currency(topProject?.costUSD ?: digest.totals.costUSD)
            val projectSessions = topProject?.sessionCount ?: digest.totals.sessionCount
            val projectCitation = topProject?.let {
                InsightCitation("project:${it.id}", InsightCitation.Kind.Project(it.id), it.displayName)
            }
            val providerCitation = topProvider?.let {
                InsightCitation("provider:${it.id}", InsightCitation.Kind.Agent(it.id), it.displayName)
            }
            val modelCitation = topModel?.let {
                InsightCitation("model:${it.id}", InsightCitation.Kind.Model(it.id), it.id)
            }
            val quotaRisk = digest.quotaSnapshots
                .filter { (it.limit ?: 0.0) > 0.0 }
                .maxByOrNull { it.used / maxOf(it.limit ?: 1.0, 1.0) }
            val quotaCitation = quotaRisk?.let {
                InsightCitation("quota:${it.providerID}:${it.bucketName}", InsightCitation.Kind.Quota(it.providerID, it.bucketName), "${it.providerID} quota")
            }
            val activityCitation = InsightCitation(
                "query:${digest.contentHash.ifBlank { "insight-activity" }}",
                InsightCitation.Kind.Query("insight-activity"),
                "Activity digest"
            )

            val findings = mutableListOf<InsightFinding>()
            if (topProject != null && projectCitation != null) {
                findings.add(
                    InsightFinding(
                        title = "${topProject.displayName} is where the work concentrated",
                        whyItMatters = "${topProject.displayName} accounts for $projectCost across $projectSessions sessions, so missions should start where repeated AI effort is already compounding.",
                        evidence = listOf(projectCitation),
                        confidence = InsightConfidence.HIGH,
                        severity = if (projectSessions >= 3) InsightSeverity.MEDIUM else InsightSeverity.LOW,
                        recommendedAction = "Create one focused mission for ${topProject.displayName} instead of treating the brief as isolated observations."
                    )
                )
            }

            val missions = mutableListOf<InsightMissionCandidate>()
            val accretionEvidence = nonEmptyEvidence(listOf(projectCitation, modelCitation, providerCitation), activityCitation)
            if (accretionEvidence.isNotEmpty()) {
                missions.add(
                    InsightMissionCandidate(
                        title = "Turn repeated $projectName work into an accretive feature",
                        summary = "Use the accretion lens to convert the highest-activity project into a small product or workflow improvement that reuses existing primitives instead of becoming a one-off analysis.",
                        projectID = topProject?.id,
                        projectDisplayName = topProject?.displayName,
                        lens = InsightMissionCandidate.Lens.ACCRETION,
                        priority = if (projectSessions >= 3) InsightMissionCandidate.Priority.HIGH else InsightMissionCandidate.Priority.MEDIUM,
                        confidence = if (topProject == null) InsightConfidence.MEDIUM else InsightConfidence.HIGH,
                        expectedImpact = "Compounds current AI spend into a durable workflow, trust cue, or UI affordance.",
                        effort = InsightMissionCandidate.Effort.MEDIUM,
                        acceptanceCriteria = listOf(
                            "Name the concrete user job currently driving the repeated sessions.",
                            "Ship one native workflow or polish layer that reuses existing BurnBar primitives.",
                            "Verify the next brief can cite reduced friction, clearer routing, or better user confidence."
                        ),
                        sourceInsightIDs = sourceInsightIDs,
                        evidence = accretionEvidence,
                        dispatchMetadata = mapOf("lens" to "accretion", "source" to "insight_engine")
                    )
                )
            }

            val diligenceEvidence = nonEmptyEvidence(listOf(projectCitation, quotaCitation, providerCitation), activityCitation)
            if (diligenceEvidence.isNotEmpty()) {
                val quotaHot = quotaRisk?.let { (it.limit ?: 0.0) > 0.0 && it.used / (it.limit ?: 1.0) >= 0.8 } ?: false
                missions.add(
                    InsightMissionCandidate(
                        title = if (quotaHot) "Run a diligence pass before the next heavy session" else "Run a diligence pass on $projectName",
                        summary = "Use the diligence lens to turn the brief's risk signals into an evidence-backed launch-readiness check with explicit blockers, owner, and proof.",
                        projectID = topProject?.id,
                        projectDisplayName = topProject?.displayName,
                        lens = InsightMissionCandidate.Lens.DILIGENCE,
                        priority = if (quotaHot) InsightMissionCandidate.Priority.CRITICAL else InsightMissionCandidate.Priority.HIGH,
                        confidence = InsightConfidence.MEDIUM,
                        expectedImpact = "Prevents cost, quota, or release surprises from hiding behind a normal-looking usage summary.",
                        effort = InsightMissionCandidate.Effort.SMALL,
                        acceptanceCriteria = listOf(
                            "List the top production, cost, privacy, and reliability risks with citations.",
                            "Separate blockers from serious concerns and acceptable tradeoffs.",
                            "Attach the verification command or live evidence that closes each blocker."
                        ),
                        sourceInsightIDs = sourceInsightIDs,
                        evidence = diligenceEvidence,
                        dispatchMetadata = mapOf("lens" to "diligence", "source" to "insight_engine")
                    )
                )
            }

            if (topModel != null) {
                missions.add(
                    InsightMissionCandidate(
                        title = "Reduce repeated ${topModel.id} drag",
                        summary = "Use the debt lens to decide whether high recurring model usage is doing essential expert work or masking unclear requirements, weak tests, brittle routing, or missing automation.",
                        projectID = topProject?.id,
                        projectDisplayName = topProject?.displayName,
                        lens = InsightMissionCandidate.Lens.TECH_DEBT,
                        priority = if (topModel.costUSD > maxOf(1.0, digest.totals.costUSD * 0.35)) InsightMissionCandidate.Priority.HIGH else InsightMissionCandidate.Priority.MEDIUM,
                        confidence = InsightConfidence.MEDIUM,
                        expectedImpact = "Cuts future analysis spend by removing the underlying delivery friction, not just swapping models.",
                        effort = InsightMissionCandidate.Effort.MEDIUM,
                        acceptanceCriteria = listOf(
                            "Identify the repeated work pattern causing the expensive model usage.",
                            "Choose the smallest remediation that prevents the same class of future sessions.",
                            "Add or update a test, runbook, or automation proof that the drag was actually reduced."
                        ),
                        sourceInsightIDs = sourceInsightIDs,
                        evidence = nonEmptyEvidence(listOf(modelCitation, projectCitation), activityCitation),
                        dispatchMetadata = mapOf("lens" to "techDebt", "source" to "insight_engine")
                    )
                )
            } else if (topProject == null) {
                missions.add(
                    InsightMissionCandidate(
                        title = "Upgrade the next brief with project and model attribution",
                        summary = "The digest has activity totals but lacks enough project, provider, or model breakdown to explain the work intelligently. Use the focus lens to make the next analysis more actionable instead of accepting generic totals.",
                        lens = InsightMissionCandidate.Lens.FOCUS,
                        priority = if (digest.totals.sessionCount > 0) InsightMissionCandidate.Priority.HIGH else InsightMissionCandidate.Priority.MEDIUM,
                        confidence = InsightConfidence.MEDIUM,
                        expectedImpact = "Turns an opaque usage summary into a useful brief that can name the workflow, model choice, and cost driver.",
                        effort = InsightMissionCandidate.Effort.SMALL,
                        acceptanceCriteria = listOf(
                            "Confirm mobile sync is receiving provider, model, and project summaries.",
                            "Refresh Insights and verify the Mission Board names at least one concrete driver.",
                            "Use the new driver to create one accretion, diligence, or debt mission."
                        ),
                        sourceInsightIDs = sourceInsightIDs,
                        evidence = listOf(activityCitation),
                        dispatchMetadata = mapOf("lens" to "focus", "source" to "insight_engine")
                    )
                )
            }

            val recommendations = if (topModel != null && digest.modelBenchmarks.isNotEmpty()) {
                listOf(
                    InsightRecommendation(
                        title = "Convert model-board advice into a routing experiment",
                        rationale = "Benchmark evidence is useful only after a bounded comparison against your actual $projectName work.",
                        recommendedAction = "Run one UI/design or routine-coding session through the best-fit candidate, then compare quality, cost signal, and quota health before changing defaults.",
                        estimatedImpact = "Turns abstract model rankings into a safer routing decision.",
                        evidence = listOfNotNull(modelCitation) + digest.modelBenchmarks.take(2).map { benchmarkCitation(it) },
                        confidence = InsightConfidence.MEDIUM,
                        severity = InsightSeverity.MEDIUM
                    )
                )
            } else {
                emptyList()
            }

            return MissionAdvice(findings, recommendations, missions)
        }

        private fun nonEmptyEvidence(candidates: List<InsightCitation?>, fallback: InsightCitation): List<InsightCitation> =
            candidates.filterNotNull().ifEmpty { listOf(fallback) }

        private data class BenchmarkAdvice(
            val findings: List<InsightFinding>,
            val recommendations: List<InsightRecommendation>,
            val widgets: List<InsightGeneratedWidget>
        )

        private fun modelBenchmarkAdvice(
            digest: InsightDigest,
            topModel: InsightDigest.ModelSnapshot?,
            selectedModel: InsightModelTag,
            window: InsightTimeWindow
        ): BenchmarkAdvice {
            val benchmarks = digest.modelBenchmarks
            if (benchmarks.isEmpty()) return BenchmarkAdvice(emptyList(), emptyList(), emptyList())

            val used = digest.models.associateBy { normalizedModelID(it.id) }
            val topBenchmark = topModel?.let { model ->
                benchmarks.filter { normalizedModelID(it.modelID) == normalizedModelID(model.id) }
                    .maxByOrNull { it.score ?: -1.0 }
            }
            val bestDesign = benchmarks
                .filter { it.taskCategory == "design" }
                .maxByOrNull { it.score ?: -1.0 }
                ?: benchmarks
                    .filter { it.taskCategory == "coding" }
                    .maxByOrNull { it.score ?: -1.0 }
            val cheapestSimilar = topModel?.let { current ->
                benchmarks
                    .filter { normalizedModelID(it.modelID) != normalizedModelID(current.id) }
                    .filter { (it.costSignal ?: -1.0) > (topBenchmark?.costSignal ?: 0.0) + 0.12 }
                    .filter { topBenchmark?.score == null || it.score == null || it.score >= (topBenchmark.score ?: 0.0) - 0.08 }
                    .maxWithOrNull(compareBy<InsightDigest.ModelBenchmarkSummary> { it.costSignal ?: 0.0 }.thenBy { it.score ?: 0.0 })
            }

            val findings = mutableListOf<InsightFinding>()
            val recommendations = mutableListOf<InsightRecommendation>()
            val widgets = mutableListOf<InsightGeneratedWidget>()

            if (topModel != null && bestDesign != null && normalizedModelID(bestDesign.modelID) != normalizedModelID(topModel.id)) {
                findings.add(
                    InsightFinding(
                        title = "UI/design work should be checked against ${bestDesign.modelID}",
                        whyItMatters = "${topModel.id} leads spend, but ${bestDesign.modelID} is the strongest cited ${bestDesign.taskCategory} benchmark candidate${scorePhrase(bestDesign)}.",
                        evidence = listOf(
                            InsightCitation("model:${topModel.id}", InsightCitation.Kind.Model(topModel.id), topModel.id),
                            benchmarkCitation(bestDesign)
                        ),
                        confidence = confidence(bestDesign),
                        severity = InsightSeverity.MEDIUM,
                        recommendedAction = "Use ${bestDesign.modelID} for the next UI-heavy task only if quota and routing are healthy."
                    )
                )
            }

            if (topModel != null && cheapestSimilar != null) {
                val impact = cheapestSimilar.blendedCostPerMtoken?.let { "$${"%.2f".format(it)}/MTok blended; validate quality before moving routine work." }
                    ?: cheapestSimilar.costSignal?.let { "Cost signal ${(it * 100).toInt()}/100; exact savings need provider price confirmation." }
                recommendations.add(
                    InsightRecommendation(
                        title = "${cheapestSimilar.modelID} looks cheaper at similar benchmark strength",
                        rationale = "${topModel.id} is your largest model cost contributor. ${cheapestSimilar.modelID} is close on benchmark evidence${scorePhrase(cheapestSimilar)} and has a stronger cost signal.",
                        recommendedAction = "Route one routine ${cheapestSimilar.taskCategory} session to ${cheapestSimilar.modelID}, then compare output quality before changing defaults.",
                        estimatedImpact = impact,
                        evidence = listOf(
                            InsightCitation("model:${topModel.id}", InsightCitation.Kind.Model(topModel.id), topModel.id),
                            benchmarkCitation(cheapestSimilar)
                        ),
                        confidence = confidence(cheapestSimilar),
                        severity = InsightSeverity.HIGH
                    )
                )
            }

            val rows = benchmarks
                .filter { it.score != null || it.rank != null }
                .sortedWith(
                    compareByDescending<InsightDigest.ModelBenchmarkSummary> { used.containsKey(normalizedModelID(it.modelID)) }
                        .thenByDescending { it.score ?: -1.0 }
                        .thenBy { it.rank ?: Int.MAX_VALUE }
                )
                .take(6)
                .map {
                    InsightWidgetData.Ranking.Row(
                        id = it.id,
                        label = it.modelID,
                        value = it.score ?: it.rank?.let { rank -> 1.0 / rank.coerceAtLeast(1) } ?: 0.0,
                        secondaryLabel = listOf(it.taskCategory, it.attribution ?: it.source).joinToString(" · ")
                    )
                }
            if (rows.isNotEmpty()) {
                val widget = InsightWidget(
                    kind = InsightWidgetKind.BAR_RANKING,
                    title = "Benchmark-aware model board",
                    spec = InsightWidgetSpec.Ranking(InsightWidgetSpec.RankingSpec()),
                    dataBinding = InsightDataBinding.Ranking("cost", InsightWidgetSpec.Dimension.MODEL, 6, window),
                    data = InsightWidgetData.Ranking(rows, ValueFormat.PERCENT, "Benchmark"),
                    freshness = com.openburnbar.data.insights.InsightFreshness.FRESH,
                    modelTag = selectedModel,
                    rationale = "Ranks cited benchmark candidates beside models used in this window."
                )
                widgets.add(InsightGeneratedWidget(widget = widget, reason = "Shows used models against public benchmark evidence.", citations = benchmarks.take(6).map { benchmarkCitation(it) }))
            }

            benchmarks.maxByOrNull { it.score ?: -1.0 }?.let {
                recommendations.add(
                    InsightRecommendation(
                        title = "Do not blindly switch to ${it.modelID}",
                        rationale = "Benchmarks are advisory. A higher public score loses when quota, account health, privacy mode, or task fit is worse.",
                        recommendedAction = "Treat ${it.modelID} as a candidate for ${it.taskCategory}, not as a global default.",
                        estimatedImpact = "Avoids over-routing premium or unavailable models.",
                        evidence = listOf(benchmarkCitation(it)),
                        confidence = confidence(it),
                        severity = InsightSeverity.MEDIUM
                    )
                )
            }

            return BenchmarkAdvice(findings.take(2), recommendations.take(3), widgets.take(2))
        }

        private fun benchmarkCitation(benchmark: InsightDigest.ModelBenchmarkSummary): InsightCitation =
            InsightCitation(
                "benchmark:${benchmark.id}",
                InsightCitation.Kind.Benchmark(benchmark.source, benchmark.modelID, benchmark.taskCategory),
                "${benchmark.attribution ?: benchmark.source} ${benchmark.taskCategory}"
            )

        private fun confidence(benchmark: InsightDigest.ModelBenchmarkSummary): InsightConfidence =
            when {
                (benchmark.confidence ?: 0.6) >= 0.75 -> InsightConfidence.HIGH
                (benchmark.confidence ?: 0.6) <= 0.45 -> InsightConfidence.LOW
                else -> InsightConfidence.MEDIUM
            }

        private fun scorePhrase(benchmark: InsightDigest.ModelBenchmarkSummary): String =
            benchmark.score?.let { " (${(it * 100).toInt()}/100)" } ?: benchmark.rank?.let { " (#$it)" } ?: ""

        private fun normalizedModelID(value: String): String =
            value.lowercase().replace("_", "-").replace(".", "-").replace("/", "-")

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
        digest.modelBenchmarks.take(12).forEach { benchmark ->
            val label = "${benchmark.attribution ?: benchmark.source} ${benchmark.taskCategory} · ${benchmark.modelID}"
            val citation = InsightCitation(
                "benchmark:${benchmark.id}",
                InsightCitation.Kind.Benchmark(benchmark.source, benchmark.modelID, benchmark.taskCategory),
                label
            )
            val parts = buildList {
                benchmark.score?.let { add("score ${(it * 100).toInt()}/100") }
                benchmark.rank?.let { add("rank #$it") }
                benchmark.blendedCostPerMtoken?.let { add("$${"%.2f".format(it)}/MTok blended") }
                    ?: benchmark.costSignal?.let { add("cost signal ${(it * 100).toInt()}/100") }
                add("freshness ${benchmark.freshness}")
            }
            out.add(InsightEvidence("benchmark:${benchmark.id}", citation, "model_benchmarks", "${benchmark.modelID} ${benchmark.taskCategory}: ${parts.joinToString()}.", benchmark.score))
        }
        digest.quotaSnapshots.take(8).forEach { quota ->
            val citation = InsightCitation("quota:${quota.id}", InsightCitation.Kind.Quota(quota.providerID, quota.bucketName), "${quota.providerID} ${quota.bucketName}")
            out.add(InsightEvidence("quota:${quota.id}", citation, "quota_snapshots", "${quota.providerID} ${quota.bucketName}: ${quota.used} used.", quota.limit?.let { if (it > 0) quota.used / it else 0.0 }))
        }
        return out
    }
}
