package com.openburnbar

import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.*
import org.junit.Test

class AgentProviderTest {

    @Test
    fun `fromKey returns correct provider`() {
        assertEquals(AgentProvider.OPEN_AI, AgentProvider.fromKey("openai"))
        assertEquals(AgentProvider.CLAUDE_CODE, AgentProvider.fromKey("claude-code"))
        assertEquals(AgentProvider.GEMINI_CLI, AgentProvider.fromKey("gemini-cli"))
        assertEquals(AgentProvider.OLLAMA, AgentProvider.fromKey("ollama"))
    }

    @Test
    fun `fromKey returns null for unknown key`() {
        assertNull(AgentProvider.fromKey("nonexistent-provider"))
    }

    @Test
    fun `all providers have display names and colors`() {
        AgentProvider.entries.forEach { provider ->
            assertTrue(provider.displayName.isNotBlank(), "Missing display name for ${provider.key}")
            assertTrue(provider.brandColor != 0L, "Missing brand color for ${provider.key}")
            assertTrue(provider.accentColor != 0L, "Missing accent color for ${provider.key}")
        }
    }

    @Test
    fun `chartPalette returns non-empty color list`() {
        AgentProvider.entries.forEach { provider ->
            val palette = AgentProvider.chartPalette(provider)
            assertEquals(4, palette.size)
        }
    }
}
