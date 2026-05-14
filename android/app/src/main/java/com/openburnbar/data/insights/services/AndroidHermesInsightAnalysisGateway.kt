package com.openburnbar.data.insights.services

import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightBriefingAnswer
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTokenUsage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSource
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.TimeUnit

/**
 * Token + cost report produced by a Hermes Insights turn. Mirrors the
 * Swift `HermesInsightTokenUsage` so the Android audit log records the
 * same dimensions the iOS and macOS audit logs do.
 */
data class HermesInsightTokenUsage(
    val inputTokens: Int = 0,
    val outputTokens: Int = 0,
    val reasoningTokens: Int = 0,
    val cacheCreationTokens: Int = 0,
    val cacheReadTokens: Int = 0,
    /**
     * USD figure Hermes derived from its own pricing table for the
     * underlying provider call. The gateway prefers this over any
     * catalog-based estimate so the audit log records the relay's
     * truth, not a client-side approximation.
     */
    val estimatedCostUSD: Double = 0.0,
)

/**
 * One slice of a streamed Hermes Insights reply.
 *
 * - [Delta] — incremental answer text fragment. Concatenate in arrival
 *   order.
 * - [Usage] — terminal token + cost accounting reported by Hermes.
 *   Always arrives at most once, immediately before [Completed].
 * - [Completed] — stream finished cleanly. `fullAnswer` is the full
 *   assembled text in case the consumer wants to short-circuit without
 *   manually accumulating [Delta] chunks.
 */
sealed interface HermesInsightChunk {
    data class Delta(val text: String) : HermesInsightChunk
    data class Usage(val usage: HermesInsightTokenUsage) : HermesInsightChunk
    data class Completed(val fullAnswer: String) : HermesInsightChunk
}

/**
 * Hermes Insights gateway for Android.
 *
 * Implements [InsightAnalysisModelGateway] (buffered `analyze`) plus a
 * streaming `stream(...)` method that yields [HermesInsightChunk]s as
 * the relay sends them. Conditional on the user's Hermes connection
 * state — when [reachabilityProvider] returns `false` the gateway
 * surfaces a clear error so the orchestrator can fall back to local
 * rules with the existing `isFallback = true` UX, instead of silently
 * sending a doomed request.
 *
 * Wire from [AndroidInsightGatewayRegistry.defaultGateways] using the
 * new `hermesProvider` parameter; the view model should observe
 * `HermesService.isReachable` + `selectedConnection.endpointURL` and
 * call `defaultGateways(...)` again whenever either flips so the
 * catalog reflects the current connection.
 */
