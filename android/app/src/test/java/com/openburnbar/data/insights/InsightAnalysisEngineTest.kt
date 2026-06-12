@file:Suppress("FunctionNaming", "LargeClass", "TooManyFunctions")
// detekt: JUnit backtick BDD test names; Android Insights orchestrator + Ollama gateway regression matrix.

package com.openburnbar.data.insights

import com.openburnbar.data.insights.services.AndroidBurnBarHostedInsightGateway
import com.openburnbar.data.insights.services.AndroidInsightAnalysisEngine
import com.openburnbar.data.insights.services.InMemoryInsightDataSource
import com.openburnbar.data.insights.services.InsightAggregator
import com.openburnbar.data.insights.services.InsightAnalysisModelGateway
import com.openburnbar.data.insights.services.OllamaInsightAnalysisGateway
import com.openburnbar.data.repos.InsightAnalysisCacheRepository
import io.mockk.coEvery
import io.mockk.coJustRun
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers the Android Insights orchestrator paths that synthesize briefing
 * answers (gateway results without one, the hosted fallback route, cache
 * hits), the local-only refusal, the Ollama gateway request contract, and
 * the aggregator's truncation thresholds. The citation/grounded-point caps
 * asserted here pin INSIGHT_MAX_CITATIONS / INSIGHT_GROUNDED_FINDING_LIMIT /
 * INSIGHT_MAX_GROUNDED_POINTS semantics.
 */
class InsightAnalysisEngineTest {
    private val testContext =
        runBlocking {
            InsightAggregator.buildContext(
                digest = InMemoryInsightDataSource().buildDigest(InsightFilter()),
                includedDataSources = listOf("firestore_rollups"),
            )
        }

    @Test
    fun `follow-up answers synthesized from gateway results cap citations and grounded points`() = runBlocking {
        val tag = modelTag("stub-gateway")
        val request = analysisRequest(tag)
        val gateway = ScriptedGateway(providerKey = "stub-gateway", models = listOf(tag)) { gatewayResult(tag, it) }
        val engine = AndroidInsightAnalysisEngine(gateways = mapOf("stub-gateway" to gateway))

        val result = engine.analyze(request)

        assertEquals(1, gateway.callCount)
        val answer = requireNotNull(result.briefingAnswer)
        assertEquals(request.prompt, answer.question)
        // 7 citations in, 3 out: the briefing answer caps drill-down anchors.
        assertEquals(listOf("citation-1", "citation-2", "citation-3"), answer.citations.map { it.id })
        // 3 finding titles, then anomalies, capped at 4 grounded points overall.
        assertEquals(listOf("Finding 1", "Finding 2", "Finding 3", "Spike: Anomaly 1"), answer.bullets)
        assertEquals(InsightBriefingAnswer.Source.MODEL_GATEWAY, answer.source)
        assertEquals(tag.displayName, answer.modelDisplayName)
        assertFalse(answer.isFallback)
        assertTrue(answer.answer.contains("Provider routing concentrated cost"))
    }

    @Test
    fun `follow-up rides the hosted route when the selected provider has no gateway`() = runBlocking {
        val hostedKey = AndroidBurnBarHostedInsightGateway.PROVIDER_KEY
        val hostedTag = modelTag(hostedKey, displayName = "BurnBar hosted")
        val hosted =
            ScriptedGateway(providerKey = hostedKey, models = listOf(hostedTag)) { gatewayResult(hostedTag, it) }
        val request = analysisRequest(modelTag("unconfigured-provider"))
        val engine = AndroidInsightAnalysisEngine(gateways = mapOf(hostedKey to hosted))

        val result = engine.analyze(request)

        assertEquals(1, hosted.callCount)
        // The orchestrator swaps the unconfigured selection for the hosted route's own tag.
        assertEquals(hostedTag, hosted.lastRequest?.selectedModel)
        val answer = requireNotNull(result.briefingAnswer)
        assertEquals(InsightBriefingAnswer.Source.HOSTED_FALLBACK, answer.source)
        assertFalse(answer.isFallback)
        assertEquals(listOf("citation-1", "citation-2", "citation-3"), answer.citations.map { it.id })
        assertEquals("BurnBar hosted", answer.modelDisplayName)
    }

