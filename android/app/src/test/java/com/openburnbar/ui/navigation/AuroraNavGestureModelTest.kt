package com.openburnbar.ui.navigation

import com.openburnbar.ui.navigation.AuroraNavGestureModel.SwipeDirection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Port of the root-swipe section of the iOS `AuroraNavigationTrayTests`
 * (swipe-direction resolution + adjacency with nil edges), so both phones
 * resolve the same drag to the same tab change.
 */
class AuroraNavGestureModelTest {
    private val allTabs = BurnBarTab.allCandidates

    // ── Adjacency ──

    @Test
    fun `adjacent leading from the first tab returns the second`() {
        assertSame(
            BurnBarTab.BURN,
            AuroraNavGestureModel.adjacent(BurnBarTab.PULSE, SwipeDirection.LEADING, allTabs),
        )
    }

    @Test
    fun `adjacent trailing from the second tab returns the first`() {
        assertSame(
            BurnBarTab.PULSE,
            AuroraNavGestureModel.adjacent(BurnBarTab.BURN, SwipeDirection.TRAILING, allTabs),
        )
    }

    @Test
    fun `adjacent leading from the last tab returns null`() {
        // Edge is nil — no wraparound.
        assertNull(AuroraNavGestureModel.adjacent(BurnBarTab.YOU, SwipeDirection.LEADING, allTabs))
    }

    @Test
    fun `adjacent trailing from the first tab returns null`() {
        assertNull(AuroraNavGestureModel.adjacent(BurnBarTab.PULSE, SwipeDirection.TRAILING, allTabs))
    }

    @Test
    fun `adjacent sweeps forward through the entire order`() {
        var current = allTabs.first()
        for (expected in allTabs.drop(1)) {
            val next = AuroraNavGestureModel.adjacent(current, SwipeDirection.LEADING, allTabs)
            assertSame(expected, next)
            current = next!!
        }
        assertNull(AuroraNavGestureModel.adjacent(current, SwipeDirection.LEADING, allTabs))
    }

    @Test
    fun `adjacent returns null when current is not in the list`() {
        assertNull(AuroraNavGestureModel.adjacent(BurnBarTab.FLEET, SwipeDirection.LEADING, allTabs))
    }

    // ── Swipe direction ──

    @Test
    fun `left swipe returns leading`() {
        assertEquals(SwipeDirection.LEADING, AuroraNavGestureModel.swipeDirection(-60f, 5f, minimumDistance = 40f))
    }

    @Test
    fun `right swipe returns trailing`() {
        assertEquals(SwipeDirection.TRAILING, AuroraNavGestureModel.swipeDirection(60f, 5f, minimumDistance = 40f))
    }

    @Test
    fun `vertical swipe returns null`() {
        assertNull(AuroraNavGestureModel.swipeDirection(10f, 100f, minimumDistance = 40f))
    }

    @Test
    fun `diagonal with vertical dominance returns null`() {
        assertNull(AuroraNavGestureModel.swipeDirection(30f, 80f, minimumDistance = 40f))
    }

    @Test
    fun `below the minimum distance returns null`() {
        assertNull(AuroraNavGestureModel.swipeDirection(20f, 0f, minimumDistance = 40f))
        assertNull(AuroraNavGestureModel.swipeDirection(-35f, 0f, minimumDistance = 40f))
    }

    @Test
    fun `exactly the minimum distance resolves`() {
        assertEquals(SwipeDirection.LEADING, AuroraNavGestureModel.swipeDirection(-40f, 0f, minimumDistance = 40f))
    }
}
