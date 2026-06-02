package com.openburnbar.ui.chartstudio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChartSpecRendererSecurityTest {
    @Test
    fun sanitizeMermaidStripsMarkdownFences() {
        val sanitized =
            ChartSpecRenderer.sanitizeMermaid(
                """
                ```mermaid
                flowchart TD
                  A --> B
                ```
                """.trimIndent(),
            )

        assertEquals("flowchart TD\n  A --> B", sanitized)
    }

    @Test
    fun sanitizeMermaidRejectsExternalLinks() {
        val sanitized =
            ChartSpecRenderer.sanitizeMermaid(
                """
                flowchart TD
                  A[Open]
                  click A href "https://example.com"
                """.trimIndent(),
            )

        assertEquals(ChartSpecRenderer.SAFE_MERMAID_FALLBACK, sanitized)
    }

    @Test
    fun sanitizeMermaidRejectsHtmlAndEventHandlers() {
        val sanitized =
            ChartSpecRenderer.sanitizeMermaid(
                """
                flowchart TD
                  A["<img src=x onerror=alert(1)>"]
                """.trimIndent(),
            )

        assertEquals(ChartSpecRenderer.SAFE_MERMAID_FALLBACK, sanitized)
    }

    @Test
    fun sanitizeMermaidRejectsOversizedInput() {
        val sanitized = ChartSpecRenderer.sanitizeMermaid("flowchart TD\nA[" + "x".repeat(12_500) + "]")

        assertEquals(ChartSpecRenderer.SAFE_MERMAID_FALLBACK, sanitized)
    }

    @Test
    fun decodeSanitizesMermaidSource() {
        val rendering =
            ChartSpecRenderer.decode(
                """
                {
                  "kind": "mermaid",
                  "source": "flowchart TD\nA[Open]\nclick A href \"https://example.com\""
                }
                """.trimIndent(),
            )

        if (rendering !is ChartStudioRendering.Mermaid) {
            throw AssertionError("Expected Mermaid rendering")
        }
        assertEquals(
            ChartSpecRenderer.SAFE_MERMAID_FALLBACK,
            rendering.spec.source,
        )
    }
}
