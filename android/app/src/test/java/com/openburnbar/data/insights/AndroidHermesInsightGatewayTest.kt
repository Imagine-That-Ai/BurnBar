package com.openburnbar.data.insights

import com.openburnbar.data.insights.services.AndroidHermesInsightAnalysisGateway
import com.openburnbar.data.insights.services.AndroidInsightGatewayRegistry
import com.openburnbar.data.insights.services.HermesInsightChunk
import com.openburnbar.data.insights.services.InMemoryInsightDataSource
import com.openburnbar.data.insights.services.InsightAggregator
import com.openburnbar.data.insights.services.InsightAnalysisModelGateway
import io.mockk.mockk
import io.mockk.every
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * Covers the Hermes Insights gateway end-to-end against an in-memory
 * OkHttp interceptor stub. Mirrors `HermesInsightAdapterTests` on the
 * Swift side so parity regressions are obvious.
 *
 * Skipped registry-shape coverage: `defaultGateways(..., hermesProvider)`
 * is exercised via the `analyze` + `stream` paths below — the
 * provider-list assembly is a one-line mutable list addition and is
 * indirectly covered by the gateway tests.
 */
class AndroidHermesInsightGatewayTest {

    @Test
    fun `analyze surfaces structured result with token usage and cost`() = runBlocking {
        val (gateway, _) = makeGateway(
            body = chatCompletionBody(
                content = canonicalEnvelope(),
                inputTokens = 4_200,
                outputTokens = 1_027,
                estimatedCostUSD = 0.0042
            )
        )
        val request = followUpRequest("Why did cost spike?")
        val result = gateway.analyze(request)
        assertEquals("hermes", result.modelTag.providerKey)
        assertNotNull(result.tokenUsage)
        assertEquals(4_200, result.tokenUsage?.inputTokens)
        assertEquals(1_027, result.tokenUsage?.outputTokens)
        assertEquals(0.0042, result.tokenUsage?.estimatedCostUSD ?: 0.0, 0.00001)
        assertTrue(result.findings.isNotEmpty())
    }

    @Test
    fun `analyze rejects when hermes is unreachable so engine can fall back`() = runBlocking {
        val gateway = AndroidHermesInsightAnalysisGateway(
            baseURLProvider = { "http://stub.invalid" },
            reachabilityProvider = { false },
            client = OkHttpClient.Builder()
                .connectTimeout(2, TimeUnit.SECONDS)
                .readTimeout(2, TimeUnit.SECONDS)
                .build()
        )
        var caught: Throwable? = null
        try {
            gateway.analyze(followUpRequest("Why did cost spike?"))
        } catch (t: Throwable) {
            caught = t
        }
        assertNotNull("Expected analyze() to throw when Hermes is unreachable", caught)
        assertTrue(caught!!.message?.contains("not reachable") == true)
    }

    @Test
    fun `stream yields delta chunks then usage and completion`() = runBlocking {
        val sseBody = listOf(
            sseChunk(content = "Hermes routed "),
            sseChunk(content = "two long Claude turns "),
            sseChunk(content = "→ cost +\$0.42."),
            sseUsage(inputTokens = 3_900, outputTokens = 1_200, costUSD = 0.0051),
            "data: [DONE]\n"
        ).joinToString(separator = "\n")
        val (gateway, _) = makeGateway(body = sseBody, contentType = "text/event-stream")
        val chunks = gateway.stream(followUpRequest("Why did cost spike?")).toList()
        val deltas = chunks.filterIsInstance<HermesInsightChunk.Delta>().map { it.text }
        assertEquals(listOf("Hermes routed ", "two long Claude turns ", "→ cost +\$0.42."), deltas)
        val usage = chunks.filterIsInstance<HermesInsightChunk.Usage>().firstOrNull()?.usage
        assertNotNull(usage)
        assertEquals(3_900, usage!!.inputTokens)
        assertEquals(1_200, usage.outputTokens)
        assertEquals(0.0051, usage.estimatedCostUSD, 0.00001)
        val completed = chunks.filterIsInstance<HermesInsightChunk.Completed>().firstOrNull()
        assertNotNull(completed)
        assertTrue(completed!!.fullAnswer.startsWith("Hermes routed two long Claude turns"))
    }

