package com.openburnbar.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundStyleTest {
    @Test
    fun fromKeyRoundTripsEveryStyle() {
        for (style in BackgroundStyle.entries) {
            assertEquals(style, BackgroundStyle.fromKey(style.key))
        }
    }

    @Test
    fun fromKeyIsNullForUnknownOrBlankKeys() {
        assertNull(BackgroundStyle.fromKey(null))
        assertNull(BackgroundStyle.fromKey(""))
        assertNull(BackgroundStyle.fromKey("   "))
        assertNull(BackgroundStyle.fromKey("not-a-style"))
    }

    @Test
    fun constellationKeyMatchesPersistedValue() {
        // The persisted key is part of the on-disk contract; pin it so a rename can't
        // silently drop a user's saved Constellation choice on the next launch.
        assertEquals("constellation", BackgroundStyle.DOT_CONSTELLATION.key)
        assertEquals(BackgroundStyle.DOT_CONSTELLATION, BackgroundStyle.fromKey("constellation"))
    }

    @Test
    fun customBackdropStylesDriveTheLegacyWebsiteBackgroundFlag() {
        // Both swarm and constellation paint a custom dark backdrop, which the rest of
        // the app reads (via useWebsiteBackground) to switch to high-contrast text.
        assertTrue(BackgroundStyle.SWARM.usesCustomBackdrop)
        assertTrue(BackgroundStyle.DOT_CONSTELLATION.usesCustomBackdrop)
        assertFalse(BackgroundStyle.AURORA.usesCustomBackdrop)
    }
}
