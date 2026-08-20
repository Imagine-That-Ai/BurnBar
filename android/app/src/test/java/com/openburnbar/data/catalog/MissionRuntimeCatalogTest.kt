package com.openburnbar.data.catalog

import com.openburnbar.data.assistants.CLIAgentSessionActionKind
import com.openburnbar.data.hermes.AssistantRuntimeID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MissionRuntimeCatalogTest {
    @Test
    fun catalogCoversAndroidAssistantRuntimeTokens() {
        val catalog = MissionRuntimeCatalog.loadFixture()
        val tokens = AssistantRuntimeID.values().map { it.token }
        assertTrue(catalog.covers(tokens))
        assertNotNull(AssistantRuntimeID.OPEN_CLAUDE)
        assertNotNull(AssistantRuntimeID.OMP)
        assertEquals("openclaude", AssistantRuntimeID.OPEN_CLAUDE.token)
        assertEquals("omp", AssistantRuntimeID.OMP.token)
    }

    @Test
    fun fromTokenDoesNotRemapUnknownToHermes() {
        assertNull(AssistantRuntimeID.fromToken("not-a-runtime"))
        assertNull(AssistantRuntimeID.fromToken(null))
        assertNotEquals(AssistantRuntimeID.HERMES, AssistantRuntimeID.fromToken("unknown"))
    }

    @Test
    fun sessionActionUnknownDoesNotRemapToResume() {
        assertNull(CLIAgentSessionActionKind.fromWire("not-an-action"))
        assertNotEquals(CLIAgentSessionActionKind.RESUME, CLIAgentSessionActionKind.fromWire("yolo"))
    }

    @Test
    fun cursorAliasesAreFirstClass() {
        val catalog = MissionRuntimeCatalog.loadFixture()
        for (alias in listOf("cursorAgent", "cursoragent", "cursor_agent", "cursor")) {
            assertEquals("cursoragent", catalog.canonicalId(alias))
        }
    }
}