    @Test
    fun `cache hits skip the gateway and still synthesize a capped briefing answer`() = runBlocking {
        val tag = modelTag("stub-gateway")
        val request = analysisRequest(tag)
        val cache = mockk<InsightAnalysisCacheRepository>()
        coEvery { cache.lookup(any()) } returns
            InsightAnalysisCacheRepository.CachedResult(
                key = "cache-key",
                result = gatewayResult(tag, request),
                storedAt = "2026-06-11T00:00:00Z",
            )
        coJustRun { cache.store(any()) }
        val gateway =
            ScriptedGateway(providerKey = "stub-gateway", models = listOf(tag)) {
                error("the gateway must not run on a cache hit")
            }
        val engine = AndroidInsightAnalysisEngine(cache = cache, gateways = mapOf("stub-gateway" to gateway))

        val result = engine.analyze(request)

        assertEquals(0, gateway.callCount)
        val answer = requireNotNull(result.briefingAnswer)
        assertEquals(listOf("citation-1", "citation-2", "citation-3"), answer.citations.map { it.id })
        assertEquals(InsightBriefingAnswer.Source.MODEL_GATEWAY, answer.source)
        assertTrue(result.missionCandidates.isNotEmpty())
        // The enriched + answered result is written back so the next hit is complete.
        coVerify(exactly = 1) { cache.store(any()) }
    }

    @Test
    fun `local-only mode refuses models whose data leaves the device`() = runBlocking {
        val engine = AndroidInsightAnalysisEngine(restrictToLocalOnly = true)
        val request = analysisRequest(modelTag("hermes").copy(egressTier = InsightEgressTier.USER_RELAY))

        val error = runCatching { engine.analyze(request) }.exceptionOrNull()

        assertNotNull(error)
        assertTrue(error is IllegalStateException)
        assertTrue(error?.message.orEmpty().contains("local-only"))
    }

    @Test
    fun `ollama gateway defaults advertise a single local-only llama route`() {
        val gateway = OllamaInsightAnalysisGateway()

        assertEquals("ollama", gateway.providerKey)
        assertEquals("Ollama", gateway.displayName)
        val tag = gateway.models.single()
        assertEquals("llama3.1", tag.modelID)
        assertEquals(InsightEgressTier.LOCAL_ONLY, tag.egressTier)
    }

    @Test
    fun `ollama gateway posts deterministic low-temperature json chat and maps usage`() = runBlocking {
        var capturedUrl: String? = null
        var capturedBody: String? = null
        val client =
            OkHttpClient.Builder()
                .addInterceptor { chain ->
                    capturedUrl = chain.request().url.toString()
                    capturedBody = Buffer().also { chain.request().body?.writeTo(it) }.readUtf8()
                    Response.Builder()
                        .request(chain.request())
                        .protocol(Protocol.HTTP_1_1)
                        .code(200)
                        .message("OK")
                        .header("Content-Type", "application/json")
                        .body(ollamaChatResponse().toResponseBody("application/json".toMediaType()))
                        .build()
                }
                .build()
        val gateway = OllamaInsightAnalysisGateway(baseURL = "http://stub.invalid/", client = client)
        val request =
            analysisRequest(gateway.models.first(), instruction = InsightAnalysisRequest.Instruction.DEFAULT_BRIEF)

        val result = gateway.analyze(request)

        assertEquals("http://stub.invalid/api/chat", capturedUrl)
        val body = JSONObject(requireNotNull(capturedBody))
        assertEquals("llama3.1", body.getString("model"))
        assertFalse(body.getBoolean("stream"))
        assertEquals("json", body.getString("format"))
        assertEquals(0.2, body.getJSONObject("options").getDouble("temperature"), 1e-9)
        assertEquals(1400, body.getJSONObject("options").getInt("num_predict"))
        assertEquals("system", body.getJSONArray("messages").getJSONObject(0).getString("role"))
        assertEquals(321, result.tokenUsage?.inputTokens)
        assertEquals(123, result.tokenUsage?.outputTokens)
        assertEquals(0.0, result.tokenUsage?.estimatedCostUSD ?: -1.0, 1e-9)
        assertEquals("ollama", result.modelTag.providerKey)
        assertTrue(result.findings.isNotEmpty())
    }

    @Test
    fun `aggregator flags provider model and daily sources truncated at their thresholds`() {
        val digest =
            InsightDigest(
                providers = (1..12).map { providerSnapshot(it) },
                models = (1..16).map { modelSnapshot(it) },
                daily = (1..90).map { InsightDigest.DailyPoint(day = "day-%03d".format(it)) },
            )
        val sources = listOf("provider_summaries", "model_summaries", "daily_points")

        val context = InsightAggregator.buildContext(digest, sources)

        assertEquals(sources, context.budgetReport.truncatedDataSources)
        assertTrue(context.budgetReport.truncationSummary.contains(InsightDigest.MAX_ENCODED_BYTES.toString()))
    }

    @Test
    fun `aggregator reports no truncation below the thresholds or without opted-in sources`() {
        val below =
            InsightDigest(
                providers = (1..11).map { providerSnapshot(it) },
                models = (1..15).map { modelSnapshot(it) },
                daily = (1..89).map { InsightDigest.DailyPoint(day = "day-%03d".format(it)) },
            )
        val sources = listOf("provider_summaries", "model_summaries", "daily_points")
        val belowReport = InsightAggregator.buildContext(below, sources).budgetReport
        assertTrue(belowReport.truncatedDataSources.isEmpty())
        assertEquals("No truncation.", belowReport.truncationSummary)

        val notOptedIn = InsightDigest(providers = (1..12).map { providerSnapshot(it) })
        val notOptedInReport = InsightAggregator.buildContext(notOptedIn, listOf("firestore_rollups")).budgetReport
        assertTrue(notOptedInReport.truncatedDataSources.isEmpty())
    }

