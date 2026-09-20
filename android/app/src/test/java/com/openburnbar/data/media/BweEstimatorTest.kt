
package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class BweEstimatorTest {
    @Test
    fun starts_at_highest_step() {
        val bwe = BweEstimator(BweEstimator.VIDEO_CALL_STEPS)
        assertEquals(BweEstimator.VIDEO_CALL_STEPS.last(), bwe.currentBitsPerSecond)
    }

    @Test
    fun loss_above_threshold_steps_down() {
        val bwe = BweEstimator(BweEstimator.VIDEO_CALL_STEPS)
        val start = bwe.currentBitsPerSecond
        bwe.apply(
            BweEstimator.Sample(
                roundTripMillis = 30,
                packetLossRate = 0.10,
                observedBitsPerSecond = start,
            ),
        )
        assertNotEquals(start, bwe.currentBitsPerSecond)
        assertEquals(BweEstimator.VIDEO_CALL_STEPS.dropLast(1).last(), bwe.currentBitsPerSecond)
    }

    @Test
    fun high_rtt_steps_down_even_with_zero_loss() {
        val bwe = BweEstimator(BweEstimator.VIDEO_CALL_STEPS)
        val start = bwe.currentBitsPerSecond
        bwe.apply(
            BweEstimator.Sample(
                roundTripMillis = 250,
                packetLossRate = 0.0,
                observedBitsPerSecond = start,
            ),
        )
        assertNotEquals(start, bwe.currentBitsPerSecond)
    }

    @Test
    fun recovery_hysteresis_requires_several_good_samples() {
        val bwe =
            BweEstimator(
                steps = BweEstimator.VIDEO_CALL_STEPS,
                recoveryHysteresisSamples = 3,
            )
        // Push down.
        bwe.apply(
            BweEstimator.Sample(roundTripMillis = 30, packetLossRate = 0.10, observedBitsPerSecond = 0),
        )
        val downStep = bwe.currentBitsPerSecond
        // One good sample shouldn't step back up.
        bwe.apply(
            BweEstimator.Sample(roundTripMillis = 30, packetLossRate = 0.0, observedBitsPerSecond = downStep),
        )
        assertEquals(downStep, bwe.currentBitsPerSecond)
        bwe.apply(
            BweEstimator.Sample(roundTripMillis = 30, packetLossRate = 0.0, observedBitsPerSecond = downStep),
        )
        bwe.apply(
            BweEstimator.Sample(roundTripMillis = 30, packetLossRate = 0.0, observedBitsPerSecond = downStep),
        )
        // After 3 good samples we should be back at the next step up.
        assertNotEquals(downStep, bwe.currentBitsPerSecond)
    }

    @Test
    fun single_step_table_clamps_safely() {
        val bwe = BweEstimator(steps = listOf(500_000))
        bwe.apply(BweEstimator.Sample(roundTripMillis = 30, packetLossRate = 0.10, observedBitsPerSecond = 0))
        // With only one step, down + up should both clamp to that step.
        assertEquals(500_000, bwe.currentBitsPerSecond)
    }

    @Test
    fun screen_share_impairment_walks_below_one_megabit() {
        val bwe = BweEstimator(BweEstimator.SCREEN_SHARE_STEPS)
        val expected = listOf(4_000_000, 2_000_000, 1_000_000, 500_000, 250_000)
        for (rung in expected) {
            assertEquals(
                rung,
                bwe.apply(
                    BweEstimator.Sample(
                        roundTripMillis = 200,
                        packetLossRate = 0.04,
                        observedBitsPerSecond = bwe.currentBitsPerSecond,
                    ),
                ),
            )
        }
    }

    @Test
    fun constrained_path_fast_drops_to_five_hundred_kbps() {
        val bwe = BweEstimator(BweEstimator.SCREEN_SHARE_STEPS)
        val next =
            bwe.apply(
                BweEstimator.Sample(
                    roundTripMillis = 40,
                    packetLossRate = 0.0,
                    observedBitsPerSecond = 8_000_000,
                    pathConstrained = true,
                ),
            )
        assertEquals(500_000, next)
    }

    @Test
    fun constrained_path_recovery_does_not_exceed_cellular_ceiling() {
        val bwe = BweEstimator(BweEstimator.SCREEN_SHARE_STEPS)
        bwe.apply(
            BweEstimator.Sample(
                roundTripMillis = 40,
                packetLossRate = 0.10,
                observedBitsPerSecond = 0,
                pathConstrained = true,
            ),
        )
        assertEquals(250_000, bwe.currentBitsPerSecond)

        repeat(9) {
            bwe.apply(
                BweEstimator.Sample(
                    roundTripMillis = 20,
                    packetLossRate = 0.0,
                    observedBitsPerSecond = 2_000_000,
                    pathConstrained = true,
                ),
            )
        }
        assertEquals(500_000, bwe.currentBitsPerSecond)
    }
}
