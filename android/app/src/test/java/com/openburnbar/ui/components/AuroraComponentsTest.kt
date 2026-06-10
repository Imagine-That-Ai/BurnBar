@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; drift
// fixtures are literal by design.

package com.openburnbar.ui.components

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-math tests for the `AuroraComponents` drift interpolation
 * ([auroraOrbDriftOffset]) — the placement-lambda math each orb reads every
 * frame, pinned here so the 18s drift path stays a straight lerp between its
 * two anchor offsets.
 */
class AuroraComponentsTest {
    private val offsetA = Offset(-100f, -200f) // the ember orb's resting anchor
    private val offsetB = Offset(-60f, -176f)

    @Test
    fun `phase zero rests exactly at offset A`() {
        assertEquals(IntOffset(-100, -200), auroraOrbDriftOffset(offsetA, offsetB, phase = 0f))
    }

    @Test
    fun `phase one arrives exactly at offset B`() {
        assertEquals(IntOffset(-60, -176), auroraOrbDriftOffset(offsetA, offsetB, phase = 1f))
    }

    @Test
    fun `mid phase is the exact midpoint`() {
        assertEquals(IntOffset(-80, -188), auroraOrbDriftOffset(offsetA, offsetB, phase = 0.5f))
    }

    @Test
    fun `drift is monotonic along both axes for an increasing phase`() {
        var previous = auroraOrbDriftOffset(offsetA, offsetB, 0f)
        for (step in 1..10) {
            val current = auroraOrbDriftOffset(offsetA, offsetB, step / 10f)
            assertTrue("x must drift toward offsetB", current.x >= previous.x)
            assertTrue("y must drift toward offsetB", current.y >= previous.y)
            previous = current
        }
    }

    @Test
    fun `a static phase clamp pins the orb to its resting anchor`() {
        // Reduce Motion feeds a constant 0f phase: the orb must render the
        // identical frame as phase zero, with no residual drift.
        val resting = auroraOrbDriftOffset(offsetA, offsetB, 0f)
        assertEquals(resting, auroraOrbDriftOffset(offsetA, offsetB, auroraStaticPhase()))
    }

    @Test
    fun `fractional pixels truncate toward zero like the historical inline math`() {
        // (0 → 10) at phase 0.55 = 5.5 → 5 (Float.toInt truncation, not rounding).
        assertEquals(IntOffset(5, -5), auroraOrbDriftOffset(Offset(0f, 0f), Offset(10f, -10f), 0.55f))
    }

    @Test
    fun `identical anchors never move regardless of phase`() {
        val anchored = Offset(120f, 240f) // the amber orb's anchor pair shape
        for (phase in listOf(0f, 0.3f, 0.7f, 1f)) {
            assertEquals(IntOffset(120, 240), auroraOrbDriftOffset(anchored, anchored, phase))
        }
    }
}
