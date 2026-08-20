package com.openburnbar.ui.tokens

import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.TweenSpec
import kotlin.math.PI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `PensieveMotion` resolves design tokens into Compose animation specs. It holds no
 * Composables, so every rule here is checkable on the JVM — which matters, because
 * these values decide what a user who has asked for Reduce Motion actually sees.
 */
class PensieveMotionTest {

    // MARK: Reduce Motion

    /// The whole Reduce Motion contract in one assertion: springs become tweens.
    /// A spring that survives here is motion a user explicitly opted out of.
    @Test
    fun `settle and arrive collapse from spring to tween under reduce motion`() {
        assertTrue(PensieveMotion.settleSpec<Float>(reduceMotion = false) is SpringSpec)
        assertTrue(PensieveMotion.arriveSpec<Float>(reduceMotion = false) is SpringSpec)
        assertTrue(PensieveMotion.settleSpec<Float>(reduceMotion = true) is TweenSpec)
        assertTrue(PensieveMotion.arriveSpec<Float>(reduceMotion = true) is TweenSpec)
    }

    /// Depart and tick are tweens either way, so the rule they must honour is
    /// duration, not type.
    @Test
    fun `depart and tick shorten to the reduced duration`() {
        assertEquals(
            PensieveMotion.departMs,
            (PensieveMotion.departSpec<Float>(reduceMotion = false) as TweenSpec).durationMillis,
        )
        assertEquals(
            PensieveMotion.reducedMs,
            (PensieveMotion.departSpec<Float>(reduceMotion = true) as TweenSpec).durationMillis,
        )
        assertEquals(
            PensieveMotion.tickMs,
            (PensieveMotion.tickSpec<Float>(reduceMotion = false) as TweenSpec).durationMillis,
        )
        assertEquals(
            PensieveMotion.reducedMs,
            (PensieveMotion.tickSpec<Float>(reduceMotion = true) as TweenSpec).durationMillis,
        )
    }

    // MARK: Stagger

    /// Stagger is the one token that must reach exactly zero, not merely "small":
    /// a staggered cascade is precisely the effect Reduce Motion exists to stop.
    @Test
    fun `stagger is zero under reduce motion and for the first item`() {
        assertEquals(0L, PensieveMotion.staggerDelay(index = 5, reduceMotion = true))
        assertEquals(0L, PensieveMotion.staggerDelay(index = 0))
        assertEquals(0L, PensieveMotion.staggerDelay(index = -3))
    }

    @Test
    fun `stagger steps linearly then clamps at the cap`() {
        assertEquals(PensieveMotion.staggerStepMs, PensieveMotion.staggerDelay(index = 1))
        assertEquals(PensieveMotion.staggerStepMs * 2, PensieveMotion.staggerDelay(index = 2))
        // Far past the cap: a long list must not stagger for seconds.
        assertEquals(PensieveMotion.staggerCapMs, PensieveMotion.staggerDelay(index = 1_000))
        assertTrue(PensieveMotion.staggerDelay(index = 50) <= PensieveMotion.staggerCapMs)
    }

    // MARK: Stiffness

    /// Stiffness is derived, not authored: k = (2π / responseSeconds)². Pinning the
    /// formula keeps a token edit from silently retuning every spring in the app.
    @Test
    fun `stiffness follows the response-period formula`() {
        fun expected(responseMs: Float): Float {
            val omega = (2.0 * PI) / (responseMs / 1000.0)
            return (omega * omega).toFloat()
        }
        assertEquals(expected(PensieveMotion.settleResponseMs), PensieveMotion.settleStiffness, 0.01f)
        assertEquals(expected(PensieveMotion.arriveResponseMs), PensieveMotion.arriveStiffness, 0.01f)
    }

    /// Arrive responds faster than settle, so it must be the stiffer spring. This is
    /// the ordering the vocabulary depends on; equal values would flatten the two.
    @Test
    fun `arrive is stiffer than settle and both are positive`() {
        assertTrue(PensieveMotion.settleStiffness > 0f)
        assertTrue(PensieveMotion.arriveStiffness > PensieveMotion.settleStiffness)
    }

    // MARK: Token fallbacks

    /// Every token parses to a usable number. A malformed token falls back rather
    /// than producing 0f, which would mean an infinitely stiff spring.
    @Test
    fun `damping ratios stay inside the physical range`() {
        assertTrue(PensieveMotion.settleDamping > 0f && PensieveMotion.settleDamping <= 1f)
        assertTrue(PensieveMotion.arriveDamping > 0f && PensieveMotion.arriveDamping <= 1f)
        // Settle is damped harder than arrive so plate edges do not wobble.
        assertTrue(PensieveMotion.settleDamping > PensieveMotion.arriveDamping)
    }

    @Test
    fun `durations and periods are positive`() {
        assertTrue(PensieveMotion.departMs > 0)
        assertTrue(PensieveMotion.tickMs > 0)
        assertTrue(PensieveMotion.reducedMs > 0)
        assertTrue(PensieveMotion.pulsePeriodMs > 0)
        assertTrue(PensieveMotion.staggerStepMs > 0L)
        assertTrue(PensieveMotion.staggerCapMs >= PensieveMotion.staggerStepMs)
        assertTrue(PensieveMotion.pulseFloor > 0f && PensieveMotion.pulseFloor < 1f)
    }
}
