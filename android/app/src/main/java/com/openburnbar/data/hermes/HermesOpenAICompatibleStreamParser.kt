package com.openburnbar.data.hermes

import com.openburnbar.irohrelay.HermesChatMessageOutcome as RelayOutcome
import com.openburnbar.irohrelay.HermesStreamEvent
import com.openburnbar.irohrelay.HermesTokenUsageStats as RelayUsageStats
import org.json.JSONArray
import org.json.JSONObject

internal data class HermesStreamParseResult(
    val events: List<HermesStreamEvent>,
    val done: Boolean = false,
    val streamedText: Boolean = false,
)

internal class HermesOpenAICompatibleStreamParser {
    private data class PendingToolCall(
        val id: String,
        val index: Int,
        val name: String,
        val arguments: String,
    )

    private val pendingToolCalls = mutableMapOf<Int, PendingToolCall>()

    fun eventsFromPayload(payload: String): HermesStreamParseResult {
        if (payload == "[DONE]") {
            return HermesStreamParseResult(events = flushPendingToolCalls(), done = true)
        }
        val json = runCatching { JSONObject(payload) }.getOrNull() ?: return HermesStreamParseResult(emptyList())
        return eventsFromJson(json)
    }

    fun eventsFromJson(json: JSONObject): HermesStreamParseResult {
        val events = mutableListOf<HermesStreamEvent>()
        var streamedText = false

        tokenUsageStats(json.optJSONObject("usage") ?: json)?.let { usage ->
            events += HermesStreamEvent.MessageStop(outcome = RelayOutcome.NORMAL, usage = usage)
        }

        errorMessage(json)?.let { error ->
            events += HermesStreamEvent.Notice(level = "error", text = error)
            return HermesStreamParseResult(events)
        }

        val choices = json.optJSONArray("choices")
        val choice = choices?.optJSONObject(0)
        if (choice == null) {
            val text =
                visibleContentValue(json.opt("content"))
                    ?: visibleContentValue(json.opt("output_text"))
                    ?: visibleContentValue(json.opt("text"))
            if (!text.isNullOrEmpty()) {
                events += HermesStreamEvent.MessageChunk(text)
                streamedText = true
            }
            return HermesStreamParseResult(events = events, streamedText = streamedText)
        }

        val delta = choice.optJSONObject("delta")
        val finalMessage = choice.optJSONObject("message")
        refusalContent(delta)?.takeIf { it.isNotEmpty() }?.let {
            events += HermesStreamEvent.RefusalChunk(it)
        }
        refusalContent(finalMessage)?.takeIf { it.isNotEmpty() }?.let {
            events += HermesStreamEvent.RefusalChunk(it)
        }
        reasoningContent(delta)?.takeIf { it.isNotEmpty() }?.let {
            events += HermesStreamEvent.ReasoningChunk(it)
        }
        reasoningContent(finalMessage)?.takeIf { it.isNotEmpty() }?.let {
            events += HermesStreamEvent.ReasoningChunk(it)
        }

        val toolCalls = toolCalls(delta) ?: toolCalls(finalMessage)
        if (toolCalls != null) {
            events += ingestToolCalls(toolCalls)
        }

        val text =
            visibleContent(delta)
                ?: visibleContent(finalMessage)
                ?: choice.optString("text").takeIf { it.isNotEmpty() }
        if (!text.isNullOrEmpty()) {
            events += flushPendingToolCalls()
            events += HermesStreamEvent.MessageChunk(text)
            streamedText = true
        }

        val finishReason =
            choice.optString("finish_reason").takeIf { it.isNotEmpty() }
                ?: choice.optString("finishReason").takeIf { it.isNotEmpty() }
        if (finishReason != null) {
            events += flushPendingToolCalls()
            events += HermesStreamEvent.MessageStop(finishReason = finishReason, outcome = RelayOutcome.NORMAL)
        }

        return HermesStreamParseResult(events = events, streamedText = streamedText)
    }

    private fun ingestToolCalls(rawToolCalls: JSONArray): List<HermesStreamEvent> {
        val events = mutableListOf<HermesStreamEvent>()
        for (i in 0 until rawToolCalls.length()) {
            val raw = rawToolCalls.optJSONObject(i) ?: continue
            val index = if (raw.has("index")) raw.optInt("index", 0).coerceAtLeast(0) else 0
            val function = raw.optJSONObject("function") ?: JSONObject()
            val id = raw.optString("id").takeIf { it.isNotEmpty() }
                ?: pendingToolCalls[index]?.id
                ?: "tool-index-$index"
            val nameFragment =
                function.optString("name").takeIf { it.isNotEmpty() }
                    ?: raw.optString("name").takeIf { it.isNotEmpty() }
            val argsFragment =
                function.optString("arguments").takeIf { it.isNotEmpty() }
                    ?: raw.optString("arguments").takeIf { it.isNotEmpty() }
                    ?: ""
            val name = nameFragment ?: pendingToolCalls[index]?.name ?: ""
            val arguments = (pendingToolCalls[index]?.arguments ?: "") + argsFragment
            pendingToolCalls[index] = PendingToolCall(id = id, index = index, name = name, arguments = arguments)
            events += HermesStreamEvent.ToolCallChunk(
                id = id,
                index = index,
                name = nameFragment,
                argumentsDelta = argsFragment,
            )
        }
        return events
    }

