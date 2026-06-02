package com.openburnbar

import com.openburnbar.data.hermes.HermesOpenAICompatibleStreamParser
import com.openburnbar.data.hermes.HermesSseChunkReader
import com.openburnbar.irohrelay.HermesChatMessageOutcome
import com.openburnbar.irohrelay.HermesStreamEvent
import com.openburnbar.irohrelay.HermesTokenUsageStats
import org.junit.Assert.assertEquals
import org.junit.Test

class HermesOpenAICompatibleStreamParserTest {
    @Test
    fun parser_emits_tool_call_chunks_and_finished_event() {
        val parser = HermesOpenAICompatibleStreamParser()

        val first =
            parser.eventsFromPayload(
                """
                {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burn"}}]},"finish_reason":null}]}
                """.trimIndent(),
            )
        val second =
            parser.eventsFromPayload(
                """{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"bar\"}"}}]},"finish_reason":null}]}""",
            )
        val stop = parser.eventsFromPayload("""{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}""")

        assertEquals(
            listOf(HermesStreamEvent.ToolCallChunk("call_1", 0, "search", """{"query":"burn""")),
            first.events,
        )
        assertEquals(
            listOf(HermesStreamEvent.ToolCallChunk("call_1", 0, null, """bar"}""")),
            second.events,
        )
        assertEquals(
            listOf(
                HermesStreamEvent.ToolCallFinished("call_1", "search", """{"query":"burnbar"}"""),
                HermesStreamEvent.MessageStop(finishReason = "tool_calls", outcome = HermesChatMessageOutcome.NORMAL),
            ),
            stop.events,
        )
    }

    @Test
    fun done_payload_flushes_pending_tool_calls_when_provider_omits_finish_reason() {
        val parser = HermesOpenAICompatibleStreamParser()

        parser.eventsFromPayload(
            """
            {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burn"}}]},"finish_reason":null}]}
            """.trimIndent(),
        )
        parser.eventsFromPayload(
            """{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"bar\"}"}}]},"finish_reason":null}]}""",
        )
        val done = parser.eventsFromPayload("[DONE]")

        assertEquals(true, done.done)
        assertEquals(
            listOf(HermesStreamEvent.ToolCallFinished("call_1", "search", """{"query":"burnbar"}""")),
            done.events,
        )
    }

    @Test
    fun text_chunk_flushes_pending_tool_calls_before_visible_content() {
        val parser = HermesOpenAICompatibleStreamParser()

        val result =
            parser.eventsFromPayload(
                """
                {"choices":[{"delta":{"content":"done","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burnbar\"}"}}]},"finish_reason":null}]}
                """.trimIndent(),
            )

        assertEquals(
            listOf(
                HermesStreamEvent.ToolCallChunk("call_1", 0, "search", """{"query":"burnbar"}"""),
                HermesStreamEvent.ToolCallFinished("call_1", "search", """{"query":"burnbar"}"""),
                HermesStreamEvent.MessageChunk("done"),
            ),
            result.events,
        )
        assertEquals(true, result.streamedText)
    }

    @Test
    fun sse_reader_preserves_done_payload_for_parser_flush() {
        assertEquals("[DONE]", HermesSseChunkReader.parseRelayLine("data: [DONE]"))
    }

    @Test
    fun parser_emits_reasoning_refusal_and_ollama_usage() {
        val parser = HermesOpenAICompatibleStreamParser()
        val channels =
            parser.eventsFromPayload(
                """{"choices":[{"delta":{"reasoning_content":"think","refusal":"no"},"finish_reason":"stop"}]}""",
            )

        assertEquals(
            listOf(
                HermesStreamEvent.RefusalChunk("no"),
                HermesStreamEvent.ReasoningChunk("think"),
                HermesStreamEvent.MessageStop(finishReason = "stop", outcome = HermesChatMessageOutcome.NORMAL),
            ),
            channels.events,
        )

        val usage = parser.eventsFromPayload("""{"eval_count":8,"eval_duration":2000000000,"total_duration":2500000000}""")
        assertEquals(
            listOf(
                HermesStreamEvent.MessageStop(
                    outcome = HermesChatMessageOutcome.NORMAL,
                    usage = HermesTokenUsageStats(
                        outputTokens = 8,
                        totalTokens = 8,
                        generationDurationSeconds = 2.0,
                        totalDurationSeconds = 2.5,
                    ),
                ),
            ),
            usage.events,
        )
    }
}
