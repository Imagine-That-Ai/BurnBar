package com.openburnbar.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioral parity for the Android Settings search engine — matches the
 * iOS/macOS suites so cross-platform UX feels identical.
 */
class SettingsSearchEngineTest {

    private val fixture = listOf(
        SettingsItem(
            id = "theme",
            section = SettingsSection.CLOUD,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = "theme",
            title = "Theme",
            subtitle = "System, Light, or Dark",
            keywords = listOf("dark", "appearance"),
            helpText = "Choose how OpenBurnBar styles itself.",
        ),
        SettingsItem(
            id = "hermes-token",
            section = SettingsSection.HERMES,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = "hermes-token",
            title = "Gateway Auth Token",
            subtitle = "Bearer token",
            keywords = listOf("secret", "auth"),
            helpText = "Used for non-loopback bindings.",
        ),
        SettingsItem(
            id = "alerts-digest",
            section = SettingsSection.NOTIFICATIONS,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = "alerts-digest",
            title = "Daily Digest",
            subtitle = "Summary of spend",
            keywords = listOf("morning", "summary"),
        ),
        SettingsItem(
            id = "cafe",
            section = SettingsSection.CLOUD,
            pageRoute = SettingsPageRoute.ROOT,
            anchorId = "cafe",
            title = "Café Defaults",
            subtitle = "Diacritic test",
            keywords = listOf("coffee"),
        ),
    )

    @Test
    fun emptyQueryReturnsEmpty() {
        assertTrue(SettingsSearchEngine.search("", fixture).isEmpty())
        assertTrue(SettingsSearchEngine.search("   ", fixture).isEmpty())
    }

    @Test
    fun titleHitOutranksHelpTextHit() {
        val results = SettingsSearchEngine.search("dark", fixture)
        assertEquals("theme", results.first().id)
    }

    @Test
    fun keywordHitFindsMatch() {
        val results = SettingsSearchEngine.search("coffee", fixture)
        assertEquals("cafe", results.first().id)
    }

    @Test
    fun diacriticFolding() {
        assertEquals("cafe", SettingsSearchEngine.search("café", fixture).first().id)
        assertEquals("cafe", SettingsSearchEngine.search("cafe", fixture).first().id)
    }

    @Test
    fun andSemanticsDropsRowsMissingAnyToken() {
        val results = SettingsSearchEngine.search("daily digest", fixture)
        assertEquals(listOf("alerts-digest"), results.map { it.id })
    }

    @Test
    fun andSemanticsReturnsEmptyWhenAnyTokenMissing() {
        assertTrue(SettingsSearchEngine.search("dark spend", fixture).isEmpty())
    }

    @Test
    fun caseInsensitive() {
        assertEquals("theme", SettingsSearchEngine.search("theme", fixture).first().id)
        assertEquals("theme", SettingsSearchEngine.search("THEME", fixture).first().id)
        assertEquals("theme", SettingsSearchEngine.search("ThEmE", fixture).first().id)
    }

    @Test
    fun tieBreakerByTitleAscending() {
        val items = listOf(
            SettingsItem(
                id = "b",
                section = SettingsSection.CLOUD,
                pageRoute = SettingsPageRoute.ROOT,
                anchorId = "b",
                title = "Beta",
                keywords = listOf("match"),
            ),
            SettingsItem(
                id = "a",
                section = SettingsSection.CLOUD,
                pageRoute = SettingsPageRoute.ROOT,
                anchorId = "a",
                title = "Alpha",
                keywords = listOf("match"),
            ),
        )
        val results = SettingsSearchEngine.search("match", items).map { it.id }
        assertEquals(listOf("a", "b"), results)
    }

    @Test
    fun resultLimit() {
        val many = (0 until 60).map { i ->
            SettingsItem(
                id = "i$i",
                section = SettingsSection.CLOUD,
                pageRoute = SettingsPageRoute.ROOT,
                anchorId = "i$i",
                title = "Item $i",
                keywords = listOf("foo"),
            )
        }
        assertEquals(25, SettingsSearchEngine.search("foo", many, limit = 25).size)
    }

    // Manifest guards

    @Test
    fun manifestIsNotEmpty() {
        assertFalse(SettingsManifest.all.isEmpty())
    }

    @Test
    fun manifestAnchorsAreUnique() {
        val anchors = SettingsManifest.all.map { it.anchorId }
        assertEquals(anchors.size, anchors.toSet().size)
    }

    @Test
    fun manifestIdsAreUnique() {
        val ids = SettingsManifest.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
    }

    @Test
    fun manifestAnchorIndexCoversEveryItem() {
        for (item in SettingsManifest.all) {
            assertEquals(item.pageRoute, SettingsManifest.anchorIndex[item.anchorId])
        }
    }

    @Test
    fun manifestFindsOpenCodeProviderEntry() {
        val ids = SettingsSearchEngine.search("opencode", SettingsManifest.all).map { it.id }
        assertTrue(ids.contains("root.providers"))
    }
}