    private fun flushPendingToolCalls(): List<HermesStreamEvent> {
        if (pendingToolCalls.isEmpty()) return emptyList()
        val calls = pendingToolCalls.values.sortedBy { it.index }
        pendingToolCalls.clear()
        return calls.map { call ->
            HermesStreamEvent.ToolCallFinished(
                id = call.id,
                name = call.name.ifBlank { "tool" },
                arguments = call.arguments,
            )
        }
    }

    private fun tokenUsageStats(usage: JSONObject): RelayUsageStats? {
        val promptTokens =
            usage.optNullableInt("prompt_tokens")
                ?: usage.optNullableInt("promptTokens")
                ?: usage.optNullableInt("input_tokens")
                ?: usage.optNullableInt("inputTokens")
                ?: usage.optNullableInt("prompt_eval_count")
                ?: usage.optNullableInt("promptEvalCount")
        val outputTokens =
            usage.optNullableInt("completion_tokens")
                ?: usage.optNullableInt("completionTokens")
                ?: usage.optNullableInt("output_tokens")
                ?: usage.optNullableInt("outputTokens")
                ?: usage.optNullableInt("eval_count")
                ?: usage.optNullableInt("evalCount")
        val totalTokens =
            usage.optNullableInt("total_tokens")
                ?: usage.optNullableInt("totalTokens")
                ?: usage.optNullableInt("total_token_count")
                ?: usage.optNullableInt("totalTokenCount")
                ?: (promptTokens ?: 0).plus(outputTokens ?: 0).takeIf { it > 0 }
        val generationDuration =
            durationSecondsFromUsage(
                usage,
                listOf(
                    "eval_duration",
                    "evalDuration",
                    "generation_duration",
                    "generationDuration",
                    "completion_duration",
                    "completionDuration",
                    "output_duration",
                    "outputDuration",
                    "generation_time",
                    "generationTime",
                ),
            )
        val totalDuration =
            durationSecondsFromUsage(
                usage,
                listOf(
                    "total_duration",
                    "totalDuration",
                    "request_duration",
                    "requestDuration",
                    "elapsed_time",
                    "elapsedTime",
                    "duration",
                ),
            )
        if (promptTokens == null && outputTokens == null && totalTokens == null && generationDuration == null && totalDuration == null) {
            return null
        }
        return RelayUsageStats(
            promptTokens = promptTokens,
            outputTokens = outputTokens,
            totalTokens = totalTokens,
            generationDurationSeconds = generationDuration,
            totalDurationSeconds = totalDuration,
        )
    }

    private fun toolCalls(item: JSONObject?): JSONArray? {
        item ?: return null
        return item.optJSONArray("tool_calls")?.takeIf { it.length() > 0 }
            ?: item.optJSONArray("toolCalls")?.takeIf { it.length() > 0 }
            ?: item.optJSONObject("function_call")?.let { JSONArray().put(it) }
    }

    private fun visibleContent(item: JSONObject?): String? {
        item ?: return null
        return visibleContentValue(item.opt("content"))
            ?: visibleContentValue(item.opt("text"))
            ?: visibleContentValue(item.opt("output_text"))
    }

    private fun refusalContent(item: JSONObject?): String? {
        item ?: return null
        return visibleContentValue(item.opt("refusal"))
    }

    private fun reasoningContent(item: JSONObject?): String? {
        item ?: return null
        return visibleContentValue(item.opt("reasoning_content"))
            ?: visibleContentValue(item.opt("reasoningContent"))
            ?: visibleContentValue(item.opt("reasoning"))
            ?: visibleContentValue(item.opt("thinking"))
    }

    private fun visibleContentValue(value: Any?): String? =
        when (value) {
            null, JSONObject.NULL -> null
            is String -> value
            is JSONArray -> {
                val joined = (0 until value.length()).joinToString("") { index ->
                    visibleContentValue(value.opt(index)).orEmpty()
                }
                joined.takeIf { it.isNotEmpty() }
            }
            is JSONObject ->
                visibleContentValue(value.opt("text"))
                    ?: visibleContentValue(value.opt("value"))
                    ?: visibleContentValue(value.opt("content"))
            else -> null
        }

    private fun errorMessage(json: JSONObject): String? {
        val error = json.optJSONObject("error")
        if (error != null) {
            return error.optString("message").takeIf { it.isNotEmpty() }
                ?: error.optString("error").takeIf { it.isNotEmpty() }
                ?: error.optString("detail").takeIf { it.isNotEmpty() }
        }
        return json.optString("error").takeIf { it.isNotEmpty() }
            ?: json.optString("message_error").takeIf { it.isNotEmpty() }
    }

    private fun durationSecondsFromUsage(usage: JSONObject, keys: List<String>): Double? {
        for (key in keys) {
            if (!usage.has(key) || usage.isNull(key)) continue
            val value = usage.optDouble(key, Double.NaN).takeIf { it.isFinite() && it > 0 } ?: continue
            return when {
                value >= 1_000_000_000 -> value / 1_000_000_000.0
                value >= 10_000 -> value / 1_000.0
                else -> value
            }
        }
        return null
    }

    private fun JSONObject.optNullableInt(key: String): Int? =
        if (has(key) && !isNull(key)) optInt(key) else null
}
