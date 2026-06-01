package com.openburnbar.data.hermes

import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject

private const val BURNBAR_GATEWAY_PORT = 8317
private const val TOOL_ARGUMENT_PREVIEW_CHARS = 200

internal class PiServiceRuntimeSupport(
    private val client: OkHttpClient,
    private val selectedConnection: () -> PiConnectionRecord,
    private val modelOptions: MutableStateFlow<List<HermesRuntimeModelOption>>,
    private val selectedModelID: MutableStateFlow<String?>,
    private val isReachable: MutableStateFlow<Boolean>,
    private val runtimeError: (String?) -> Unit,
) {
    suspend fun refreshRuntime() {
        runtimeError(null)
        probeReachability()
        if (isReachable.value) loadModels()
    }

    suspend fun probeReachability() {
        val base = resolvedBaseURL() ?: return
        val request =
            Request.Builder()
                .url("$base/v1/models")
                .get()
                .build()
        runCatching {
            client.newCall(request).execute().use { response: Response ->
                isReachable.value = response.isSuccessful
                if (!response.isSuccessful) {
                    runtimeError("Pi gateway returned HTTP ${response.code}.")
                }
            }
        }.onFailure {
            isReachable.value = false
            runtimeError("Pi gateway not reachable: ${it.message ?: "unknown error"}")
        }
    }

    suspend fun loadModels() {
        val base = resolvedBaseURL() ?: return
        val request =
            Request.Builder()
                .url("$base/v1/models")
                .get()
                .build()
        runCatching {
            client.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                val options = mergeModelOptions(parseModelsResponse(body), fetchBurnBarGatewayModels(base))
                modelOptions.value = options
                if (selectedModelID.value == null) {
                    selectedModelID.value = options.firstOrNull()?.modelID
                }
            }
        }.onFailure { runtimeError("Failed to list Pi models: ${it.message ?: ""}") }
    }

    fun endpointForModel(endpoint: String, modelID: String): String {
        val isProxyModel =
            modelOptions.value.any {
                it.modelID.equals(modelID, ignoreCase = true) && it.sourceKind == "openburnbar_proxy"
            }
        return if (isProxyModel) burnBarGatewayEndpoint(endpoint) ?: endpoint else endpoint
    }

    private fun fetchBurnBarGatewayModels(endpoint: String): List<HermesRuntimeModelOption> {
        val url =
            endpoint.toHttpUrlOrNull()
                ?.newBuilder()
                ?.port(BURNBAR_GATEWAY_PORT)
                ?.encodedPath("/v1/models")
                ?.query(null)
                ?.fragment(null)
                ?.build()
                ?: return emptyList()
        return runCatching {
            val request = Request.Builder().url(url).get().build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@runCatching emptyList()
                parseModelsResponse(response.body?.string().orEmpty()).map { it.copy(sourceKind = "openburnbar_proxy") }
            }
        }.getOrElse { emptyList() }
    }

    private fun parseModelsResponse(body: String): List<HermesRuntimeModelOption> {
        val json = JSONObject(body)
        val data = json.optJSONArray("data") ?: JSONArray()
        val options = mutableListOf<HermesRuntimeModelOption>()
        for (i in 0 until data.length()) {
            val entry = data.getJSONObject(i)
            val id = entry.optString("id")
            if (id.isNullOrEmpty()) continue
            val provider =
                entry.optString("provider_id").takeIf { it.isNotBlank() }
                    ?: entry.optString("owned_by", "pi")
            val providerName =
                entry.optString("provider_name").takeIf { it.isNotBlank() }
                    ?: provider.replaceFirstChar { it.titlecase() }
            options +=
                HermesRuntimeModelOption(
                    providerID = provider,
                    providerName = providerName,
                    modelID = id,
                    displayName = entry.optString("display_name", id).takeIf { it.isNotBlank() } ?: id,
                    sourceKind = entry.optString("source_kind").takeIf { it.isNotBlank() },
                )
        }
        return options
    }

    fun resolvedBaseURL(): String? {
        val configured = selectedConnection().endpointURL?.trim().orEmpty()
        if (configured.isEmpty()) return "http://127.0.0.1:8765"
        return configured.removeSuffix("/")
    }

    private fun mergeModelOptions(primary: List<HermesRuntimeModelOption>, secondary: List<HermesRuntimeModelOption>): List<HermesRuntimeModelOption> {
        val seen = linkedSetOf<String>()
        return (primary + secondary).filter { seen.add(it.modelID.lowercase()) }
    }

    private fun burnBarGatewayEndpoint(endpoint: String): String? = endpoint.toHttpUrlOrNull()
        ?.newBuilder()
        ?.port(BURNBAR_GATEWAY_PORT)
        ?.encodedPath("/")
        ?.query(null)
        ?.fragment(null)
        ?.build()
        ?.toString()
        ?.trimEnd('/')
}
