package com.openburnbar.ui.hermes

import com.openburnbar.data.hermes.HermesAtomRun
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesRichBubbleTest {
    @Test
    fun `streaming content stays literal until the response completes`() {
        val text = "Generating [Session AB12](burnbar://session?id=abcd1234)"

        assertEquals(listOf(HermesAtomRun.Text(text)), hermesRichRuns(text, isStreaming = true))
    }

    @Test
    fun `completed content parses rich Hermes atoms`() {
        val runs = hermesRichRuns("[Session AB12](burnbar://session?id=abcd1234)", isStreaming = false)

        assertTrue(runs.single() is HermesAtomRun.Atom)
    }
}
