package com.openburnbar.wallpaper.livingthemes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LivingThemeIntentTest {
    @Test
    fun parsesThemeAndQuality() {
        assertEquals(
            LivingThemeRequest(LiveTheme.FLUID_AURORA, 30),
            LivingThemeIntent.parse(
                "burnbar://living-theme?theme=fluid-aurora&quality=atelier",
            ),
        )
    }

    @Test
    fun qualityProfilesUseDistinctFrameRateBudgets() {
        assertEquals(20, LivingThemeIntent.parse("burnbar://living-theme?theme=mesh&quality=eco")?.maxFps)
        assertEquals(30, LivingThemeIntent.parse("burnbar://living-theme?theme=mesh&quality=atelier")?.maxFps)
        assertEquals(60, LivingThemeIntent.parse("burnbar://living-theme?theme=mesh&quality=cinema")?.maxFps)
    }

    @Test
    fun acceptsLegacyHostAndKernelAlias() {
        assertEquals(
            LivingThemeRequest(LiveTheme.AURORA, 20),
            LivingThemeIntent.parse("burnbar://live-wallpaper?kernel=aurora"),
        )
    }

    @Test
    fun rejectsUnknownThemesAndUnrelatedLinks() {
        assertNull(LivingThemeIntent.parse("burnbar://living-theme?theme=missing"))
        assertNull(LivingThemeIntent.parse("burnbar://dashboard"))
        assertNull(LivingThemeIntent.parse("https://imaginethat.ai/live"))
    }

    @Test
    fun completeCatalogMatchesOpenBurnBarBackdropCatalog() {
        assertEquals(42, LiveTheme.entries.size)
        assertEquals(42, LiveTheme.entries.map { it.assetID }.distinct().size)
        assertEquals(
            LiveTheme.entries.map { it.id },
            com.openburnbar.ui.settings.MobileBackdropKernel.entries.map { it.key },
        )
    }
}
