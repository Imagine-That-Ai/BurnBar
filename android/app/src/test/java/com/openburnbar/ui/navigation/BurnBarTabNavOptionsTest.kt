@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for [burnBarTabNavOptions] — the navigation options every
 * tab switch (phone tray + wide-screen rail, via `navigateTo` in
 * `BurnBarNavHost`) uses.
 *
 * Documented Back behavior (intentional change, approved 2026-06-10):
 * because every tab switch pops up to the start destination with
 * `saveState = true`, the back stack holds at most the start destination
 * (Pulse) plus the current tab's entry. System Back from any non-start tab
 * therefore returns to Pulse and then exits the app — it no longer walks
 * back through every previously visited tab. Sub-routes pushed above a tab
 * (e.g. `agent_insights/{slug}`, `cloud_store`) are saved with their tab on
 * switch-away and restored with it on return via `restoreState = true`.
 */
class BurnBarTabNavOptionsTest {
    private val startDestinationId = 0x7F0A0001

    @Test
    fun `tab switch pops up to the start destination so the back stack stays bounded`() {
        val options = burnBarTabNavOptions(startDestinationId)

        assertEquals(startDestinationId, options.popUpToId)
        // Not inclusive: the start destination (Pulse) itself stays on the
        // back stack, so Back from any tab lands on Pulse before exiting.
        assertFalse(options.isPopUpToInclusive())
    }

    @Test
    fun `popped tab state is saved so restoreState has something to restore`() {
        val options = burnBarTabNavOptions(startDestinationId)

        // The previous implementation set restoreState without ever saving —
        // a provable no-op (zero saveState call sites app-wide). These two
        // must hold together for warm tab returns.
        assertTrue(options.shouldPopUpToSaveState())
        assertTrue(options.shouldRestoreState())
    }

    @Test
    fun `reselecting the current tab does not push a duplicate entry`() {
        val options = burnBarTabNavOptions(startDestinationId)

        assertTrue(options.shouldLaunchSingleTop())
    }
}
