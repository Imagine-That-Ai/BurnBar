package com.openburnbar.data.hermes

import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject

private const val BURNBAR_GATEWAY_PORT = 8317

internal class HermesRuntimeModelState(
    val availableModels: MutableStateFlow<List<String>>,
    val modelOptions: MutableStateFlow<List<HermesRuntimeModelOption>>,
    val selectedModelID: MutableStateFlow<String?>,
)

internal class HermesRuntimeProbeState(
    val runtimeInfo: MutableStateFlow<Map<String, String>>,
    val isReachable: MutableStateFlow<Boolean>,
    val isConnected: MutableStateFlow<Boolean>,
    val runtimeErrorText: MutableStateFlow<String?>,
    val isLoadingRuntime: MutableStateFlow<Boolean>,
    val connections: MutableStateFlow<List<HermesConnectionRecord>>,
    val selectedConnectionFlow: MutableStateFlow<HermesConnectionRecord>,
)

internal class HermesServiceRuntimeSupport(
    private val client: OkHttpClient,
    private val selectedConnection: () -> HermesConnectionRecord,
    private val modelState: HermesRuntimeModelState,
    private val probeState: HermesRuntimeProbeState,
) {
    @Suppress("InstanceOfCheckForException", "TooGenericExceptionCaught")
    // Coroutine-safe catch: CancellationException must propagate; a split catch would trip RethrowCaughtException.
    suspend fun probeSelectedRuntime(endpointOverride: String? = null) {
        val selected = selectedConnection()

        if (selected.mode == HermesConnectionMode.RELAY_LINK && endpointOverride == null) {
            applyRelayRuntimeSnapshot(selected)
            return
        }

        val endpoint = endpointOverride ?: HermesServiceEndpointSupport.selectedEndpointURL(selected)
        if (endpoint == null) {
            val error = "Android does not have an HTTP Hermes endpoint for ${selected.displayName}."
            applyOfflineRuntimeState(selected, error)
            return
        }

        probeState.isLoadingRuntime.value = true
        probeState.runtimeErrorText.value = null
        updateConnectionStatus(selected, HermesConnectionStatus.PENDING)
        try {
            val healthInfo = fetchHealth(endpoint)
            val models = mergeModelOptions(fetchModels(endpoint), fetchBurnBarGatewayModels(endpoint))
            val modelIDs =
                models.map { it.modelID }.ifEmpty {
                    healthInfo["model"]?.let { listOf(it) }.orEmpty()
                }
            probeState.runtimeInfo.value = healthInfo + mapOf("endpoint" to endpoint)
            modelState.availableModels.value = modelIDs
            modelState.modelOptions.value =
                models.ifEmpty {
                    modelIDs.map { id ->
                        HermesRuntimeModelOption(
                            providerID = "hermes",
                            providerName = "Hermes",
                            modelID = id,
                            displayName = id,
                        )
                    }
                }
            if (modelState.selectedModelID.value == null) {
                modelState.selectedModelID.value = modelIDs.firstOrNull()
            }
            probeState.isReachable.value = true
            probeState.isConnected.value = true
            updateConnectionStatus(
                selected,
                HermesConnectionStatus.ONLINE,
                advertisedModel = modelIDs.firstOrNull(),
                capabilities = listOf("health", "models", "chat_completions"),
            )
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            applyOfflineRuntimeState(selected, runtimeProbeError(e), endpoint = endpoint)
        } finally {
            probeState.isLoadingRuntime.value = false
        }
    }

    fun endpointForModel(endpoint: String, modelID: String): String {
        val isProxyModel =
            modelState.modelOptions.value.any {
                it.modelID.equals(modelID, ignoreCase = true) && it.sourceKind == "openburnbar_proxy"
            }
        return if (isProxyModel) burnBarGatewayEndpoint(endpoint) ?: endpoint else endpoint
    }

    fun modelCapabilitiesFor(modelID: String): ModelIOCapabilities? {
        return modelState.modelOptions.value.firstOrNull {
            it.modelID.equals(modelID, ignoreCase = true)
        }?.modelCapabilities
    }

    private fun applyRelayRuntimeSnapshot(selected: HermesConnectionRecord) {
        probeState.runtimeErrorText.value = null
        probeState.isLoadingRuntime.value = false
        probeState.isReachable.value = true
        probeState.isConnected.value = true
        val advertised = selected.advertisedModel
        modelState.availableModels.value = listOfNotNull(advertised)
        modelState.modelOptions.value =
            listOfNotNull(advertised).map { id ->
                HermesRuntimeModelOption(
                    providerID = "hermes",
                    providerName = "Hermes",
                    modelID = id,
                    displayName = id,
                )
            }
        if (modelState.selectedModelID.value == null) modelState.selectedModelID.value = advertised
        probeState.runtimeInfo.value =
            mapOf(
                "transport" to "encrypted-relay",
                "encryption" to (selected.relayEncryption ?: HermesRelayCrypto.ALGORITHM),
            )
        updateConnectionStatus(
            selected,
            HermesConnectionStatus.ONLINE,
            advertisedModel = advertised,
            capabilities = selected.capabilities.ifEmpty { listOf("relay", "chat_completions") },
        )
    }

    private fun applyOfflineRuntimeState(
        selected: HermesConnectionRecord,
        error: String,
        endpoint: String? = null,
    ) {
        probeState.runtimeErrorText.value = error
        probeState.isReachable.value = false
        probeState.isConnected.value = false
        if (endpoint != null) {
            probeState.runtimeInfo.value = probeState.runtimeInfo.value + ("endpoint" to endpoint)
        }
        updateConnectionStatus(selected, HermesConnectionStatus.OFFLINE, error = error)
    }

    private fun runtimeProbeError(error: Throwable): String =
        error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName

    private fun fetchHealth(endpoint: String): Map<String, String> {
        val request = Request.Builder().url("$endpoint/health").get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return emptyMap()
            val body = response.body?.string()?.takeIf { it.isNotBlank() } ?: return emptyMap()
            val json = JSONObject(body)
            val info = mutableMapOf<String, String>()
            json.keys().forEach { key ->
                val value = json.opt(key)
                if (value != null) info[key] = value.toString()
            }
            return info
        }
    }

    private fun fetchModels(endpoint: String): List<HermesRuntimeModelOption> {
        val request = Request.Builder().url("$endpoint/v1/models").get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                error("Hermes models probe failed: HTTP ${response.code}")
            }
            val body =
                response.body?.string()?.takeIf { it.isNotBlank() }
                    ?: error("Hermes models probe returned an empty body.")
            val json = JSONObject(body)
            val data = json.optJSONArray("data") ?: JSONArray()
            return (0 until data.length()).mapNotNull { index ->
                val item = data.optJSONObject(index) ?: return@mapNotNull null
                val id = item.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                val owner = item.optString("owned_by", "hermes").takeIf { it.isNotBlank() } ?: "hermes"
                HermesRuntimeModelOption(
                    providerID = owner,
                    providerName = owner.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() },
                    modelID = id,
                    displayName = item.optString("display_name", id).takeIf { it.isNotBlank() } ?: id,
                    sourceKind = item.optString("source_kind").takeIf { it.isNotBlank() },
                    modelCapabilities = HermesModelCapabilitiesParser.parseModelCapabilities(item),
                )
            }
        }
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
                val body = response.body?.string()?.takeIf { it.isNotBlank() } ?: return@runCatching emptyList()
                HermesProtocol.parseModelsResponse(body).map { it.copy(sourceKind = "openburnbar_proxy") }
            }
        }.getOrElse { emptyList() }
    }

    private fun burnBarGatewayEndpoint(endpoint: String): String? {
        return endpoint.toHttpUrlOrNull()
            ?.newBuilder()
            ?.port(BURNBAR_GATEWAY_PORT)
            ?.encodedPath("/")
            ?.query(null)
            ?.fragment(null)
            ?.build()
            ?.toString()
            ?.trimEnd('/')
    }

    private fun mergeModelOptions(
        primary: List<HermesRuntimeModelOption>,
        secondary: List<HermesRuntimeModelOption>,
    ): List<HermesRuntimeModelOption> {
        val seen = linkedSetOf<String>()
        return (primary + secondary).filter { seen.add(it.modelID.lowercase()) }
    }

    private fun updateConnectionStatus(
        connection: HermesConnectionRecord,
        status: HermesConnectionStatus,
        advertisedModel: String? = null,
        capabilities: List<String>? = null,
        error: String? = null,
    ) {
        val now = System.currentTimeMillis()
        val updated =
            connection.copy(
                status = status,
                advertisedModel = advertisedModel ?: connection.advertisedModel,
                capabilities = capabilities ?: connection.capabilities,
                updatedAt = now,
                lastSeenAt = if (status == HermesConnectionStatus.ONLINE) now else connection.lastSeenAt,
            )
        probeState.connections.value = probeState.connections.value.map { if (it.id == updated.id) updated else it }
        if (probeState.selectedConnectionFlow.value.id == updated.id) {
            probeState.selectedConnectionFlow.value = updated
        }
        if (error != null) {
            probeState.runtimeInfo.value = probeState.runtimeInfo.value + ("last_error" to error)
        }
    }
}

