
package com.openburnbar.ui.navigation

import com.openburnbar.ui.components.AuroraNavDestination
import com.openburnbar.ui.components.FloatingChatMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Contract tests for the pure navigation logic `BurnBarNavHost` owns: the
 * [BurnBarTab] route table (deep-link addressable via `burnbar://`), the
 * route → tab resolution that picks the highlighted tab, and the
 * [FloatingChatState] pill state machine the host keeps alive across tab
 * switches. The nav-options side of every tab switch (pop-with-save +
 * restore) is pinned separately in [BurnBarTabNavOptionsTest].
 */
class BurnBarNavHostTest {
    @Test
    fun `the tab catalog exposes six unique deep-link routes`() {
        val routes = BurnBarTab.allCandidates.map { it.route }

        assertEquals(listOf("pulse", "burn", "insights", "streams", "hermes", "you"), routes)
        assertEquals(routes.size, routes.toSet().size)
    }

    @Test
    fun `pulse is the start destination tab`() {
        // BurnBarNavHost falls back to PULSE for unknown routes and
        // burnBarTabNavOptions pops up to it on every tab switch — it must
        // stay first in the catalog.
        assertSame(BurnBarTab.PULSE, BurnBarTab.allCandidates.first())
        assertEquals("pulse", BurnBarTab.PULSE.route)
    }

    @Test
    fun `fromRoute resolves every catalog route to its own tab`() {
        for (tab in BurnBarTab.allCandidates) {
            assertSame(tab, BurnBarTab.fromRoute(tab.route))
        }
    }

    @Test
    fun `fromRoute rejects null and unknown routes`() {
        assertNull(BurnBarTab.fromRoute(null))
        assertNull(BurnBarTab.fromRoute("not-a-tab"))
        // Sub-routes hosted under the Store tab are not tabs themselves: the
        // signed-in shell maps them to YOU explicitly in its currentTab
        // `when`, so fromRoute must keep returning null for them.
        assertNull(BurnBarTab.fromRoute("cloud_store"))
        assertNull(BurnBarTab.fromRoute("computer_use_agent"))
    }

    @Test
    fun `the assistants tab keeps the hermes route for deep-link stability`() {
        // Plan 2 renamed the tab "Assistants" but `burnbar://hermes` and
        // bookmarks must keep resolving to the same destination.
        assertEquals("hermes", BurnBarTab.HERMES.route)
        assertEquals("Assistants", BurnBarTab.HERMES.label)
        assertEquals(AuroraNavDestination.HERMES, BurnBarTab.HERMES.destination)
    }

    @Test
    fun `each tab maps to a distinct aurora destination`() {
        val destinations = BurnBarTab.allCandidates.map { it.destination }

        assertEquals(destinations.size, destinations.toSet().size)
    }

    @Test
    fun `tab customization merge never drops a tab`() {
        // `all` reorders from the visual settings but re-appends anything the
        // stored keys miss ("Add any missing"), so every candidate survives
        // exactly once no matter what preference string is stored.
        val all = BurnBarTab.all

        assertEquals(BurnBarTab.allCandidates.size, all.size)
        assertEquals(BurnBarTab.allCandidates.toSet(), all.toSet())
    }

    @Test
    fun `the floating chat pill starts idle and empty`() {
        val state = FloatingChatState()

        assertEquals(FloatingChatMode.Idle, state.mode)
        assertEquals("", state.snippet)
    }

    @Test
    fun `startStreaming enters streaming mode with the live snippet`() {
        val state = FloatingChatState()

        state.startStreaming("Burn rate is trending down…")

        assertEquals(FloatingChatMode.Streaming, state.mode)
        assertEquals("Burn rate is trending down…", state.snippet)
    }

    @Test
    fun `show parks the pill idle with the last reply snippet`() {
        val state = FloatingChatState()
        state.startStreaming("partial")

        state.show("Done — saved to Insights.")

        assertEquals(FloatingChatMode.Idle, state.mode)
        assertEquals("Done — saved to Insights.", state.snippet)
    }

    @Test
    fun `hide hides the pill without clearing the snippet`() {
        val state = FloatingChatState()
        state.show("kept for the next reveal")

        state.hide()

        assertEquals(FloatingChatMode.Hidden, state.mode)
        assertEquals("kept for the next reveal", state.snippet)
    }
}