    @Test
    fun `defaultGateways prefers hermes provider over legacy endpoint`() {
        val credentialStore = mockk<com.openburnbar.data.insights.services.AndroidInsightCredentialStore>(relaxed = true)
        every { credentialStore.credential(any(), any()) } returns null
        every { credentialStore.endpoint("hermes") } returns "http://127.0.0.1:8642"
        val stubHermes = object : InsightAnalysisModelGateway {
            override val providerKey: String = "hermes"
            override val displayName: String = "Injected Hermes"
            override val models: List<InsightModelTag> = listOf(
                InsightModelTag(
                    providerKey = "hermes",
                    modelID = "hermes-injected",
                    displayName = "Injected Hermes",
                    egressTier = InsightEgressTier.USER_RELAY
                )
            )
            override suspend fun analyze(request: InsightAnalysisRequest) =
                throw UnsupportedOperationException("stub")
        }
        val gateways = AndroidInsightGatewayRegistry.defaultGateways(
            credentialStore,
            hermesProvider = { stubHermes }
        )
        val hermesEntries = gateways.filter { it.providerKey == "hermes" }
        assertEquals(1, hermesEntries.size)
        assertEquals("Injected Hermes", hermesEntries.first().displayName)
    }

    @Test
    fun `defaultGateways falls back to legacy hermes endpoint when provider returns null`() {
        val credentialStore = mockk<com.openburnbar.data.insights.services.AndroidInsightCredentialStore>(relaxed = true)
        every { credentialStore.credential(any(), any()) } returns null
        every { credentialStore.endpoint("hermes") } returns "http://127.0.0.1:8642"
        val gateways = AndroidInsightGatewayRegistry.defaultGateways(
            credentialStore,
            hermesProvider = { null }
        )
        assertTrue(gateways.any { it.providerKey == "hermes" })
    }

    // MARK: - Helpers

    private fun makeGateway(
        body: String,
        contentType: String = "application/json",
    ): Pair<AndroidHermesInsightAnalysisGateway, OkHttpClient> {
        val client = OkHttpClient.Builder()
            .connectTimeout(2, TimeUnit.SECONDS)
            .readTimeout(2, TimeUnit.SECONDS)
            .addInterceptor(stubInterceptor(body = body, contentType = contentType))
            .build()
        val gateway = AndroidHermesInsightAnalysisGateway(
            baseURLProvider = { "http://stub.invalid" },
            reachabilityProvider = { true },
            client = client,
        )
        return gateway to client
    }

    private fun stubInterceptor(body: String, contentType: String): Interceptor =
        Interceptor { chain ->
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .header("Content-Type", contentType)
                .body(body.toResponseBody(contentType.toMediaType()))
                .build()
        }

    private fun followUpRequest(prompt: String): InsightAnalysisRequest {
        val digest = runBlocking { InMemoryInsightDataSource().buildDigest(InsightFilter()) }
        val context = InsightAggregator.buildContext(
            digest = digest,
            includedDataSources = listOf("firestore_rollups"),
            priorRunSummaries = emptyList()
        )
        val model = InsightModelTag(
            providerKey = "hermes",
            modelID = "hermes-default",
            displayName = "Hermes",
            egressTier = InsightEgressTier.USER_RELAY,
            stampedAt = "2026-05-14T10:00:00Z"
        )
        return InsightAnalysisRequest(
            prompt = prompt,
            context = context,
            currentCanvas = null,
            selectedModel = model,
            instruction = InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP,
            allowDeepTranscriptAnalysis = false,
            maxGeneratedWidgets = 6
        )
    }

    private fun chatCompletionBody(
        content: String,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double,
    ): String = JSONObject().apply {
        put(
            "choices", JSONArray().put(
                JSONObject().put(
                    "message",
                    JSONObject().put("content", content)
                )
            )
        )
        put(
            "usage", JSONObject()
                .put("prompt_tokens", inputTokens)
                .put("completion_tokens", outputTokens)
                .put("estimated_cost_usd", estimatedCostUSD)
        )
    }.toString()

    private fun sseChunk(content: String): String {
        val payload = JSONObject().apply {
            put(
                "choices", JSONArray().put(
                    JSONObject().put(
                        "delta",
                        JSONObject().put("content", content)
                    )
                )
            )
        }
        return "data: $payload"
    }

    private fun sseUsage(inputTokens: Int, outputTokens: Int, costUSD: Double): String {
        val payload = JSONObject().apply {
            put(
                "usage", JSONObject()
                    .put("prompt_tokens", inputTokens)
                    .put("completion_tokens", outputTokens)
                    .put("estimated_cost_usd", costUSD)
            )
        }
        return "data: $payload"
    }

    private fun canonicalEnvelope(): String = """
        {
          "executiveSummary": "Cost jumped because Hermes routed two long Claude turns.",
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
