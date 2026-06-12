// values are literal design tokens.

package com.openburnbar.ui.settings

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wallpaper-style catalog tests for `WallpaperGeneratorScreenSections`: each
 * [WallpaperStyle] must pin its canvas color, its dark/light classification,
 * and a palette name the [SwarmSimulation] string-keyed palette switch (and
 * [AppThemePalette]) actually knows — a typo here silently renders the
 * default palette.
 */
class WallpaperGeneratorScreenSectionsTest {
    @Test
    fun `every style maps to a real AppThemePalette entry`() {
        for (style in WallpaperStyle.entries) {
            assertNotNull(
                "palette '${style.paletteName}' of $style is not an AppThemePalette",
                AppThemePalette.entries.find { it.name == style.paletteName },
            )
        }
    }

    @Test
    fun `palette mapping is the designed one to one pairing`() {
        assertEquals("AuroraTeal", WallpaperStyle.DARK.paletteName)
        assertEquals("ForestMoss", WallpaperStyle.LIGHT.paletteName)
        assertEquals("CyberpunkViolet", WallpaperStyle.AMOLED.paletteName)
        assertEquals("SolarFlare", WallpaperStyle.EMBER.paletteName)
        // No two styles share a palette.
        val palettes = WallpaperStyle.entries.map { it.paletteName }
        assertEquals(palettes.size, palettes.toSet().size)
    }

    @Test
    fun `amoled is true black and light is the only light style`() {
        assertEquals(Color.Black, WallpaperStyle.AMOLED.backgroundColor)
        assertFalse(WallpaperStyle.LIGHT.isDark)
        for (style in WallpaperStyle.entries.filter { it != WallpaperStyle.LIGHT }) {
            assertTrue("$style must render as a dark canvas", style.isDark)
        }
    }

    @Test
    fun `canvas colors are pinned design tokens`() {
        assertEquals(Color(0xFF0E0D0B), WallpaperStyle.DARK.backgroundColor)
        assertEquals(Color(0xFFEDF0E6), WallpaperStyle.LIGHT.backgroundColor)
        assertEquals(Color(0xFF140F0A), WallpaperStyle.EMBER.backgroundColor)
    }

    @Test
    fun `display names are user facing and unique`() {
        assertEquals("Ember Glow", WallpaperStyle.EMBER.displayName)
        assertEquals("AMOLED", WallpaperStyle.AMOLED.displayName)
        val names = WallpaperStyle.entries.map { it.displayName }
        assertEquals(names.size, names.toSet().size)
        assertTrue(names.all { it.isNotBlank() })
    }
}
