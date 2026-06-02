package com.openburnbar.irohrelay

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class HermesStreamEventTest {
    @Test
    fun event_vector_decodes_and_reencodes_byte_identically() {
        val fixture =
            requireNotNull(
                javaClass.classLoader?.getResource("hermes-stream/HermesStreamEventVector.json"),
            ).readText().trim()
        val events =
            HermesStreamEvent.json.decodeFromString(
                ListSerializer(HermesStreamEvent.serializer()),
                fixture,
            )

        assertEquals(9, events.size)
        assertEquals(HermesStreamEvent.MessageChunk("Hello "), events.first())
        assertEquals(
            HermesStreamEvent.MessageStop(
                finishReason = "stop",
                outcome = HermesChatMessageOutcome.NORMAL,
                usage =
                    HermesTokenUsageStats(
                        promptTokens = 10,
                        outputTokens = 20,
                        totalTokens = 30,
                        generationDurationSeconds = 1.25,
                        totalDurationSeconds = 2.5,
                    ),
            ),
            events.last(),
        )

        val encoded =
            HermesStreamEvent.json.encodeToString(
                ListSerializer(HermesStreamEvent.serializer()),
                events,
            )
        assertEquals(canonicalJson(fixture), canonicalJson(encoded))
    }

    @Test
    fun unknown_fields_are_ignored_for_forward_compatibility() {
        val decoded =
            HermesStreamEvent.json.decodeFromString(
                HermesStreamEvent.serializer(),
                """{"type":"notice","level":"info","text":"hello","future":"ignored"}""",
            )

        assertEquals(HermesStreamEvent.Notice(level = "info", text = "hello"), decoded)
    }

    private fun canonicalJson(text: String): String = renderSorted(HermesStreamEvent.json.parseToJsonElement(text))

    private fun renderSorted(element: JsonElement): String =
        when (element) {
            is JsonArray -> element.joinToString(separator = ",", prefix = "[", postfix = "]") { renderSorted(it) }
            is JsonObject ->
                element.keys
                    .sorted()
                    .joinToString(separator = ",", prefix = "{", postfix = "}") { key ->
                        "${JsonPrimitive(key)}:${renderSorted(requireNotNull(element[key]))}"
                    }
            else -> element.toString()
        }
}
