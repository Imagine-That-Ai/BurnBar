package com.openburnbar

import com.openburnbar.data.hermes.PiService
import com.openburnbar.ui.hermes.summarizeHermesToolDetail
import com.openburnbar.data.hermes.ToolCall
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
            service.summarizeToolArguments("""{"path":"docs/README.md"""")
        )
    }

    @Test
    fun `summarizeHermesToolDetail prefers result over arguments`() {
        val tc = ToolCall(
            id = "1",
            name = "search",
            arguments = """{"query":"timezone"}""",
            result = "Pacific Daylight Time"
        )
        assertEquals("Pacific Daylight Time", summarizeHermesToolDetail(tc))
    }

    @Test
    fun `summarizeHermesToolDetail falls back to arguments preview when no result`() {
        val tc = ToolCall(
            id = "1",
            name = "search",
            arguments = """{"query":"timezone"}""",
            result = null
        )
        assertEquals("timezone", summarizeHermesToolDetail(tc))
    }

    @Test
    fun `summarizeHermesToolDetail returns null for empty payload`() {
        val tc = ToolCall(id = "1", name = "noop", arguments = "", result = null)
        assertNull(summarizeHermesToolDetail(tc))
    }
}