internal object HermesModelCapabilitiesParser {
    fun parseModelCapabilities(item: JSONObject): ModelIOCapabilities? {
        val capabilities =
            item.optJSONObject("model_capabilities")
                ?: item.optJSONObject("modelCapabilities")
                ?: return null
        return ModelIOCapabilities(
            schemaVersion = capabilities.optInt("schemaVersion", 1).coerceAtLeast(1),
            inputModalities = capabilities.optStringArray("inputModalities").ifEmpty { listOf("text") },
            outputModalities = capabilities.optStringArray("outputModalities").ifEmpty { listOf("text") },
            supportedParameters = capabilities.optStringArray("supportedParameters"),
            contextWindowTokens = capabilities.optPositiveInt("contextWindowTokens"),
            maxOutputTokens = capabilities.optPositiveInt("maxOutputTokens"),
            acceptedInputMimeTypes = capabilities.optStringArray("acceptedInputMimeTypes"),
            imageMaxBytes = capabilities.optPositiveInt("imageMaxBytes"),
            audioMaxBytes = capabilities.optPositiveInt("audioMaxBytes"),
            videoMaxBytes = capabilities.optPositiveInt("videoMaxBytes"),
        )
    }

    private fun JSONObject.optStringArray(name: String): List<String> {
        val array = optJSONArray(name) ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            array.optString(index).trim().takeIf { it.isNotBlank() }
        }
    }

    private fun JSONObject.optPositiveInt(name: String): Int? {
        if (!has(name)) return null
        val value = optInt(name, 0)
        return value.takeIf { it > 0 }
    }
}