    private fun analysisRequest(
        model: InsightModelTag,
        instruction: InsightAnalysisRequest.Instruction = InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP,
    ): InsightAnalysisRequest = InsightAnalysisRequest(
        prompt = "Why did cost spike this week?",
        context = testContext,
        selectedModel = model,
        instruction = instruction,
    )

    private fun modelTag(providerKey: String, displayName: String = providerKey): InsightModelTag = InsightModelTag(
        providerKey = providerKey,
        modelID = "$providerKey-model",
        displayName = displayName,
        egressTier = InsightEgressTier.USER_KEY,
        stampedAt = "2026-06-11T00:00:00Z",
    )

    private fun gatewayResult(tag: InsightModelTag, request: InsightAnalysisRequest): InsightAnalysisResult = InsightAnalysisResult(
        requestID = request.id,
        platform = InsightAnalysisPlatform.ANDROID,
        timeWindow = InsightTimeWindow.Last7d,
        executiveSummary = "Provider routing concentrated cost on one model this week.",
        modelTag = tag,
        contextBudget = request.context.budgetReport,
        findings = (1..5).map { finding("Finding $it") },
        anomalies = (1..3).map { anomaly("Anomaly $it") },
        recommendations = (1..3).map { recommendation("Recommendation $it") },
        citations = (1..7).map { citation(it) },
        resultHash = "gateway-result",
    )

    private fun citation(index: Int): InsightCitation = InsightCitation(
        id = "citation-$index",
        kind = InsightCitation.Kind.Model("model-$index"),
        label = "Citation $index",
    )

    private fun finding(title: String): InsightFinding = InsightFinding(
        title = title,
        whyItMatters = "$title shifted a third of weekly spend.",
        evidence = listOf(citation(0)),
        confidence = InsightConfidence.HIGH,
        recommendedAction = "Review $title routing.",
    )

    private fun anomaly(title: String): InsightAnomaly = InsightAnomaly(
        title = title,
        detail = "$title exceeded the daily baseline.",
        score = 0.9,
        evidence = listOf(citation(0)),
        confidence = InsightConfidence.MEDIUM,
    )

    private fun recommendation(title: String): InsightRecommendation = InsightRecommendation(
        title = title,
        rationale = "$title lowers cost without quality loss.",
        recommendedAction = "Adopt $title.",
        evidence = listOf(citation(0)),
        confidence = InsightConfidence.MEDIUM,
    )

    private fun providerSnapshot(index: Int): InsightDigest.ProviderSnapshot = InsightDigest.ProviderSnapshot(
        id = "provider-%02d".format(index),
        displayName = "Provider $index",
    )

    private fun modelSnapshot(index: Int): InsightDigest.ModelSnapshot = InsightDigest.ModelSnapshot(
        id = "model-%02d".format(index),
        providerID = "provider-01",
    )

    private fun ollamaChatResponse(): String = JSONObject()
        .put("message", JSONObject().put("content", canonicalEnvelope()))
        .put("prompt_eval_count", 321)
        .put("eval_count", 123)
        .toString()

    private fun canonicalEnvelope(): String = """
        {
          "executiveSummary": "Cost jumped because two long Claude turns ran back to back.",
          "findings": [
            {
              "title": "Two heavy Claude turns drove the spike",
              "whyItMatters": "Each turn ran over 100K input tokens through claude-sonnet-4-6.",
              "evidence": [{"id": null, "label": "Sessions"}],
              "confidence": "high",
              "severity": "medium",
              "recommendedAction": "Compare with claude-haiku-4-5 for the next routine turn."
            }
          ],
          "anomalies": [],
          "recommendations": [],
          "generatedWidgets": [],
          "followUpQuestions": [
            {"question": "Show me the two heavy turns."}
          ],
          "citations": []
        }
    """.trimIndent()
}

/** Deterministic in-memory gateway double that records invocations. */
private class ScriptedGateway(
    override val providerKey: String,
    override val models: List<InsightModelTag>,
    private val onAnalyze: suspend (InsightAnalysisRequest) -> InsightAnalysisResult,
) : InsightAnalysisModelGateway {
    override val displayName: String = providerKey

    var callCount: Int = 0
        private set
    var lastRequest: InsightAnalysisRequest? = null
        private set

    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult {
        callCount += 1
        lastRequest = request
        return onAnalyze(request)
    }
}
