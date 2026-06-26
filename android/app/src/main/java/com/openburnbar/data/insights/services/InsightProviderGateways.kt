package com.openburnbar.data.insights.services

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTokenUsage
import java.io.IOException
import java.security.GeneralSecurityException
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

private const val READ_TIMEOUT_SECONDS = 120
private const val CONNECT_TIMEOUT_SECONDS = 15
private const val ANALYSIS_TEMPERATURE = 0.2
private const val ANALYSIS_MAX_TOKENS = 1400
private const val INSIGHT_PROVIDER_LEGACY_PREFS = "insights_provider_credentials"
private const val INSIGHT_PROVIDER_ENCRYPTED_PREFS = "insights_provider_credentials_encrypted"
private const val INSIGHT_CREDENTIAL_PREFIX = "credential."
private const val INSIGHT_ENDPOINT_PREFIX = "endpoint."

class AndroidInsightCredentialStore internal constructor(
    private val credentials: AndroidInsightStringStorage,
    private val endpoints: AndroidInsightStringStorage,
    private val legacyCredentials: AndroidInsightStringStorage?,
) {
    constructor(context: Context) : this(
        credentials =
        EncryptedAndroidInsightStringStorage(
            context = context.applicationContext,
            prefsName = INSIGHT_PROVIDER_ENCRYPTED_PREFS,
        ),
        endpoints =
        SharedPreferencesAndroidInsightStringStorage(
            context.applicationContext.getSharedPreferences(INSIGHT_PROVIDER_LEGACY_PREFS, Context.MODE_PRIVATE),
        ),
        legacyCredentials =
        SharedPreferencesAndroidInsightStringStorage(
            context.applicationContext.getSharedPreferences(INSIGHT_PROVIDER_LEGACY_PREFS, Context.MODE_PRIVATE),
        ),
    )

    init {
        migrateLegacyCredentials()
    }

    fun credential(provider: String, aliases: List<String> = emptyList()): String? = (listOf(provider) + aliases)
        .firstNotNullOfOrNull { candidate ->
            credentials.getString(credentialKey(candidate))
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
        }

    fun endpoint(key: String): String? = endpoints.getString(endpointKey(key))
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

    fun saveCredential(provider: String, credential: String) {
        val key = credentialKey(provider)
        val normalized = credential.trim()
        if (normalized.isEmpty()) {
            credentials.remove(key)
            legacyCredentials?.remove(key)
            return
        }
        check(credentials.putString(key, normalized)) { "Unable to persist insight provider credential securely." }
        legacyCredentials?.remove(key)
    }

    fun saveEndpoint(key: String, endpoint: String) {
        val storageKey = endpointKey(key)
        val normalized = endpoint.trim()
        if (normalized.isEmpty()) {
            endpoints.remove(storageKey)
            return
        }
        check(endpoints.putString(storageKey, normalized)) { "Unable to persist insight provider endpoint." }
    }

    private fun migrateLegacyCredentials() {
        val legacy = legacyCredentials ?: return
        legacy.keys()
            .filter { it.startsWith(INSIGHT_CREDENTIAL_PREFIX) }
            .forEach { key ->
                val currentEncrypted = credentials.getString(key)?.trim()?.takeIf { it.isNotEmpty() }
                if (currentEncrypted != null) {
                    legacy.remove(key)
                    return@forEach
                }
                val normalized = legacy.getString(key)?.trim()
                if (normalized.isNullOrEmpty()) {
                    legacy.remove(key)
                    return@forEach
                }
                check(credentials.putString(key, normalized)) { "Unable to migrate insight provider credential securely." }
                legacy.remove(key)
            }
    }
}

private fun credentialKey(provider: String): String = INSIGHT_CREDENTIAL_PREFIX + provider

private fun endpointKey(key: String): String = INSIGHT_ENDPOINT_PREFIX + key

internal interface AndroidInsightStringStorage {
    fun getString(key: String): String?
    fun putString(key: String, value: String): Boolean
    fun remove(key: String): Boolean
    fun keys(): Set<String>
}

internal class SharedPreferencesAndroidInsightStringStorage(
    private val prefs: SharedPreferences,
) : AndroidInsightStringStorage {
    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String): Boolean = prefs.edit()
        .putString(key, value)
        .commit()

    override fun remove(key: String): Boolean = prefs.edit()
        .remove(key)
        .commit()

    override fun keys(): Set<String> = prefs.all.keys
}

internal class EncryptedAndroidInsightStringStorage(
    private val context: Context,
    private val prefsName: String,
) : AndroidInsightStringStorage {
    private val prefs: SharedPreferences by lazy { openEncryptedPrefs() }

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String): Boolean = prefs.edit()
        .putString(key, value)
        .commit()

    override fun remove(key: String): Boolean = prefs.edit()
        .remove(key)
        .commit()

    override fun keys(): Set<String> = prefs.all.keys

    private fun openEncryptedPrefs(): SharedPreferences {
        val masterKey =
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
        return try {
            createEncryptedPrefs(masterKey)
        } catch (_: GeneralSecurityException) {
            context.deleteSharedPreferences(prefsName)
            createEncryptedPrefs(masterKey)
        } catch (_: IOException) {
            context.deleteSharedPreferences(prefsName)
            createEncryptedPrefs(masterKey)
        }
    }

    private fun createEncryptedPrefs(masterKey: MasterKey): SharedPreferences = EncryptedSharedPreferences.create(
        context,
        prefsName,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
}

