package com.openburnbar.ui.navigation

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Material 3 width breakpoints every adaptive surface branches on.
 *
 * `calculate` is pure, so the boundaries are pinned here rather than left to an
 * emulator: an off-by-one at 600dp or 840dp silently gives tablets a phone layout,
 * and that is not something a screenshot test would obviously catch.
 */
class BurnBarWindowSizeClassTest {

    // MARK: Breakpoints

    /// The exact boundary values, from both sides. 600 and 840 are inclusive lower
    /// bounds of MEDIUM and EXPANDED respectively.
    @Test
    fun `breakpoints are half-open at 600 and 840`() {
        assertEquals(BurnBarWindowWidthClass.COMPACT, BurnBarWindowSizeClass.calculate(599.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.MEDIUM, BurnBarWindowSizeClass.calculate(600.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.MEDIUM, BurnBarWindowSizeClass.calculate(839.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.EXPANDED, BurnBarWindowSizeClass.calculate(840.dp).widthClass)
    }

    @Test
    fun `representative devices land in the expected class`() {
        // Phone portrait, phone landscape, tablet portrait, tablet landscape.
        assertEquals(BurnBarWindowWidthClass.COMPACT, BurnBarWindowSizeClass.calculate(360.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.MEDIUM, BurnBarWindowSizeClass.calculate(673.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.MEDIUM, BurnBarWindowSizeClass.calculate(800.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.EXPANDED, BurnBarWindowSizeClass.calculate(1280.dp).widthClass)
    }

    /// Degenerate widths must still classify rather than throw — a 0dp measure pass
    /// happens during layout, and it should read as the narrowest class, not crash.
    @Test
    fun `zero and negative widths fall back to compact`() {
        assertEquals(BurnBarWindowWidthClass.COMPACT, BurnBarWindowSizeClass.calculate(0.dp).widthClass)
        assertEquals(BurnBarWindowWidthClass.COMPACT, BurnBarWindowSizeClass.calculate((-100).dp).widthClass)
    }

    @Test
    fun `calculate preserves the measured width alongside the class`() {
        val sizeClass = BurnBarWindowSizeClass.calculate(712.dp)
        assertEquals(712.dp, sizeClass.widthDp)
        assertEquals(BurnBarWindowWidthClass.MEDIUM, sizeClass.widthClass)
    }

    // MARK: Convenience predicates

    /// `isWide` is the one predicate that groups two classes, so it is the easy one
    /// to get backwards — MEDIUM is wide, and only COMPACT is not.
    @Test
    fun `isWide covers medium and expanded but never compact`() {
        assertFalse(BurnBarWindowWidthClass.COMPACT.isWide)
        assertTrue(BurnBarWindowWidthClass.MEDIUM.isWide)
        assertTrue(BurnBarWindowWidthClass.EXPANDED.isWide)
    }

    @Test
    fun `each class reports exactly one identity predicate`() {
        for (widthClass in BurnBarWindowWidthClass.entries) {
            val flags = listOf(widthClass.isCompact, widthClass.isMedium, widthClass.isExpanded)
            assertEquals("$widthClass must match exactly one predicate", 1, flags.count { it })
        }
    }

    /// The default the CompositionLocal hands out before a real measurement arrives.
    /// It must be the narrowest class, so a first frame never over-commits to a
    /// wide layout it then has to tear down.
    @Test
    fun `the composition local default is a compact phone width`() {
        val fallback = LocalWindowSizeClass.value
        assertEquals(BurnBarWindowWidthClass.COMPACT, fallback.widthClass)
        assertTrue(fallback.widthDp < 600.dp)
    }
}
