package com.openburnbar.ui.chartstudio

import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/**
 * Streaming bridge between Chart Studio and the user's Hermes endpoint.
 * Mirrors the iOS `ChartStudioHermesBridge` semantically — sends the user's
 * prompt + a system prompt to the OpenAI-shaped `/v1/chat/completions`
 * endpoint with `stream: true`, parses SSE `data:` frames into either
 * Partial-content events (each token batch as it streams in) or a final
 * Completed event (full accumulated text). Errors land as Failed.
 *
 * Uses OkHttp's blocking Response reader inside a Dispatcher.IO flow so we
 * never touch the main thread.
 */
class ChartStudioHermesBridge(
    private val client: OkHttpClient = defaultClient,
    private val connection: HermesConnectionRecord
) {
    sealed class Event {
        data class Partial(val text: String) : Event()
        data class Completed(val text: String) : Event()
        data class Failed(val message: String) : Event()
    }

    /**
     * Stream a single Chart Studio turn. Emits `Partial` events as `delta.content`
     * tokens arrive, then exactly one `Completed` with the accumulated text on
     * success — or `Failed` if anything goes wrong (network, parse, HTTP code).
     */
    fun stream(
        systemPrompt: String,
        userPrompt: String,
        model: String = "hermes",
        temperature: Double = 0.2
    ): Flow<Event> = flow {
        val endpoint = resolveEndpointURL()
            ?: run {
                emit(Event.Failed("No Hermes endpoint configured. Connect Hermes in Settings."))
                return@flow
            }

        val body = JSONObject().apply {
            put("model", model)
            put("temperature", temperature)
            put("stream", true)
            put("response_format", JSONObject().put("type", "json_object"))
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "system")
                    put("content", systemPrompt)
                })
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", userPrompt)
                })
            })
        }

        val request = Request.Builder()
            .url("$endpoint/v1/chat/completions")
            .header("Accept", "text/event-stream")
            .header("Content-Type", "application/json")
            .apply { bearerToken()?.let { header("Authorization", "Bearer $it") } }
            .post(body.toString().toRequestBody(JSON))
            .build()

        val accumulated = StringBuilder()
        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    emit(Event.Failed("Hermes returned ${response.code} ${response.message}"))
                    return@use
                }
                val source = response.body?.source()
                    ?: run {
                        emit(Event.Failed("Hermes response had no body."))
                        return@use
                    }

                while (!source.exhausted()) {
                    val line = source.readUtf8Line() ?: break
                    if (line.isEmpty()) continue
                    if (!line.startsWith("data:")) continue
                    val payload = line.removePrefix("data:").trim()
                    if (payload == "[DONE]") break
                    val delta = parseDelta(payload) ?: continue
                    if (delta.isEmpty()) continue
                    accumulated.append(delta)
                    emit(Event.Partial(accumulated.toString()))
                }
                emit(Event.Completed(accumulated.toString()))
            }
        } catch (t: Throwable) {
            emit(Event.Failed(t.message ?: "Stream interrupted."))
        }
    }.flowOn(Dispatchers.IO)

    // ── Endpoint resolution ─────────────────────────────────────────────────

    /**
     * Resolve the endpoint origin (`http://host:port` — no trailing path) from
     * the selected `HermesConnectionRecord`. Defaults to localhost:8642 to
     * match the iOS LAN default when no record specifies an URL.
     */
    private fun resolveEndpointURL(): String? {
        val raw = connection.endpointURL?.trim()?.takeIf { it.isNotBlank() }
            ?: return when (connection.mode) {
                HermesConnectionMode.LOCAL -> "http://127.0.0.1:8642"
                else -> null
            }
        // Strip trailing slashes / `/v1/...` paths so we can append cleanly.
        return raw.trimEnd('/').substringBefore("/v1")
    }

    private fun bearerToken(): String? = null  // Wire when Relay-mode secret store ships.

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()

        private val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(120, TimeUnit.SECONDS)
                .build()
        }

        /**
         * Parse the OpenAI-shaped streaming chunk to extract the new tokens in
         * `choices[0].delta.content`. Returns null if the chunk is shaped
         * unexpectedly (we silently skip rather than fail the whole stream).
         */
        private fun parseDelta(payload: String): String? {
            return try {
                val obj = JSONObject(payload)
                val choices = obj.optJSONArray("choices") ?: return null
                if (choices.length() == 0) return null
                val delta = choices.getJSONObject(0).optJSONObject("delta")
                    ?: choices.getJSONObject(0).optJSONObject("message")
                    ?: return null
                delta.optString("content").takeIf { it.isNotEmpty() }
            } catch (_: Throwable) {
                null
            }
        }
    }
}
