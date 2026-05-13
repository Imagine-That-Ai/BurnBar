package com.openburnbar

import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.HermesSubProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTilePreferencesTest {

    @Test
    fun `default tile set matches iOS`() {
        val prefs = ChatTilePreferences.DEFAULT
        assertTrue(prefs.enabledTiles.contains(AssistantRuntimeID.HERMES))
        assertTrue(prefs.enabledTiles.contains(AssistantRuntimeID.PI))
    }

    @Test
    fun `default hermes sub-provider set is all six`() {
        val prefs = ChatTilePreferences.DEFAULT
        assertEquals(6, prefs.enabledHermesSubProviders.size)
        for (sub in HermesSubProvider.values()) {
            assertTrue("Default must include $sub", prefs.enabledHermesSubProviders.contains(sub))
        }
    }

    @Test
    fun `JSON round-trip preserves enabled sets`() {
        val original = ChatTilePreferences(
            enabledTiles = setOf(AssistantRuntimeID.HERMES, AssistantRuntimeID.CODEX, AssistantRuntimeID.OPEN_CLAW),
            enabledHermesSubProviders = setOf(HermesSubProvider.CODEX, HermesSubProvider.CLAUDE, HermesSubProvider.OLLAMA),
            selectedHermesModelOverride = "kimi-k2"
        )
        val json = original.toJsonString()
        val decoded = ChatTilePreferences.fromJsonString(json)
        assertEquals(original.enabledTiles, decoded.enabledTiles)
        assertEquals(original.enabledHermesSubProviders, decoded.enabledHermesSubProviders)
        assertEquals(original.selectedHermesModelOverride, decoded.selectedHermesModelOverride)
    }

    @Test
    fun `empty JSON returns default`() {
        val prefs = ChatTilePreferences.fromJsonString("")
        assertEquals(ChatTilePreferences.DEFAULT.enabledTiles, prefs.enabledTiles)
        assertEquals(ChatTilePreferences.DEFAULT.enabledHermesSubProviders, prefs.enabledHermesSubProviders)
    }

    @Test
    fun `garbage JSON returns default`() {
        val prefs = ChatTilePreferences.fromJsonString("{not valid}")
        assertEquals(ChatTilePreferences.DEFAULT.enabledTiles, prefs.enabledTiles)
    }

    @Test
    fun `unknown tile tokens are dropped`() {
        val json = """{"tiles":["hermes","mystery"],"hermesSubProviders":["codex"]}"""
        val prefs = ChatTilePreferences.fromJsonString(json)
        assertEquals(setOf(AssistantRuntimeID.HERMES), prefs.enabledTiles)
        assertEquals(setOf(HermesSubProvider.CODEX), prefs.enabledHermesSubProviders)
    }

    @Test
    fun `withTile false on every tile leaves hermes enabled`() {
        var prefs = ChatTilePreferences.DEFAULT
        for (runtime in AssistantRuntimeID.values()) {
            prefs = prefs.withTile(runtime, enabled = false)
        }
        assertEquals(setOf(AssistantRuntimeID.HERMES), prefs.enabledTiles)
    }

    @Test
    fun `selected Hermes model helper trims and clears`() {
        val selected = ChatTilePreferences.DEFAULT.setSelectedHermesModel("  glm-4.6  ")
        assertEquals("glm-4.6", selected.selectedHermesModelOverride)

        val cleared = selected.setSelectedHermesModel(" ")
        assertEquals(null, cleared.selectedHermesModelOverride)
    }

    @Test
    fun `assistant runtime tokens are stable`() {
        // Persisted in SharedPreferences — must remain decodable.
        assertEquals("hermes", AssistantRuntimeID.HERMES.token)
        assertEquals("pi", AssistantRuntimeID.PI.token)
        assertEquals("codex", AssistantRuntimeID.CODEX.token)
        assertEquals("claude", AssistantRuntimeID.CLAUDE.token)
        assertEquals("openclaw", AssistantRuntimeID.OPEN_CLAW.token)
    }

    @Test
    fun `hermes sub-provider fromToken is case insensitive`() {
        assertEquals(HermesSubProvider.CODEX, HermesSubProvider.fromToken("Codex"))
        assertEquals(HermesSubProvider.ZAI, HermesSubProvider.fromToken("ZAI"))
        assertNotNull(HermesSubProvider.fromToken("minimax"))
    }

    @Test
    fun `ordered visible tiles preserve enum order`() {
        val prefs = ChatTilePreferences(
            enabledTiles = setOf(AssistantRuntimeID.OPEN_CLAW, AssistantRuntimeID.HERMES, AssistantRuntimeID.CODEX),
            enabledHermesSubProviders = emptySet()
        )
        assertEquals(
            listOf(AssistantRuntimeID.HERMES, AssistantRuntimeID.CODEX, AssistantRuntimeID.OPEN_CLAW),
            prefs.orderedVisibleTiles()
        )
    }
}
