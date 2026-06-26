package com.openburnbar

import com.openburnbar.data.widget.BurnBarWidgetSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetSnapshotPrivacyTest {
    @Test
    fun `runtime unavailable fallback never uses preview spend`() {
        val snapshot = BurnBarWidgetSnapshot.unavailable

        assertEquals(0.0, snapshot.heroTotalCost, 0.0)
        assertEquals(0L, snapshot.heroTotalTokens)
        assertEquals(0, snapshot.heroTotalRequests)
        assertEquals(emptyList<String>(), snapshot.topProviders)
        assertEquals(emptyList<Long>(), snapshot.topProviderTokens)
        assertEquals("unavailable", snapshot.windowKey)
        assertFalse(snapshot.hasSyncedUserData)
    }

    @Test
    fun `preview snapshot remains visually populated for design previews only`() {
        val preview = BurnBarWidgetSnapshot.preview

        assertTrue(preview.heroTotalCost > 0.0)
        assertTrue(preview.heroTotalTokens > 0L)
        assertTrue(preview.topProviders.isNotEmpty())
        assertTrue(preview.hasSyncedUserData)
    }

    @Test
    fun `lock screen presentation redacts exact usage values`() {
        val snapshot =
            BurnBarWidgetSnapshot(
                heroTotalCost = 42.25,
                heroTotalTokens = 98_000,
                heroTotalRequests = 17,
                topProviders = listOf("Claude Code"),
                topProviderTokens = listOf(98_000),
                lastSyncMs = 1_717_000_000_000,
            )

        val presentation = snapshot.lockScreenPresentation()

        assertEquals("BurnBar", presentation.title)
        assertEquals("Usage private", presentation.detail)
        assertEquals(1.0f, presentation.ringProgress)
        assertTrue(presentation.hasSyncedUserData)
    }

    @Test
    fun `lock screen presentation invites sync when no user snapshot exists`() {
        val presentation = BurnBarWidgetSnapshot.unavailable.lockScreenPresentation()

        assertEquals("BurnBar", presentation.title)
        assertEquals("Open to sync", presentation.detail)
        assertEquals(0.0f, presentation.ringProgress)
        assertFalse(presentation.hasSyncedUserData)
    }
}
