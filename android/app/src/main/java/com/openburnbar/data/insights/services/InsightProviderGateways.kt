package com.openburnbar.data.insights.services

import android.content.Context
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTokenUsage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.TimeUnit

class AndroidInsightCredentialStore(context: Context) {
    private val prefs = context.getSharedPreferences("insights_provider_credentials", Context.MODE_PRIVATE)

    fun credential(provider: String, aliases: List<String> = emptyList()): String? =
        (listOf(provider) + aliases)
            .firstNotNullOfOrNull { candidate ->
                prefs.getString("credential.$candidate", null)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
            }

    fun endpoint(key: String): String? =
        prefs.getString("endpoint.$key", null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

    fun saveCredential(provider: String, credential: String) {
        prefs.edit().putString("credential.$provider", credential.trim()).apply()
    }

    fun saveEndpoint(key: String, endpoint: String) {
        prefs.edit().putString("endpoint.$key", endpoint.trim()).apply()
    }
}

object AndroidInsightGatewayRegistry {
    fun defaultGateways(credentials: AndroidInsightCredentialStore): List<InsightAnalysisModelGateway> {
        val gateways = mutableListOf<InsightAnalysisModelGateway>(OllamaInsightAnalysisGateway())
        credentials.credential("openai")?.let { key ->
            gateways += OpenAICompatibleInsightAnalysisGateway(
                providerKey = "openai",
                displayName = "OpenAI / Codex",
                apiKey = key,
                baseURL = credentials.endpoint("openai") ?: "https://api.openai.com",
                models = listOf(
                    tag("openai", "gpt-5.5", "Codex / GPT-5.5"),
                    tag("openai", "gpt-5.4", "Codex / GPT-5.4"),
                    tag("openai", "gpt-4.1", "GPT-4.1"),
                )
            )
        }
        credentials.credential("anthropic", listOf("claude"))?.let { key ->
            gateways += AnthropicInsightAnalysisGateway(apiKey = key)
        }
        credentials.credential("minimax")?.let { key ->
            gateways += OpenAICompatibleInsightAnalysisGateway(
                providerKey = "minimax",
                displayName = "MiniMax",
                apiKey = key,
                baseURL = credentials.endpoint("minimax") ?: "https://api.minimax.io",
                models = listOf(tag("minimax", "minimax-m1", "MiniMax M1"))
            )
        }
        credentials.credential("zai", listOf("z.ai", "zhipu"))?.let { key ->
            gateways += OpenAICompatibleInsightAnalysisGateway(
                providerKey = "zai",
                displayName = "Z.ai",
                apiKey = key,
                baseURL = credentials.endpoint("zai") ?: "https://open.bigmodel.cn",
                path = "/api/paas/v4/chat/completions",
                models = listOf(tag("zai", "glm-4.6", "GLM 4.6"))
            )
        }
        credentials.credential("kimi", listOf("moonshot"))?.let { key ->
            gateways += OpenAICompatibleInsightAnalysisGateway(
                providerKey = "kimi",
                displayName = "Kimi",
                apiKey = key,
                baseURL = credentials.endpoint("kimi") ?: "https://api.moonshot.ai",
                models = listOf(tag("kimi", "kimi-k2", "Kimi K2"))
            )
        }
        credentials.endpoint("hermes")?.let { endpoint ->
            gateways += OpenAICompatibleInsightAnalysisGateway(
                providerKey = "hermes",
                displayName = "Hermes",
                apiKey = credentials.credential("hermes"),
                baseURL = endpoint,
                models = listOf(tag("hermes", "hermes-agent", "Hermes gateway", InsightEgressTier.USER_RELAY))
            )
        }
        return gateways
    }