class AndroidHermesInsightAnalysisGateway(
    private val baseURLProvider: () -> String?,
    private val authorizationHeaderProvider: () -> String? = { null },
    private val reachabilityProvider: () -> Boolean = { true },
    private val client: OkHttpClient = defaultClient(),
    private val path: String = "/v1/chat/completions",
    private val maxTokens: Int = 1400,
) : InsightAnalysisModelGateway {

    override val providerKey: String = "hermes"
    override val displayName: String = "Hermes"
    override val models: List<InsightModelTag> = listOf(
        InsightModelTag(
            providerKey = providerKey,
            modelID = "hermes-default",
            displayName = "Hermes",
            egressTier = InsightEgressTier.USER_RELAY,
            stampedAt = Instant.now().toString(),
        )
    )

    override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult =
        withContext(Dispatchers.IO) {
            val baseURL = requireBaseURL(request)
            val startedAt = Instant.now().toString()
            val body = buildRequestBody(request, streaming = false)
            val httpRequest = buildHttpRequest(baseURL, body)
            client.newCall(httpRequest).execute().use { response ->
                if (!response.isSuccessful) {
                    error("Hermes Insights returned HTTP ${response.code}")
                }
                val raw = response.body?.string().orEmpty()
                val root = JSONObject(raw)
                val content = root.optJSONArray("choices")
                    ?.optJSONObject(0)
                    ?.optJSONObject("message")
                    ?.optString("content")
                    ?: root.optString("content", raw)
                val usage = parseUsage(root.optJSONObject("usage"))
                InsightAnalysisResultJsonDecoder.decode(
                    content,
                    request,
                    asInsightTokenUsage(request, usage, startedAt)
                )
            }
        }

    /**
     * Streaming variant. Yields [HermesInsightChunk.Delta] fragments
     * in order, then a terminal [HermesInsightChunk.Usage] + a
     * [HermesInsightChunk.Completed] when the upstream finishes.
     *
     * The flow is cancellation-aware: dropping the subscriber cancels
     * the underlying OkHttp call so the upstream model stops generating.
     */
    fun stream(request: InsightAnalysisRequest): Flow<HermesInsightChunk> =
        callbackFlow {
            val baseURL = requireBaseURL(request)
            val body = buildRequestBody(request, streaming = true)
            val httpRequest = buildHttpRequest(baseURL, body, streaming = true)
            val call = client.newCall(httpRequest)
            try {
                val response = call.execute()
                if (!response.isSuccessful) {
                    response.close()
                    close(IllegalStateException("Hermes Insights returned HTTP ${response.code}"))
                    return@callbackFlow
                }
                val source = response.body?.source()
                    ?: run {
                        response.close()
                        close(IllegalStateException("Hermes Insights returned an empty stream body."))
                        return@callbackFlow
                    }
                var assembled = StringBuilder()
                var terminalUsage: HermesInsightTokenUsage? = null
                try {
                    while (isActive && !source.exhausted()) {
                        val line = source.readUtf8Line() ?: continue
                        if (!line.startsWith("data: ")) continue
                        val payload = line.removePrefix("data: ")
                        if (payload == "[DONE]") break
                        val json = runCatching { JSONObject(payload) }.getOrNull() ?: continue
                        deltaText(json)?.takeIf { it.isNotEmpty() }?.let { delta ->
                            assembled.append(delta)
                            trySend(HermesInsightChunk.Delta(delta))
                        }
                        json.optJSONObject("usage")?.let { usageJson ->
                            terminalUsage = parseUsage(usageJson)
                        }
                    }
                } finally {
                    response.close()
                }
                terminalUsage?.let { trySend(HermesInsightChunk.Usage(it)) }
                trySend(HermesInsightChunk.Completed(assembled.toString()))
                close()
            } catch (t: Throwable) {
                call.cancel()
                close(t)
            }
            awaitClose { call.cancel() }
        }.flowOn(Dispatchers.IO)

    // MARK: - Helpers

    private fun requireBaseURL(request: InsightAnalysisRequest): String {
        if (!reachabilityProvider()) {
            error("Hermes is not reachable. Connect a relay in the Hermes tab and try again.")
        }
        val rawURL = baseURLProvider()?.trim().orEmpty()
        if (rawURL.isEmpty()) {
            error("Hermes endpoint is not configured for ${request.selectedModel.modelID}.")
        }
        return rawURL.trimEnd('/')
    }

    private fun buildHttpRequest(baseURL: String, body: String, streaming: Boolean = false): Request {
        val builder = Request.Builder()
            .url(baseURL + "/" + path.trimStart('/'))
            .post(body.toRequestBody("application/json".toMediaType()))
            .addHeader("Content-Type", "application/json")
        if (streaming) {
            builder.addHeader("Accept", "text/event-stream")
        }
        authorizationHeaderProvider()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { builder.addHeader("Authorization", "Bearer $it") }
        return builder.build()
    }

    private fun buildRequestBody(request: InsightAnalysisRequest, streaming: Boolean): String {
        val body = JSONObject().apply {
            put("model", request.selectedModel.modelID)
            put(
                "temperature",
                if (request.instruction == InsightAnalysisRequest.Instruction.ANSWER_FOLLOW_UP) 0.3 else 0.2
            )
            put("max_tokens", maxTokens)
            put("stream", streaming)
            if (streaming) {
                put("stream_options", JSONObject().put("include_usage", true))
            }
            put("response_format", JSONObject().put("type", "json_object"))
            put("messages", JSONArray().apply {
                put(
                    JSONObject()
                        .put("role", "system")
                        .put("content", analysisSystemPrompt(request))
                )
                put(
                    JSONObject()
                        .put("role", "user")
                        .put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request))
                )
            })
        }
        return body.toString()
    }

    private fun parseUsage(usageJson: JSONObject?): HermesInsightTokenUsage {
        if (usageJson == null) return HermesInsightTokenUsage()
        val input = usageJson.optInt("prompt_tokens", usageJson.optInt("input_tokens", 0))
        val output = usageJson.optInt("completion_tokens", usageJson.optInt("output_tokens", 0))
        val reasoning = usageJson.optInt(
            "reasoning_tokens",
            usageJson.optJSONObject("completion_tokens_details")?.optInt("reasoning_tokens", 0) ?: 0
        )
        val cacheRead = usageJson.optInt(
            "cache_read_input_tokens",
            usageJson.optJSONObject("prompt_tokens_details")?.optInt("cached_tokens", 0) ?: 0
        )
        val cacheCreation = usageJson.optInt("cache_creation_input_tokens", 0)
        val cost = usageJson.optDouble("estimated_cost_usd", usageJson.optDouble("cost_usd", 0.0))
        return HermesInsightTokenUsage(
            inputTokens = input,
            outputTokens = output,
            reasoningTokens = reasoning,
            cacheCreationTokens = cacheCreation,
            cacheReadTokens = cacheRead,
            estimatedCostUSD = if (cost.isNaN()) 0.0 else cost,
        )
    }

    private fun asInsightTokenUsage(
        request: InsightAnalysisRequest,
        usage: HermesInsightTokenUsage,
        startedAt: String,
    ): InsightTokenUsage = InsightTokenUsage(
        providerKey = providerKey,
        modelID = request.selectedModel.modelID,
        inputTokens = usage.inputTokens,
        outputTokens = usage.outputTokens,
        estimatedCostUSD = usage.estimatedCostUSD,
        startedAt = startedAt,
        completedAt = Instant.now().toString(),
    )

    private fun deltaText(json: JSONObject): String? {
        // OpenAI streaming shape: choices[0].delta.content
        json.optJSONArray("choices")
            ?.optJSONObject(0)
            ?.optJSONObject("delta")
            ?.optString("content")
            ?.takeIf { it.isNotEmpty() }
            ?.let { return it }
        // Permissive fallbacks for relays that emit differently.
        json.optString("content").takeIf { it.isNotEmpty() }?.let { return it }
        json.optString("delta").takeIf { it.isNotEmpty() }?.let { return it }
        json.optString("text").takeIf { it.isNotEmpty() }?.let { return it }
        return null
    }

    @Suppress("UNUSED_PARAMETER")
    private fun BufferedSource.readSSEPayload(line: String): String? {
        // Reserved for future multi-line SSE event handling (data: chunks
        // split across lines). The current relay implementations emit
        // single-line payloads so the streaming loop reads them directly.
        return null
    }

    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            // No read timeout on streams — SSE chunks may be silent for
            // long stretches when the upstream model is reasoning.
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }
}
