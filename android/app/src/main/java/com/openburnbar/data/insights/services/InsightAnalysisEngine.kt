package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisContext
import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.data.repos.InsightAnalysisAuditLogRepository
import com.openburnbar.data.repos.InsightAnalysisCacheRepository
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

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
        resolveCachedAndroidInsightResult(cache, this, request)?.let { return it }
        val auditID = newAndroidInsightAuditId()
        val startedAt = androidInsightStartedAt()
        val startedEntry = buildStartedAndroidAuditEntry(request, auditID, startedAt)
        auditLog?.upsertLatest(startedEntry)
        return try {
            completeAndroidInsightAnalysis(this, request, startedEntry, auditID, cache, auditLog)
        } catch (t: BurnBarProSubscriptionRequiredException) {
            recordAndroidInsightPaywallFailure(auditLog, startedEntry, t)
            throw t
        }
    }

    internal suspend fun executeSelectedModel(request: InsightAnalysisRequest): InsightAnalysisResult {
        if (restrictToLocalOnly && request.selectedModel.egressTier != InsightEgressTier.LOCAL_ONLY) {
            error("${request.selectedModel.displayName} cannot be used while local-only mode is enabled.")
        }
        if (request.selectedModel.providerKey == "local-rules") {
            return fallback.analyze(request)
        }
        val gateway =
            gateways[request.selectedModel.providerKey]
                ?: return tryHostedThenLocalFallback(
                    request,
                    "No Android Insights gateway is configured for ${request.selectedModel.providerKey}.",
                )
        return try {
            val result = gateway.analyze(request)
            if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP && result.briefingAnswer ==
                null
            ) {
                val answerSource =
                    if (result.modelTag.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY) {
                        InsightBriefingAnswer.Source.HOSTED_FALLBACK
                    } else {
                        InsightBriefingAnswer.Source.MODEL_GATEWAY
                    }
                result.copy(
                    briefingAnswer =
                    InsightBriefingAnswer(
                        question = request.prompt,
                        answer = composeAnswerBody(result),
                        bullets = composeGroundedPoints(result),
                        citations = result.citations.take(INSIGHT_MAX_CITATIONS),
                        source = answerSource,
                        modelDisplayName = result.modelTag.displayName,
                    ),
                )
            } else {
                result
            }
        } catch (paywall: BurnBarProSubscriptionRequiredException) {
            if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) {
                composeSubscriptionRequiredFallback(request)
            } else {
                throw paywall
            }
        } catch (t: BurnBarProSubscriptionRequiredException) {
            tryHostedThenLocalFallback(request, t.message ?: t.javaClass.simpleName)
        }
    }

    private suspend fun tryHostedThenLocalFallback(request: InsightAnalysisRequest, reason: String): InsightAnalysisResult {
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
                        briefingAnswer =
                        (
                            existing ?: InsightBriefingAnswer(
                                question = request.prompt,
                                answer = composeAnswerBody(hostedResult),
                                bullets = composeGroundedPoints(hostedResult),
                                citations = hostedResult.citations.take(INSIGHT_MAX_CITATIONS),
                                source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                                modelDisplayName = hostedResult.modelTag.displayName,
                                isFallback = false,
                            )
                            ).copy(
                            source = InsightBriefingAnswer.Source.HOSTED_FALLBACK,
                            isFallback = false,
                        ),
                    )
                } catch (_: BurnBarProSubscriptionRequiredException) {
                    return composeSubscriptionRequiredFallback(request)
                } catch (_: Throwable) {
                    // Fall through to local rules — disclosed below.
                }
            }
        }
        val fallbackResult = fallback.analyze(request)
        val answer = fallbackResult.briefingAnswer ?: return fallbackResult
        return fallbackResult.copy(
            briefingAnswer =
            answer.copy(
                isFallback = true,
                modelDisplayName = "${request.selectedModel.displayName} → Local rules",
            ),
        )
    }

    private suspend fun composeSubscriptionRequiredFallback(request: InsightAnalysisRequest): InsightAnalysisResult {
        val base = fallback.analyze(request)
        val existing = base.briefingAnswer ?: return base
        return base.copy(
            briefingAnswer =
            existing.copy(
                isFallback = true,
                modelDisplayName = InsightBriefingAnswer.SUBSCRIPTION_REQUIRED_DISPLAY_NAME,
                answer =
                buildString {
                    appendLine(
                        "BurnBar Pro subscription required to run hosted Intelligence Brief answers. " +
                            "Connect your own LLM (Hermes, Claude, OpenAI, Ollama, Pi, etc.) or upgrade to " +
                            "BurnBar Pro to use our hosted MiniMax route.",
                    )
                    appendLine()
                    append(existing.answer)
                }.trim(),
            ),
        )
    }

    internal suspend fun ensureBriefingAnswer(result: InsightAnalysisResult, request: InsightAnalysisRequest): InsightAnalysisResult {
        if (request.instruction != InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP || result.briefingAnswer !=
            null
        ) {
            return result
        }
        if (result.modelTag.providerKey == "local-rules") {
            return result.copy(briefingAnswer = fallback.analyze(request).briefingAnswer)
        }
        val answerSource =
            if (result.modelTag.providerKey == AndroidBurnBarHostedInsightGateway.PROVIDER_KEY) {
                InsightBriefingAnswer.Source.HOSTED_FALLBACK
            } else {
                InsightBriefingAnswer.Source.MODEL_GATEWAY
            }
        return result.copy(
            briefingAnswer =
            InsightBriefingAnswer(
                question = request.prompt,
                answer = composeAnswerBody(result),
                bullets = composeGroundedPoints(result),
                citations = result.citations.take(INSIGHT_MAX_CITATIONS),
                source = answerSource,
                modelDisplayName = result.modelTag.displayName,
            ),
        )
    }

    @Deprecated(
        "Kept as a deprecated symbol for source compatibility with older test bundles. " +
            "Production callers should route through tryHostedThenLocalFallback to give the " +
            "BurnBar-hosted route a chance before degrading.",
    )
    private suspend fun fallbackForQuestionOrThrow(request: InsightAnalysisRequest, reason: String): InsightAnalysisResult =
        tryHostedThenLocalFallback(request, reason)

    private fun composeAnswerBody(result: InsightAnalysisResult): String = buildList {
        if (result.executiveSummary.isNotBlank()) add(result.executiveSummary)
        result.findings.firstOrNull()?.let {
            if (!result.executiveSummary.lowercase().contains(it.title.lowercase())) add(it.whyItMatters)
            add(it.recommendedAction)
        }
    }.joinToString(" ")

    private fun composeGroundedPoints(result: InsightAnalysisResult): List<String> = (
        result.findings.take(INSIGHT_GROUNDED_FINDING_LIMIT).map { it.title } +
            result.anomalies.take(2).map { "Spike: ${it.title}" } +
            result.recommendations.take(2).map { "Action: ${it.title}" }
        ).take(INSIGHT_MAX_GROUNDED_POINTS)
}