    private fun tag(
        providerKey: String,
        modelID: String,
        displayName: String,
        egressTier: InsightEgressTier = InsightEgressTier.USER_KEY,
    ) = InsightModelTag(
        providerKey = providerKey,
        modelID = modelID,
        displayName = displayName,
        egressTier = egressTier,
        stampedAt = Instant.now().toString(),
    )
}

class OpenAICompatibleInsightAnalysisGateway(
    override val providerKey: String,
    override val displayName: String,
    private val apiKey: String?,
    private val baseURL: String,
    private val path: String = "/v1/chat/completions",
    override val models: List<InsightModelTag>,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build(),
    private val maxTokens: Int = 1400,
) : InsightAnalysisModelGateway {
    override suspend fun analyze(request: InsightAnalysisRequest) = withContext(Dispatchers.IO) {
        val startedAt = Instant.now().toString()
        val body = JSONObject().apply {
            put("model", request.selectedModel.modelID)
            put("temperature", 0.2)
            put("max_tokens", maxTokens)
            put("response_format", JSONObject().put("type", "json_object"))
            put("messages", JSONArray().apply {
                put(JSONObject().put("role", "system").put("content", analysisSystemPrompt(request)))
                put(JSONObject().put("role", "user").put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request)))
            })
        }
        val builder = Request.Builder()
            .url(baseURL.trimEnd('/') + "/" + path.trimStart('/'))
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .addHeader("Content-Type", "application/json")
        apiKey?.trim()?.takeIf { it.isNotEmpty() }?.let { builder.addHeader("Authorization", "Bearer $it") }
        client.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) error("$displayName returned HTTP ${response.code}")
            val raw = response.body?.string().orEmpty()
            val root = JSONObject(raw)
            val content = root.optJSONArray("choices")
                ?.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optString("content")
                ?: root.optString("content", raw)
            val usageRoot = root.optJSONObject("usage")
            val inputTokens = if (usageRoot != null) {
                usageRoot.optInt("prompt_tokens", usageRoot.optInt("input_tokens", 0))
            } else {
                0
            }
            val outputTokens = if (usageRoot != null) {
                usageRoot.optInt("completion_tokens", usageRoot.optInt("output_tokens", 0))
            } else {
                0
            }
            val usage = InsightTokenUsage(
                providerKey = providerKey,
                modelID = request.selectedModel.modelID,
                inputTokens = inputTokens,
                outputTokens = outputTokens,
                estimatedCostUSD = 0.0,
                startedAt = startedAt,
                completedAt = Instant.now().toString(),
            )
            InsightAnalysisResultJsonDecoder.decode(content, request, usage)
        }
    }
}

class AnthropicInsightAnalysisGateway(
    private val apiKey: String,
    private val baseURL: String = "https://api.anthropic.com",
    override val models: List<InsightModelTag> = listOf(
        InsightModelTag("anthropic", "claude-sonnet-4-6", "Claude Sonnet 4.6", InsightEgressTier.USER_KEY, Instant.now().toString()),
        InsightModelTag("anthropic", "claude-haiku-4-5", "Claude Haiku 4.5", InsightEgressTier.USER_KEY, Instant.now().toString()),
    ),
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build(),
) : InsightAnalysisModelGateway {
    override val providerKey: String = "anthropic"
    override val displayName: String = "Claude"

    override suspend fun analyze(request: InsightAnalysisRequest) = withContext(Dispatchers.IO) {
        val startedAt = Instant.now().toString()
        val body = JSONObject().apply {
            put("model", request.selectedModel.modelID)
            put("max_tokens", 1400)
            put("temperature", 0.2)
            put("system", analysisSystemPrompt(request))
            put("messages", JSONArray().put(JSONObject()
                .put("role", "user")
                .put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request))))
        }
        val httpRequest = Request.Builder()
            .url(baseURL.trimEnd('/') + "/v1/messages")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .addHeader("x-api-key", apiKey)
            .addHeader("anthropic-version", "2023-06-01")
            .addHeader("Content-Type", "application/json")
            .build()
        client.newCall(httpRequest).execute().use { response ->
            if (!response.isSuccessful) error("Claude returned HTTP ${response.code}")
            val raw = response.body?.string().orEmpty()
            val root = JSONObject(raw)
            val content = root.optJSONArray("content")
                ?.let { arr -> (0 until arr.length()).joinToString("") { arr.optJSONObject(it)?.optString("text").orEmpty() } }
                ?: raw
            val usageRoot = root.optJSONObject("usage")
            val usage = InsightTokenUsage(
                providerKey = providerKey,
                modelID = request.selectedModel.modelID,
                inputTokens = usageRoot?.optInt("input_tokens", 0) ?: 0,
                outputTokens = usageRoot?.optInt("output_tokens", 0) ?: 0,
                estimatedCostUSD = 0.0,
                startedAt = startedAt,
                completedAt = Instant.now().toString(),
            )
            InsightAnalysisResultJsonDecoder.decode(content, request, usage)
        }
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
    Return missionCandidates separately from findings and recommendations. Missions must be concrete work packages, not duplicate insight prose.
    Use accretion, diligence, techDebt, routing, quota, and focus lenses to propose greater-purpose missions from the evidence.
    Return keys: executiveSummary, findings, anomalies, recommendations, missionCandidates, generatedWidgets, followUpQuestions, citations.
    Generated widgets must use known widget kinds and must include citations. Max generated widgets: ${request.maxGeneratedWidgets}.
    """.trimIndent()
