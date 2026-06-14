package com.openburnbar.ui.chartstudio

import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

private val BEARER_TOKEN: String? = null

private val JSON = "application/json; charset=utf-8".toMediaType()

internal fun ChartStudioHermesBridge.streamEvents(
    systemPrompt: String,
    userPrompt: String,
    model: String = "hermes",
    temperature: Double = 0.2,
): Flow<ChartStudioHermesBridge.Event> = flow {
    val endpoint =
        resolveEndpointURL(connection)
            ?: run {
                emit(ChartStudioHermesBridge.Event.Failed("No Hermes endpoint configured. Connect Hermes in Settings."))
                return@flow
            }

    val body = buildStreamRequestBody(systemPrompt, userPrompt, model, temperature)
    val request =
        Request.Builder()
            .url("$endpoint/v1/chat/completions")
            .header("Accept", "text/event-stream")
            .header("Content-Type", "application/json")
            .apply { BEARER_TOKEN?.let { header("Authorization", "Bearer $it") } }
            .post(body.toString().toRequestBody(JSON))
            .build()

    val accumulated = StringBuilder()
    try {
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                emit(ChartStudioHermesBridge.Event.Failed("Hermes returned ${response.code} ${response.message}"))
                return@use
            }
            val source =
                response.body?.source()
                    ?: run {
                        emit(ChartStudioHermesBridge.Event.Failed("Hermes response had no body."))
                        return@use
                    }

            while (!source.exhausted()) {
                val line = source.readUtf8Line()
                if (line != null && line.isNotEmpty() && line.startsWith("data:")) {
                    val payload = line.removePrefix("data:").trim()
                    if (payload == "[DONE]") break
                    val delta = parseStreamDelta(payload)
                    if (delta != null && delta.isNotEmpty()) {
                        accumulated.append(delta)
                        emit(ChartStudioHermesBridge.Event.Partial(accumulated.toString()))
                    }
                }
            }
            emit(ChartStudioHermesBridge.Event.Completed(accumulated.toString()))
        }
    } catch (t: IllegalStateException) {
        emit(ChartStudioHermesBridge.Event.Failed(t.message ?: "Stream interrupted."))
    }
}.flowOn(Dispatchers.IO)

private fun buildStreamRequestBody(systemPrompt: String, userPrompt: String, model: String, temperature: Double): JSONObject = JSONObject().apply {
    put("model", model)
    put("temperature", temperature)
    put("stream", true)
    put("response_format", JSONObject().put("type", "json_object"))
    put(
        "messages",
        JSONArray().apply {
            put(
                JSONObject().apply {
                    put("role", "system")
                    put("content", systemPrompt)
                },
            )
            put(
                JSONObject().apply {
                    put("role", "user")
                    put("content", userPrompt)
                },
            )
        },
    )
}

private fun ChartStudioHermesBridge.resolveEndpointURL(connection: HermesConnectionRecord): String? {
    val raw =
        connection.endpointURL?.trim()?.takeIf { it.isNotBlank() }
            ?: return when (connection.mode) {
                HermesConnectionMode.LOCAL -> "http://127.0.0.1:8642"
                else -> null
            }
    return raw.trimEnd('/').substringBefore("/v1")
}

private fun parseStreamDelta(payload: String): String? {
    return try {
        val obj = JSONObject(payload)
        val choices = obj.optJSONArray("choices") ?: return null
        if (choices.length() == 0) return null
        val delta =
            choices.getJSONObject(0).optJSONObject("delta")
                ?: choices.getJSONObject(0).optJSONObject("message")
                ?: return null
        delta.optString("content").takeIf { it.isNotEmpty() }
    } catch (_: Throwable) {
        null
    }
}
