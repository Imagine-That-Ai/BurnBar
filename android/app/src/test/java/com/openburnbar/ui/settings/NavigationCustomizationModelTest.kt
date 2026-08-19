package com.openburnbar.ui.settings

import com.openburnbar.ui.navigation.BurnBarTab
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guard-rule tests for the Navigation settings screen's pure model:
 * clamped reorder, the permanent `you` tab, the minimum tray size, and the
 * addable catalog (which is where Fleet enters the tray).
 */
class NavigationCustomizationModelTest {
    private val defaults = BurnBarTab.allCandidates.map { it.route }

    // ── Reorder ──

    @Test
    fun `moved swaps neighbours and clamps at the edges`() {
        assertEquals(
            listOf("burn", "pulse", "inbox"),
            NavigationCustomizationModel.moved(listOf("pulse", "burn", "inbox"), index = 0, delta = 1),
        )
        assertEquals(
            listOf("pulse", "inbox", "burn"),
            NavigationCustomizationModel.moved(listOf("pulse", "burn", "inbox"), index = 2, delta = -1),
        )
        // Clamped: moving the first row up / the last row down is a no-op.
        assertEquals(defaults, NavigationCustomizationModel.moved(defaults, index = 0, delta = -1))
        assertEquals(defaults, NavigationCustomizationModel.moved(defaults, index = defaults.size - 1, delta = 1))
        // Out-of-range indexes are ignored.
        assertEquals(defaults, NavigationCustomizationModel.moved(defaults, index = 99, delta = -1))
    }

    // ── Remove ──

    @Test
    fun `the you tab can never be removed`() {
        assertFalse(NavigationCustomizationModel.canRemove(defaults, "you"))
        assertEquals(defaults, NavigationCustomizationModel.removed(defaults, "you"))
    }

    @Test
    fun `removal stops at the minimum tray size`() {
        val two = listOf("pulse", "you")

        assertFalse(NavigationCustomizationModel.canRemove(two, "pulse"))
        assertEquals(two, NavigationCustomizationModel.removed(two, "pulse"))

        val three = listOf("pulse", "burn", "you")
        assertTrue(NavigationCustomizationModel.canRemove(three, "pulse"))
        assertEquals(listOf("burn", "you"), NavigationCustomizationModel.removed(three, "pulse"))
    }

    @Test
    fun `a route not in the tray cannot be removed`() {
        assertFalse(NavigationCustomizationModel.canRemove(defaults, "fleet"))
    }

    // ── Add ──

    @Test
    fun `added appends once`() {
        assertEquals(defaults + "fleet", NavigationCustomizationModel.added(defaults, "fleet"))
        assertEquals(defaults, NavigationCustomizationModel.added(defaults, "pulse"))
    }

    @Test
    fun `the addable catalog offers exactly what is not visible`() {
        assertEquals(listOf(BurnBarTab.FLEET), NavigationCustomizationModel.addableTabs(defaults))
        assertEquals(
            emptyList<BurnBarTab>(),
            NavigationCustomizationModel.addableTabs(defaults + "fleet"),
        )
        assertEquals(
            listOf(BurnBarTab.INBOX, BurnBarTab.FLEET),
            NavigationCustomizationModel.addableTabs(defaults - "inbox"),
        )
    }
}
