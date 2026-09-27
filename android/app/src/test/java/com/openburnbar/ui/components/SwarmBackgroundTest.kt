// bounds fixtures are literal by design.

package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Size
import androidx.lifecycle.Lifecycle
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

    @Test
    fun `disabled auto-cycling holds free swarm past the cycle boundary`() {
        val simulation = simulation()
        simulation.ensureBounds(Size(1200f, 800f))
        simulation.isAutoCyclingEnabled = false

        // 30s in: two full CINEMATIC cycle intervals elapse with no formation.
        simulation.advance(nowNanos = 30_000_000_000L, pointer = null)

        assertFalse(simulation.inShapeMode)
        // Positive control: the sim can still enter shape mode on demand, so
        // the hold above is the gate — not a broken cycler. Rings use the
        // generated point table, safe on the context-less JVM.
        simulation.setShapeMode("rings")
        assertTrue(simulation.inShapeMode)
    }

    @Test
    fun `scaled particle count applies the plan scale`() {
        assertEquals(520, scaledSwarmParticleCount(520, SwarmBackgroundRenderPlan.PROMINENT_LIVE))
        assertEquals(234, scaledSwarmParticleCount(520, SwarmBackgroundRenderPlan.SUBTLE_LIVE))
        assertEquals(486, scaledSwarmParticleCount(1080, SwarmBackgroundRenderPlan.SUBTLE_LIVE))
        // The composable never scales a non-live plan, but the helper stays
        // total: a zero scale floors at one particle, never zero.
        assertEquals(1, scaledSwarmParticleCount(520, SwarmBackgroundRenderPlan.STATIC_BACKDROP))
        assertEquals(1, scaledSwarmParticleCount(520, SwarmBackgroundRenderPlan.DISABLED_FALLBACK))
    }

    @Test
    fun `frame interval honors the plan fps cap`() {
        assertEquals(33_333_333L, swarmFrameIntervalNanos(SwarmBackgroundRenderPlan.PROMINENT_LIVE))
        assertEquals(66_666_666L, swarmFrameIntervalNanos(SwarmBackgroundRenderPlan.SUBTLE_LIVE))
        // Plans without a cap fall back to the legacy 60Hz floor.
        assertEquals(16_000_000L, swarmFrameIntervalNanos(SwarmBackgroundRenderPlan.STATIC_BACKDROP))
        assertEquals(16_000_000L, swarmFrameIntervalNanos(SwarmBackgroundRenderPlan.DISABLED_FALLBACK))
    }

    @Test
    fun `power predicate treats any nonzero plug source as connected`() {
        // BatteryManager.EXTRA_PLUGGED: 0 = on battery, 1/2/4 = AC/USB/wireless.
        assertFalse(isSwarmPowerConnectedFromPluggedExtra(0))
        assertTrue(isSwarmPowerConnectedFromPluggedExtra(1))
        assertTrue(isSwarmPowerConnectedFromPluggedExtra(2))
        assertTrue(isSwarmPowerConnectedFromPluggedExtra(4))
        assertTrue(isSwarmPowerConnectedFromPluggedExtra(7))
    }

    @Test
    fun `wifi predicate counts wifi or ethernet like iOS`() {
        assertFalse(isSwarmWifiConnectedFromTransports(hasWifiTransport = false, hasEthernetTransport = false))
        assertTrue(isSwarmWifiConnectedFromTransports(hasWifiTransport = true, hasEthernetTransport = false))
        assertTrue(isSwarmWifiConnectedFromTransports(hasWifiTransport = false, hasEthernetTransport = true))
        assertTrue(isSwarmWifiConnectedFromTransports(hasWifiTransport = true, hasEthernetTransport = true))
    }

    @Test
    fun `scene is active only while resumed`() {
        assertFalse(isSwarmSceneActive(Lifecycle.State.DESTROYED))
        assertFalse(isSwarmSceneActive(Lifecycle.State.INITIALIZED))
        assertFalse(isSwarmSceneActive(Lifecycle.State.CREATED))
        assertFalse(isSwarmSceneActive(Lifecycle.State.STARTED))
        assertTrue(isSwarmSceneActive(Lifecycle.State.RESUMED))
    }
}
