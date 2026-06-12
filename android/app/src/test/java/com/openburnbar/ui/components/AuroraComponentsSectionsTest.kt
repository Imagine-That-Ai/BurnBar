// ladder values are literal design tokens.

package com.openburnbar.ui.components

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Presentation-policy tests for `AuroraComponentsSections`: the
 * density/Reduce-Motion ladder that decides which backdrop layers render, at
 * what opacity, and with which phase source — plus the vignette edge colors.
 */
class AuroraComponentsSectionsTest {
    @Test
    fun `vignette edge is deep black in dark mode and faint ink on paper`() {
        assertEquals(Color.Black.copy(alpha = 0.32f), auroraVignetteEdgeColor(isDark = true))
        assertEquals(Color(0xFF1C2014).copy(alpha = 0.10f), auroraVignetteEdgeColor(isDark = false))
        // The light vignette must stay much fainter than the dark one.
        assertTrue(auroraVignetteEdgeColor(false).alpha < auroraVignetteEdgeColor(true).alpha)
    }

    @Test
    fun `minimal density renders no animated layers at all`() {
        assertFalse(auroraShowsAnimatedLayers(AuroraDensity.MINIMAL))
        assertTrue(auroraShowsAnimatedLayers(AuroraDensity.SUBTLE))
        assertTrue(auroraShowsAnimatedLayers(AuroraDensity.FULL))
    }

    @Test
    fun `subtle density dims both the orb field and the ribbon`() {
        assertEquals(1f, auroraOrbLayerOpacity(AuroraDensity.FULL))
        assertEquals(0.55f, auroraOrbLayerOpacity(AuroraDensity.SUBTLE))
        assertEquals(0.55f, auroraRibbonLayerOpacity(AuroraDensity.FULL))
        assertEquals(0.35f, auroraRibbonLayerOpacity(AuroraDensity.SUBTLE))
        // The ribbon never reaches full opacity; SUBTLE always dims below FULL.
        for (density in listOf(AuroraDensity.FULL, AuroraDensity.SUBTLE)) {
            assertTrue(auroraRibbonLayerOpacity(density) < 1f)
        }
        assertTrue(auroraOrbLayerOpacity(AuroraDensity.SUBTLE) < auroraOrbLayerOpacity(AuroraDensity.FULL))
    }

    @Test
    fun `particles render only at full density without reduce motion`() {
        assertTrue(auroraShowsParticleLayer(AuroraDensity.FULL, reduceMotion = false))
        assertFalse(auroraShowsParticleLayer(AuroraDensity.FULL, reduceMotion = true))
        assertFalse(auroraShowsParticleLayer(AuroraDensity.SUBTLE, reduceMotion = false))
        assertFalse(auroraShowsParticleLayer(AuroraDensity.MINIMAL, reduceMotion = false))
    }

    @Test
    fun `reduce motion swaps every live phase for the shared static clamp`() {
        val livePhase: () -> Float = { 0.42f }

        val resolved = auroraResolvedPhase(reduceMotion = true, livePhase = livePhase)
        // The same capture-less instance is reused (no per-frame allocation)…
        assertSame(auroraStaticPhase, resolved)
        // …and it pins the drift to the static 0f frame.
        assertEquals(0f, resolved())

        val passthrough = auroraResolvedPhase(reduceMotion = false, livePhase = livePhase)
        assertSame(livePhase, passthrough)
        assertNotSame(auroraStaticPhase, passthrough)
        assertEquals(0.42f, passthrough())
    }
}