class OllamaInsightAnalysisGateway(
    private val baseURL: String = "http://127.0.0.1:11434",
    private val client: OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(INSIGHT_CONNECT_TIMEOUT_SECONDS.toLong(), TimeUnit.SECONDS)
            .readTimeout(INSIGHT_READ_TIMEOUT_SECONDS.toLong(), TimeUnit.SECONDS)
            .build(),
    private val numPredict: Int = 1400,
) : InsightAnalysisModelGateway {
    override val providerKey: String = "ollama"
    override val displayName: String = "Ollama"
    override val models: List<InsightModelTag> =
        listOf(
            InsightModelTag(
                providerKey = providerKey,
                modelID = "llama3.1",
                displayName = "Ollama llama3.1",
                egressTier = InsightEgressTier.LOCAL_ONLY,
                stampedAt = Instant.now().toString(),
            ),
        )

    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult = withContext(Dispatchers.IO) {
        val startedAt = Instant.now().toString()
        val body =
            JSONObject().apply {
                put("model", request.selectedModel.modelID)
                put("stream", false)
                put("format", "json")
                put("think", false)
                put(
                    "options",
                    JSONObject().apply {
                        put("temperature", INSIGHT_LOCAL_MODEL_TEMPERATURE)
                        put("num_predict", numPredict)
                    },
                )
                put(
                    "messages",
                    JSONArray().apply {
                        put(
                            JSONObject().apply {
                                put("role", "system")
                                put("content", analysisSystemPrompt(request))
                            },
                        )
                        put(
                            JSONObject().apply {
                                put("role", "user")
                                put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request))
                            },
                        )
                    },
                )
            }
        val httpRequest =
            Request.Builder()
                .url(baseURL.trimEnd('/') + "/api/chat")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()
        client.newCall(httpRequest).execute().use { response ->
            if (!response.isSuccessful) error("Ollama returned HTTP ${response.code}")
            val raw = response.body?.string().orEmpty()
            val root = JSONObject(raw)
            val content =
                root.optJSONObject("message")?.optString("content")
                    ?: root.optString("content", raw)
            val usage =
                InsightTokenUsage(
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

    private fun analysisSystemPrompt(request: InsightAnalysisRequest): String = """
        You are OpenBurnBar Insights. Analyze the user's AI usage digest and return one JSON object only.
        Explain what changed, why it matters, what caused it, what is wasteful, what is risky, and what the user should
            do next.
        Never include secrets, credentials, raw files, or full transcripts. Only cite evidence IDs present in
            evidenceIndex.
        When model benchmark evidence exists, compare observed model usage against score/rank, cost signal, latency,
            task category, freshness, and attribution.
        Never invent benchmark ranks, prices, or dollar savings. If exact prices are absent, say cost signal rather
            than savings.
        For UI/design work, separate design/coding benchmark fit from general reasoning fit.
        Treat Android, iOS, iPadOS, and macOS Insights as mission-control remotes for the user's local Hermes, Pi,
            OpenClaw/OpenClaude, Claude, and Codex agents.
        When a user asks for a mission, produce dispatch-ready work: recommended agent, target project, evidence to
            inspect, acceptance criteria, validation commands, risks, and what mobile should show when complete.
        Return missionCandidates separately from findings and recommendations. Missions must be concrete work packages,
            not duplicate insight prose.
        Use accretion, diligence, techDebt, routing, quota, and focus lenses to propose greater-purpose missions from
            the evidence.
        Recommend adjacent security, UI improvement, modernization, and cost-efficiency missions when the digest or
            benchmark evidence supports them.
        Return keys: executiveSummary, findings, anomalies, recommendations, missionCandidates, generatedWidgets,
            followUpQuestions, citations.
        Generated widgets must use known widget kinds and must include citations. Max generated widgets:
            ${request.maxGeneratedWidgets}.
    """.trimIndent()
}

object InsightAnalysisResultJsonDecoder {
    fun decode(content: String, request: InsightAnalysisRequest, usage: InsightTokenUsage?): InsightAnalysisResult =
        decodeInsightAnalysisResultJson(content, request, usage)
}

class RuleBasedInsightAnalysisEngine(
    private val platform: InsightAnalysisPlatform,
) : InsightAnalysisEngine {
    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult {
        val result = buildRuleBasedInsightResult(request, platform)
        return result.copy(resultHash = ruleBasedInsightSha256(result.copy(resultHash = "").toString()))
    }

    companion object {
        fun materializeCanvas(result: InsightAnalysisResult, prompt: String): InsightCanvas = ruleBasedMaterializeCanvas(result, prompt)

        fun enrichMissionCandidates(result: InsightAnalysisResult, request: InsightAnalysisRequest, platform: InsightAnalysisPlatform): InsightAnalysisResult =
            ruleBasedEnrichMissionCandidates(result, request, platform)
    }
}

object InsightAggregator {
    fun buildContext(
        digest: InsightDigest,
        includedDataSources: List<String>,
        priorRunSummaries: List<String> = emptyList(),
        evidencePacks: List<com.openburnbar.data.insights.InsightEvidencePack> = emptyList(),
    ): InsightAnalysisContext {
        val encoded = kotlinx.serialization.json.Json.encodeToString(InsightDigest.serializer(), digest)
        val evidence = buildInsightEvidenceIndex(digest) + evidencePacks.flatMap { it.evidence }
        val sources = (includedDataSources + evidencePacks.flatMap { it.includedDataSources }).distinct().sorted()
        val truncated =
            buildList {
                if (digest.providers.size >= INSIGHT_PROVIDER_TRIM_THRESHOLD && "provider_summaries" in includedDataSources) {
                    add("provider_summaries")
                }
                if (digest.models.size >= INSIGHT_MODEL_TRIM_THRESHOLD && "model_summaries" in includedDataSources) {
                    add("model_summaries")
                }
                if (digest.daily.size >= INSIGHT_DAILY_TRIM_THRESHOLD && "daily_points" in includedDataSources) add("daily_points")
            }
        val budget =
            InsightContextBudgetReport(
                encodedBytes = encoded.toByteArray(Charsets.UTF_8).size,
                estimatedPromptTokens = (encoded.length / 4).coerceAtLeast(1),
                includedDataSources = sources,
                truncatedDataSources = truncated,
                truncationSummary =
                if (truncated.isEmpty()) {
                    "No truncation."
                } else {
                    "Context was budgeted to ${InsightDigest.MAX_ENCODED_BYTES} bytes; " +
                        "long-tail ${truncated.joinToString()} data was summarized."
                },
            )
        return InsightAnalysisContext(
            digest = digest,
            evidenceIndex = evidence,
            budgetReport = budget,
            priorRunSummaries = priorRunSummaries,
            evidencePacks = evidencePacks,
        )
    }
}
