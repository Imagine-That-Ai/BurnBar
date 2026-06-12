// bounds fixtures are literal by design.

package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Size
import com.openburnbar.data.models.AgentProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lifecycle tests for the `SwarmBackground` simulation host: the
 * uninitialized-advance guard, proportional rescaling on bounds changes, and
 * the shape-preference → mode gating (including the glyph-filter fallback).
 * Step physics and frame-scale independence live in [SwarmSimulationTest].
 */
class SwarmBackgroundTest {
    private fun simulation(particleCount: Int = 60) = SwarmSimulation(
        particleCount = particleCount,
        pace = SwarmPace.CINEMATIC,
        clockNanos = { 1_000_000_000L },
    )

    private fun positions(simulation: SwarmSimulation): List<Pair<Double, Double>> = simulation.particles.map { it.x to it.y }

    @Test
    fun `advance before any bounds is a guarded no op`() {
        val simulation = simulation()
        val before = positions(simulation)

        simulation.advance(nowNanos = 2_000_000_000L, pointer = null)

        // Without ensureBounds the simulation must not integrate physics over
        // a zero-sized canvas (which would collapse every particle to a wall).
        assertEquals(before, positions(simulation))
    }

    @Test
    fun `ensureBounds seeds particles inside the canvas`() {
        val simulation = simulation(particleCount = 120)
        simulation.ensureBounds(Size(1200f, 800f))

        assertEquals(120, simulation.particles.size)
        assertTrue(
            simulation.particles.all { it.x in 0.0..1200.0 && it.y in 0.0..800.0 },
        )
    }

    @Test
    fun `a rotation rescales every particle proportionally`() {
        val simulation = simulation()
        simulation.ensureBounds(Size(1000f, 500f))
        val before = positions(simulation)

        // Portrait → landscape: double the width, quadruple the height.
        simulation.ensureBounds(Size(2000f, 2000f))

        val after = positions(simulation)
        for (index in before.indices) {
            assertEquals(before[index].first * 2.0, after[index].first, 1e-9)
            assertEquals(before[index].second * 4.0, after[index].second, 1e-9)
        }
    }

    @Test
    fun `re-applying identical bounds does not reseed positions`() {
        val simulation = simulation()
        simulation.ensureBounds(Size(1000f, 500f))
        val seeded = positions(simulation)

        simulation.ensureBounds(Size(1000f, 500f))

        assertEquals(seeded, positions(simulation))
    }

    @Test
    fun `shape preferences enter and leave shape mode`() {
        val simulation = simulation()
        simulation.ensureBounds(Size(1200f, 800f))

        assertFalse(simulation.inShapeMode)
        // "rings" forms from the generated point table, so the gating is
        // testable on the context-less JVM (text rasters need android.graphics).
        simulation.setShapeMode("rings")
        assertTrue(simulation.inShapeMode)
        assertTrue(simulation.particles.any { it.tx != null && it.ty != null })
        simulation.setShapeMode("swarm")
        assertFalse(simulation.inShapeMode)
        assertTrue(simulation.particles.all { it.tx == null && it.role == null })
    }

    @Test
    fun `grok preference falls back to free swarm when the xai glyph is disabled`() {
        val simulation = SwarmSimulation(
            particleCount = 60,
            pace = SwarmPace.CINEMATIC,
            enabledProviderGlyphs = setOf(AgentProvider.CODEX),
            clockNanos = { 1_000_000_000L },
        )
        simulation.ensureBounds(Size(1200f, 800f))

        simulation.setShapeMode("grok")

        // The user disabled the xAI glyph: the swarm must never reform the
        // Grok mark, it stays in free murmuration instead.
        assertFalse(simulation.inShapeMode)
        assertTrue(simulation.particles.none { it.role != null })
    }

    @Test
    fun `enabling the xai glyph restores the grok formation`() {
        val simulation = simulation()
        simulation.ensureBounds(Size(1200f, 800f))
        simulation.setShapeMode("grok")
        assertTrue(simulation.inShapeMode)
    }
}
