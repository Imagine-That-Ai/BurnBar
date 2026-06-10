@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; ARGB
// masks and token counts are literal by design.

package com.openburnbar.wallpaper

import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-rendering-policy tests for `BurnBarWallpaperService`: the alpha-channel
 * stamping the engine applies per particle and the token-share weighting that
 * turns the widget snapshot's top providers into the wallpaper palette.
 */
class BurnBarWallpaperServiceTest {
    // ── particle opacity → alpha channel ──

    @Test
    fun `opacity is clamped into the alpha channel and rgb stays untouched`() {
        val brandRgb = 0x00CC785C

        assertEquals(0xFFCC785C.toInt(), applyWallpaperParticleOpacity(brandRgb, 1.0))
        assertEquals(brandRgb, applyWallpaperParticleOpacity(brandRgb, 0.0))
        // Out-of-range opacities clamp instead of overflowing the channel.
        assertEquals(0xFFCC785C.toInt(), applyWallpaperParticleOpacity(brandRgb, 7.5))
        assertEquals(brandRgb, applyWallpaperParticleOpacity(brandRgb, -3.0))
        // Half opacity = floor(0.5 * 255) = 127.
        assertEquals((127 shl 24) or brandRgb, applyWallpaperParticleOpacity(brandRgb, 0.5))
    }

    @Test
    fun `an existing alpha byte is replaced not blended`() {
        val opaqueBrand = 0xFF112233.toInt()
        assertEquals(0x00112233, applyWallpaperParticleOpacity(opaqueBrand, 0.0))
        assertEquals((63 shl 24) or 0x00112233, applyWallpaperParticleOpacity(opaqueBrand, 0.25))
    }

    // ── widget snapshot → provider color weights ──

    @Test
    fun `weights are token shares over the kept providers`() {
        val claude = AgentProvider.entries.first().key
        val weights = wallpaperProviderColorWeights(
            topProviders = listOf(claude, AgentProvider.entries[1].key),
            topProviderTokens = listOf(3_000L, 1_000L),
        )

        assertEquals(2, weights.size)
        assertEquals(0.75, weights[0].weight, 1e-9)
        assertEquals(0.25, weights[1].weight, 1e-9)
        // The bands must tile the whole 0…1 colorIndex range.
        assertEquals(1.0, weights.sumOf { it.weight }, 1e-9)
        // Brand colors carry through as ARGB ints.
        assertEquals(weights[0].provider.brandColor.toInt(), weights[0].argb)
    }

    @Test
    fun `at most five providers are kept`() {
        val keys = AgentProvider.entries.take(7).map { it.key }
        val weights = wallpaperProviderColorWeights(
            topProviders = keys,
            topProviderTokens = List(7) { 100L },
        )
        assertEquals(5, weights.size)
        // Five kept of seven equal shares → 1/5 each over the kept set.
        assertTrue(weights.all { kotlin.math.abs(it.weight - 0.2) < 1e-9 })
    }

    @Test
    fun `unknown provider keys are dropped but keep the total share denominator`() {
        val known = AgentProvider.entries.first().key
        val weights = wallpaperProviderColorWeights(
            topProviders = listOf(known, "not-a-real-provider"),
            topProviderTokens = listOf(1_000L, 1_000L),
        )
        assertEquals(1, weights.size)
        // The unknown provider's tokens still count toward the denominator, so
        // the known provider renders its true half share, not an inflated 100%.
        assertEquals(0.5, weights[0].weight, 1e-9)
    }

    @Test
    fun `zero tokens never divide by zero`() {
        val weights = wallpaperProviderColorWeights(
            topProviders = listOf(AgentProvider.entries.first().key),
            topProviderTokens = listOf(0L),
        )
        assertEquals(1, weights.size)
        assertEquals(0.0, weights[0].weight, 1e-9)

        assertEquals(emptyList<ProviderColorWeight>(), wallpaperProviderColorWeights(emptyList(), emptyList()))
    }
}
