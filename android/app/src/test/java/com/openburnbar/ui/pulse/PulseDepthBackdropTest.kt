@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; drift
// fixtures are literal by design.

package com.openburnbar.ui.pulse

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-math tests for the `PulseDepthBackdrop` perf work: the 30Hz
 * derivedStateOf quantization ([pulseDepthQuantizedStep] /
 * [pulseDepthPhaseForStep]), the per-halo drift interpolation
 * ([pulseDepthDrift]), and the render/reduce-motion gating decisions. The
 * composable itself only wires these into `derivedStateOf` and the draw
 * scope.
 */
class PulseDepthBackdropTest {
    /**
     * The real (amount, freq) drift pairs of the five halos' two axes, in
     * draw order: hero ember, amber forecast, whimsy mid-band, mercury,
     * blaze foot.
     */
    private val haloDriftPairs = listOf(
        28f to 1.0f,
        16f to 0.7f,
        -22f to 0.6f,
        18f to 1.3f,
        24f to 0.9f,
        -20f to 0.5f,
        -18f to 0.8f,
        22f to 0.4f,
        14f to 1.1f,
        -12f to 0.7f,
    )

    @Test
    fun `the phase grid encodes 30Hz over the 22s drift cycle`() {
        assertEquals(660, QUANTIZED_PHASE_STEPS)
        assertEquals(DRIFT_CYCLE_MILLIS / 1_000 * 30, QUANTIZED_PHASE_STEPS)
    }

    @Test
    fun `quantization truncates toward zero like the historical inline math`() {
        // (phase * 660).toInt() — Float.toInt truncation, not rounding.
        assertEquals(0, pulseDepthQuantizedStep(0f))
        assertEquals(329, pulseDepthQuantizedStep(0.4999f))
        assertEquals(330, pulseDepthQuantizedStep(0.5f))
        assertEquals(659, pulseDepthQuantizedStep(0.9999f))
        assertEquals(660, pulseDepthQuantizedStep(1f))
    }

    @Test
    fun `every phase inside a grid cell collapses to that cell's step`() {
        // The invalidation contract: the derived Int is what the draw block
        // observes, so phases sharing a cell must produce zero redraws.
        for (step in 0 until QUANTIZED_PHASE_STEPS) {
            val cellMidpoint = (step + 0.5f) / QUANTIZED_PHASE_STEPS
            assertEquals(step, pulseDepthQuantizedStep(cellMidpoint))
        }
    }

    @Test
    fun `step reconstruction stays within one grid cell of the raw phase`() {
        val cellWidth = 1f / QUANTIZED_PHASE_STEPS
        var phase = 0f
        while (phase < 1f) {
            val reconstructed = pulseDepthPhaseForStep(pulseDepthQuantizedStep(phase))
            assertTrue(
                "phase $phase reconstructed as $reconstructed",
                abs(reconstructed - phase) < cellWidth,
            )
            phase += 0.00037f // dense, deliberately off-grid sweep
        }
    }

    @Test
    fun `per-step halo movement stays sub-pixel for every real drift pair`() {
        // The basis for shipping 30Hz: max drift velocity is amount·2π·freq
        // per cycle, i.e. ≤ ~0.27px per grid step for the largest halo pair —
        // imperceptible, while cutting halo redraws ~75% on 120Hz displays.
        for ((amount, freq) in haloDriftPairs) {
            var maxDelta = 0f
            for (step in 0 until QUANTIZED_PHASE_STEPS) {
                val here = pulseDepthDrift(pulseDepthPhaseForStep(step), amount, freq)
                val next = pulseDepthDrift(pulseDepthPhaseForStep(step + 1), amount, freq)
                maxDelta = maxOf(maxDelta, abs(next - here))
            }
            assertTrue(
                "($amount, $freq) moved $maxDelta px in one step",
                maxDelta <= 0.27f,
            )
        }
    }

    @Test
    fun `drift is bounded by its amplitude and starts at rest`() {
        for ((amount, freq) in haloDriftPairs) {
            assertEquals(0f, pulseDepthDrift(0f, amount, freq), 1e-6f)
            for (step in 0..QUANTIZED_PHASE_STEPS) {
                val offset = pulseDepthDrift(pulseDepthPhaseForStep(step), amount, freq)
                assertTrue(abs(offset) <= abs(amount) + 1e-4f)
            }
        }
    }

    @Test
    fun `custom dark backdrops suppress the halos entirely`() {
        // Under the token-ember swarm / dot constellation the warm glow
        // muddies card contrast and costs five full-screen gradient fills per
        // frame — the layer must skip itself.
        assertFalse(pulseDepthRendersHalos(useWebsiteBackground = true))
        assertTrue(pulseDepthRendersHalos(useWebsiteBackground = false))
    }

    @Test
    fun `reduce motion's rest step renders the exact cycle-start frame`() {
        assertEquals(0f, pulseDepthPhaseForStep(PULSE_DEPTH_REST_STEP), 0f)
        // At the rest phase every halo sits exactly on its anchor: the static
        // frame is identical to the animated cycle's first frame.
        for ((amount, freq) in haloDriftPairs) {
            assertEquals(0f, pulseDepthDrift(pulseDepthPhaseForStep(PULSE_DEPTH_REST_STEP), amount, freq), 0f)
        }
    }
}
