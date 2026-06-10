@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; the
// 200-char preview budget is literal by design.

package com.openburnbar.ui.hermes

import com.openburnbar.data.hermes.ToolCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Tool-pill summary tests for `HermesViewBubbleSections`:
 * [summarizeHermesToolDetail] feeds the one-line detail under each tool-call
 * pill — result first, then the canonical argument keys, then a regex rescue
 * for malformed JSON — always clamped to the 200-char preview budget.
 * (The permission-index helpers are pinned by [HermesChatPermissionIndexTest].)
 */
class HermesViewBubbleSectionsTest {
    private fun toolCall(arguments: String = "", result: String? = null) = ToolCall(id = "tc-1", name = "tool", arguments = arguments, result = result)

    @Test
    fun `result wins and is trimmed and clamped to 200 chars`() {
        val longResult = "  " + "r".repeat(300) + "  "
        val summary = summarizeHermesToolDetail(toolCall(arguments = """{"path":"/ignored"}""", result = longResult))
        assertEquals("r".repeat(200), summary)
    }

    @Test
    fun `a whitespace only result falls through to the arguments`() {
        val summary = summarizeHermesToolDetail(toolCall(arguments = """{"command":"ls -la"}""", result = "   "))
        assertEquals("ls -la", summary)
    }

    @Test
    fun `preferred argument keys resolve in canonical order`() {
        // "path" outranks "command" regardless of JSON field order.
        val summary = summarizeHermesToolDetail(
            toolCall(arguments = """{"command":"cat file","path":"/Users/me/file.txt"}"""),
        )
        assertEquals("/Users/me/file.txt", summary)

        // file_path is the second alias in the ladder.
        assertEquals(
            "/tmp/a.kt",
            summarizeHermesToolDetail(toolCall(arguments = """{"file_path":"/tmp/a.kt","query":"x"}""")),
        )
    }

    @Test
    fun `without a preferred key the first non empty value is used and clamped`() {
        val summary = summarizeHermesToolDetail(
            toolCall(arguments = """{"custom_arg":"${"v".repeat(250)}"}"""),
        )
        assertEquals("v".repeat(200), summary)
    }

    @Test
    fun `malformed json is rescued by the preferred key regex`() {
        // Truncated streaming arguments: not parseable, but the path is visible.
        val summary = summarizeHermesToolDetail(
            toolCall(arguments = """{"path":"/Users/me/project/Main.kt", "content":"unterminated"""),
        )
        assertEquals("/Users/me/project/Main.kt", summary)
    }

    @Test
    fun `empty payloads summarize to null so the pill renders without a detail row`() {
        assertNull(summarizeHermesToolDetail(toolCall()))
        assertNull(summarizeHermesToolDetail(toolCall(arguments = "   ")))
        // Malformed JSON without any preferred key has nothing to rescue.
        assertNull(summarizeHermesToolDetail(toolCall(arguments = """{"broken": tru""")))
    }

    @Test
    fun `numeric and url arguments stringify for the preview`() {
        assertEquals(
            "https://burnbar.ai/trust",
            summarizeHermesToolDetail(toolCall(arguments = """{"url":"https://burnbar.ai/trust"}""")),
        )
    }
}
