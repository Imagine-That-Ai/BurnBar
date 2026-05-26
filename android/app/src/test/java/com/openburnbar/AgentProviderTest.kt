package com.openburnbar

import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.*
import org.junit.Test

class AgentProviderTest {

    @Test
    fun `fromKey returns correct provider`() {
        assertEquals(AgentProvider.OPEN_AI, AgentProvider.fromKey("openai"))
        assertEquals(AgentProvider.DEEP_SEEK, AgentProvider.fromKey("deepseek"))
        assertEquals(AgentProvider.CLAUDE_CODE, AgentProvider.fromKey("claude-code"))
        assertEquals(AgentProvider.GEMINI_CLI, AgentProvider.fromKey("gemini-cli"))
        assertEquals(AgentProvider.OLLAMA, AgentProvider.fromKey("ollama"))
        assertEquals(AgentProvider.ANTIGRAVITY, AgentProvider.fromKey("antigravity"))
        assertEquals(AgentProvider.ANTIGRAVITY, AgentProvider.fromKey("antigravity-cli"))
        assertEquals(AgentProvider.XAI, AgentProvider.fromKey("xai"))
        assertEquals(AgentProvider.XAI, AgentProvider.fromKey("x.ai"))
        assertEquals(AgentProvider.XAI, AgentProvider.fromKey("grok"))
        assertEquals(AgentProvider.PI_AGENT, AgentProvider.fromKey("pi-agent"))
        assertEquals(AgentProvider.FACTORY, AgentProvider.fromKey("droid"))
        assertEquals(AgentProvider.FACTORY, AgentProvider.fromKey("factory-droid"))
        assertEquals(AgentProvider.FORGE_DEV, AgentProvider.fromKey("forge"))
        assertEquals(AgentProvider.FORGE_DEV, AgentProvider.fromKey("forge-dev"))
    }

    @Test
    fun `fromKey returns null for unknown key`() {
        assertNull(AgentProvider.fromKey("nonexistent-provider"))
    }

    @Test
    fun `all providers have display names and colors`() {
        AgentProvider.entries.forEach { provider ->
            assertTrue("Missing display name for ${provider.key}", provider.displayName.isNotBlank())
            assertTrue("Missing brand color for ${provider.key}", provider.brandColor != 0L)
            assertTrue("Missing accent color for ${provider.key}", provider.accentColor != 0L)
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