object AndroidInsightGatewayRegistry {
    /**
     * @param credentials credential store backing user-key gateways.
     * @param hermesProvider optional hook the caller uses to inject a
     *   live Hermes gateway when the user's relay is reachable. Mirrors
     *   the Swift `HermesProvider` closure on
     *   `InsightProviderGatewayRegistry.registerDefaultSwiftGateways`.
     *   Returning `null` means "Hermes not currently available" — the
     *   registry falls back to the legacy `credentials.endpoint("hermes")`
     *   path so existing relay-URL preferences keep working.
     */
    fun defaultGateways(
        credentials: AndroidInsightCredentialStore,
        hermesProvider: () -> InsightAnalysisModelGateway? = { null },
        hostedFallbackProvider: () -> InsightAnalysisModelGateway? = { AndroidBurnBarHostedInsightGateway() },
    ): List<InsightAnalysisModelGateway> {
        val gateways = mutableListOf<InsightAnalysisModelGateway>(OllamaInsightAnalysisGateway())
        val injectedHermes = hermesProvider()
        if (injectedHermes != null) {
            gateways += injectedHermes
        }
        // BurnBar-hosted fallback is always registered when the
        // provider returns one. The orchestrator only routes to it
        // when no user-owned route succeeds.
        hostedFallbackProvider()?.let { gateways += it }
        registerCredentialBackedInsightGateways(credentials, gateways, injectedHermes)
        return gateways
    }
}

class OpenAICompatibleInsightAnalysisGateway(
    override val providerKey: String,
    override val displayName: String,
    private val apiKey: String?,
    private val baseURL: String,
    private val path: String = "/v1/chat/completions",
    override val models: List<InsightModelTag>,
    private val client: OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_SECONDS.toLong(), TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_SECONDS.toLong(), TimeUnit.SECONDS)
            .build(),
    private val maxTokens: Int = 1400,
) : InsightAnalysisModelGateway {
    override suspend fun analyze(request: InsightAnalysisRequest) = withContext(Dispatchers.IO) {
        val startedAt = Instant.now().toString()
        val body =
            JSONObject().apply {
                put("model", request.selectedModel.modelID)
                put("temperature", ANALYSIS_TEMPERATURE)
                put("max_tokens", maxTokens)
                put("response_format", JSONObject().put("type", "json_object"))
                put(
                    "messages",
                    JSONArray().apply {
                        put(JSONObject().put("role", "system").put("content", analysisSystemPrompt(request)))
                        put(JSONObject().put("role", "user").put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request)))
                    },
                )
            }
        val builder =
            Request.Builder()
                .url(baseURL.trimEnd('/') + "/" + path.trimStart('/'))
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .addHeader("Content-Type", "application/json")
        apiKey?.trim()?.takeIf { it.isNotEmpty() }?.let { builder.addHeader("Authorization", "Bearer $it") }
        client.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) error("$displayName returned HTTP ${response.code}")
            val raw = response.body?.string().orEmpty()
            val root = JSONObject(raw)
            val content =
                root.optJSONArray("choices")
                    ?.optJSONObject(0)
                    ?.optJSONObject("message")
                    ?.optString("content")
                    ?: root.optString("content", raw)
            val usageRoot = root.optJSONObject("usage")
            val inputTokens =
                if (usageRoot != null) {
                    usageRoot.optInt("prompt_tokens", usageRoot.optInt("input_tokens", 0))
                } else {
                    0
                }
            val outputTokens =
                if (usageRoot != null) {
                    usageRoot.optInt("completion_tokens", usageRoot.optInt("output_tokens", 0))
                } else {
                    0
                }
            val usage =
                InsightTokenUsage(
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
    override val models: List<InsightModelTag> =
        listOf(
            InsightModelTag("anthropic", "claude-sonnet-4-6", "Claude Sonnet 4.6", InsightEgressTier.USER_KEY, Instant.now().toString()),
            InsightModelTag("anthropic", "claude-haiku-4-5", "Claude Haiku 4.5", InsightEgressTier.USER_KEY, Instant.now().toString()),
        ),
    private val client: OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_SECONDS.toLong(), TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_SECONDS.toLong(), TimeUnit.SECONDS)
            .build(),
) : InsightAnalysisModelGateway {
    override val providerKey: String = "anthropic"
    override val displayName: String = "Claude"

    override suspend fun analyze(request: InsightAnalysisRequest) = withContext(Dispatchers.IO) {
        val startedAt = Instant.now().toString()
        val body =
            JSONObject().apply {
                put("model", request.selectedModel.modelID)
                put("max_tokens", ANALYSIS_MAX_TOKENS)
                put("temperature", ANALYSIS_TEMPERATURE)
                put("system", analysisSystemPrompt(request))
                put(
                    "messages",
                    JSONArray().put(
                        JSONObject()
                            .put("role", "user")
                            .put("content", Json.encodeToString(InsightAnalysisRequest.serializer(), request)),
                    ),
                )
            }
        val httpRequest =
            Request.Builder()
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
            val content =
                root.optJSONArray("content")
                    ?.let { arr -> (0 until arr.length()).joinToString("") { arr.optJSONObject(it)?.optString("text").orEmpty() } }
                    ?: raw
            val usageRoot = root.optJSONObject("usage")
            val usage =
                InsightTokenUsage(
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

internal fun analysisSystemPrompt(request: InsightAnalysisRequest): String = """
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
