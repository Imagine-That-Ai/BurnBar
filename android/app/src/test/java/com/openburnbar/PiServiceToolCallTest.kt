@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar

import com.openburnbar.data.hermes.PiChatMessage
import com.openburnbar.data.hermes.PiConnectionRecord
import com.openburnbar.data.hermes.PiService
import com.openburnbar.data.hermes.PiServiceChatStreamSupport
import com.openburnbar.data.hermes.PiServiceRuntimeSupport
import com.openburnbar.data.hermes.ToolCall
import com.openburnbar.ui.hermes.summarizeHermesToolDetail
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the OpenAI-compatible tool-call accumulation Pi performs on
 * Android. The streaming protocol emits a single tool call across many chunks
 * (name first, then partial argument fragments tagged with the same `index`),
 * so the summarizer needs to handle both well-formed JSON and mid-stream
 * fragments. Tests double as the contract between the iOS and Android Pi
 * runtimes — both must produce identical pill detail strings.
 */
class PiServiceToolCallTest {
    @Test
    fun `summarizeToolArguments pulls path from full JSON`() {
        val service = PiService()
        assertEquals("/etc/hosts", service.summarizeToolArguments("""{"path":"/etc/hosts"}"""))
    }

    @Test
    fun `summarizeToolArguments pulls command from full JSON`() {
        val service = PiService()
        assertEquals("ls -al", service.summarizeToolArguments("""{"command":"ls -al"}"""))
    }

    @Test
    fun `summarizeToolArguments returns null for empty input`() {
        val service = PiService()
        assertNull(service.summarizeToolArguments(""))
    }

    @Test
    fun `summarizeToolArguments handles partial mid-stream JSON via regex fallback`() {
        // Mid-stream the JSON is incomplete (no closing brace yet). The regex
        // fallback should still surface the file path so the pill renders
        // something useful before the tool call finishes.
        val service = PiService()
        assertEquals(
            "docs/README.md",
            service.summarizeToolArguments("""{"path":"docs/README.md""""),
        )
    }

    @Test
    fun `summarizeHermesToolDetail prefers result over arguments`() {
        val tc =
            ToolCall(
                id = "1",
                name = "search",
                arguments = """{"query":"timezone"}""",
                result = "Pacific Daylight Time",
            )
        assertEquals("Pacific Daylight Time", summarizeHermesToolDetail(tc))
    }

    @Test
    fun `summarizeHermesToolDetail falls back to arguments preview when no result`() {
        val tc =
            ToolCall(
                id = "1",
                name = "search",
                arguments = """{"query":"timezone"}""",
                result = null,
            )
        assertEquals("timezone", summarizeHermesToolDetail(tc))
    }

    @Test
    fun `summarizeHermesToolDetail returns null for empty payload`() {
        val tc = ToolCall(id = "1", name = "noop", arguments = "", result = null)
        assertNull(summarizeHermesToolDetail(tc))
    }

    @Test
    fun `Pi stream support consumes typed parser events and done flush`() {
        val messages = MutableStateFlow(listOf(PiChatMessage(id = "assistant", role = "assistant", isStreaming = true)))
        val client = OkHttpClient()
        val selectedModelID = MutableStateFlow<String?>("pi")
        val support =
            PiServiceChatStreamSupport(
                client = client,
                messages = messages,
                selectedModelID = { selectedModelID.value },
                runtimeSupport = PiServiceRuntimeSupport(
                    client = client,
                    selectedConnection = { PiConnectionRecord.localDefault },
                    modelOptions = MutableStateFlow(emptyList()),
                    selectedModelID = selectedModelID,
                    isReachable = MutableStateFlow(false),
                    runtimeError = {},
                ),
                appendToAssistant = { assistantId, delta, transform ->
                    messages.value =
                        messages.value.map { existing ->
                            if (existing.id != assistantId) return@map existing
                            val withDelta = if (delta.isEmpty()) existing else existing.copy(content = existing.content + delta)
                            transform?.invoke(withDelta) ?: withDelta
                        }
                },
                applyError = { assistantId, text ->
                    messages.value =
                        messages.value.map { existing ->
                            if (existing.id == assistantId) {
                                existing.copy(content = text, isError = true, isStreaming = false)
                            } else {
                                existing
                            }
                        }
                },
            ).also { it.currentThreadID = { "thread" } }

        support.applySsePayload(
            """
            {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burn"}}]},"finish_reason":null}]}
            """.trimIndent(),
            "assistant",
        )
        support.applySsePayload(
            """{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"bar\"}"}}]},"finish_reason":null}]}""",
            "assistant",
        )
        support.applySsePayload(
            """{"choices":[{"delta":{"content":"Hello "},"finish_reason":null}]}""",
            "assistant",
        )
        val done = support.applySsePayload("[DONE]", "assistant")

        val assistant = messages.value.single()
        assertEquals(true, done)
        assertEquals("Hello ", assistant.content)
        assertEquals("call_1", assistant.toolCalls.single().id)
        assertEquals("search", assistant.toolCalls.single().name)
        assertEquals("""{"query":"burnbar"}""", assistant.toolCalls.single().arguments)
    }
}
