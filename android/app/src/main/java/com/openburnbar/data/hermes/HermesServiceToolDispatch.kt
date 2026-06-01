package com.openburnbar.data.hermes

import org.json.JSONArray
import org.json.JSONObject

internal object HermesCompletionTextParser {
    fun parseCompletionText(json: JSONObject): String {
        val choices = json.optJSONArray("choices")
        if (choices != null && choices.length() > 0) {
            val choice = choices.optJSONObject(0)
            val parsedDelta = parseContentValue(choice?.optJSONObject("delta")?.opt("content"))
            if (parsedDelta.isNotEmpty()) return parsedDelta

            val messageContent = parseContentValue(choice?.optJSONObject("message")?.opt("content"))
            if (messageContent.isNotEmpty()) return messageContent

            val text = choice?.optString("text").orEmpty()
            if (text.isNotEmpty()) return text
        }

        return parseContentValue(json.opt("content")).ifEmpty {
            json.optString("output_text").takeIf { it.isNotEmpty() }
                ?: json.optString("text").takeIf { it.isNotEmpty() }
                ?: ""
        }
    }

    fun parseContentValue(value: Any?): String {
        return when (value) {
            is String -> value
            is JSONArray ->
                (0 until value.length()).joinToString("") { index ->
                    val item = value.opt(index)
                    when (item) {
                        is String -> item
                        is JSONObject ->
                            item.optString("text")
                                .takeIf { it.isNotEmpty() }
                                ?: item.optString("content")
                        else -> ""
                    }
                }
            is JSONObject ->
                value.optString("text")
                    .takeIf { it.isNotEmpty() }
                    ?: value.optString("content")
            else -> ""
        }
    }
}

/**
 * Captures fallback signals from each SSE chunk so an upstream model that
 * finishes without producing visible `content` can still surface something useful.
 */
internal class HermesEmptyResponseRescue {
    private var refusal = StringBuilder()
    private var reasoning = StringBuilder()
    private var lastFinishReason: String? = null

    fun absorb(json: JSONObject) {
        val choices = json.optJSONArray("choices") ?: return
        if (choices.length() == 0) return
        val choice = choices.optJSONObject(0) ?: return
        val delta = choice.optJSONObject("delta")
        val message = choice.optJSONObject("message")

        extractRefusal(delta)?.let { refusal.append(it) }
        extractRefusal(message)?.let { refusal.append(it) }
        extractReasoning(delta)?.let { reasoning.append(it) }
        extractReasoning(message)?.let { reasoning.append(it) }

        val finishReason =
            choice.optString("finish_reason").takeIf { it.isNotEmpty() }
                ?: choice.optString("finishReason").takeIf { it.isNotEmpty() }
        if (finishReason != null) lastFinishReason = finishReason
    }

    fun resolved(): EmptyResponseFallback =
        HermesChatMessageOutcome.emptyResponseFallback(
            refusal = refusal.toString(),
            reasoning = reasoning.toString(),
            finishReason = lastFinishReason,
        )

    private fun extractRefusal(envelope: JSONObject?): String? {
        envelope ?: return null
        return parseStringValue(envelope.opt("refusal"))
    }

    private fun extractReasoning(envelope: JSONObject?): String? {
        envelope ?: return null
        return parseStringValue(envelope.opt("reasoning_content"))
            ?: parseStringValue(envelope.opt("reasoningContent"))
            ?: parseStringValue(envelope.opt("reasoning"))
            ?: parseStringValue(envelope.opt("thinking"))
    }

    private fun parseStringValue(raw: Any?): String? {
        return when (raw) {
            is String -> raw.takeIf { it.isNotEmpty() }
            is JSONArray -> {
                val joined =
                    (0 until raw.length()).joinToString("") { idx ->
                        when (val item = raw.opt(idx)) {
                            is String -> item
                            is JSONObject ->
                                item.optString("text")
                                    .takeIf { it.isNotEmpty() }
                                    ?: item.optString("content")
                            else -> ""
                        }
                    }
                joined.takeIf { it.isNotEmpty() }
            }
            is JSONObject ->
                raw.optString("text")
                    .takeIf { it.isNotEmpty() }
                    ?: raw.optString("content").takeIf { it.isNotEmpty() }
            else -> null
        }
    }
}

internal class HermesServiceToolDispatch(
    private val atomNavigator: () -> HermesAtomNavigator?,
) {
    fun dispatchLocalToolCalls(json: JSONObject): Int {
        val choices = json.optJSONArray("choices") ?: return 0
        val choice = choices.optJSONObject(0)
        val container = choice?.optJSONObject("delta") ?: choice?.optJSONObject("message")
        val toolCallsArray =
            container?.optJSONArray("tool_calls")
                ?: container?.optJSONArray("toolCalls")
        if (toolCallsArray == null || toolCallsArray.length() == 0) return 0
        var dispatched = 0
        for (i in 0 until toolCallsArray.length()) {
            val entry = toolCallsArray.optJSONObject(i)
            if (entry != null) {
                val function = entry.optJSONObject("function")
                val name = function?.optString("name")?.takeIf { it.isNotEmpty() }
                if (function != null && name != null) {
                    val arguments = function.optString("arguments")
                    if (
                        MobileToolCatalog.dispatchLocal(
                            toolName = name,
                            argumentsJson = arguments,
                            navigator = atomNavigator(),
                        )
                    ) {
                        dispatched += 1
                    }
                }
            }
        }
        return dispatched
    }
}
