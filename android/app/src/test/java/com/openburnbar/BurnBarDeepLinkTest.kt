package com.openburnbar

import com.openburnbar.data.policy.MobileOsDestination
import com.openburnbar.data.policy.MobileOsRouteDecision
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BurnBarDeepLinkTest {
    @After
    fun tearDown() {
        InboxPendingItem.reset()
        OsPendingNavigation.reset()
    }

    @Test
    fun parsesAnInboxItemLink() {
        assertEquals(
            BurnBarDeepLinkRoute.Inbox("inb_abc"),
            BurnBarDeepLink.parse("burnbar://inbox/inb_abc"),
        )
    }

    @Test
    fun parsesTheBareInboxListLink() {
        assertEquals(BurnBarDeepLinkRoute.Inbox(null), BurnBarDeepLink.parse("burnbar://inbox"))
        assertEquals(BurnBarDeepLinkRoute.Inbox(null), BurnBarDeepLink.parse("burnbar://inbox/"))
    }

    @Test
    fun leavesNavGraphDestinationsToNavigationCompose() {
        // These hosts are declared as navDeepLink patterns on their composables.
        // Claiming them here would route them twice.
        assertNull(BurnBarDeepLink.parse("burnbar://pulse"))
        assertNull(BurnBarDeepLink.parse("burnbar://insights/all"))
        assertNull(BurnBarDeepLink.parse("burnbar://assistants/hermes?threadId=t1"))
        assertNull(BurnBarDeepLink.parse("https://burnbar.ai/inbox/inb_abc"))
        assertNull(BurnBarDeepLink.parse(null))
    }

    @Test
    fun rejectsItemIdsThatCouldSpoofRenderedText() {
        assertEquals(BurnBarDeepLinkRoute.Inbox(null), BurnBarDeepLink.parse("burnbar://inbox/${"a".repeat(161)}"))
        assertEquals(BurnBarDeepLinkRoute.Inbox(null), BurnBarDeepLink.parse("burnbar://inbox/inb_‮abc"))
    }

    @Test
    fun buildsLinksThatRoundTripThroughTheParser() {
        assertEquals("burnbar://inbox/inb_abc", BurnBarDeepLink.inboxURL("inb_abc"))
        assertEquals("burnbar://inbox", BurnBarDeepLink.inboxURL(null))
        assertEquals(
            BurnBarDeepLinkRoute.Inbox("inb_abc"),
            BurnBarDeepLink.parse(BurnBarDeepLink.inboxURL("inb_abc")),
        )
    }

    @Test
    fun pendingItemIsClaimedExactlyOnce() {
        // A configuration change re-composes the surface; the second claim must
        // be empty or the app re-navigates away from wherever the user went.
        InboxPendingItem.stash("inb_abc")
        assertEquals("inb_abc", InboxPendingItem.claim())
        assertNull(InboxPendingItem.claim())
    }

    @Test
    fun peekLeavesTheRequestForALaterClaim() {
        // The Inbox surface composes before the store's first Firestore snapshot
        // arrives, so it must be able to look without consuming. A consuming
        // read on that first pass would discard the request and the push would
        // silently open the app to an unselected list.
        InboxPendingItem.stash("inb_abc")
        assertEquals("inb_abc", InboxPendingItem.peek())
        assertEquals("inb_abc", InboxPendingItem.peek())
        assertEquals("inb_abc", InboxPendingItem.claim())
        assertNull(InboxPendingItem.peek())
    }

    @Test
    fun stashEmitsSoAWarmStartPushIsNotMissed() {
        // A second push while the app is already open updates the stash after
        // the Inbox surface has composed. If the stash were a plain field the
        // surface would never re-read it and the tap would do nothing.
        val observed = mutableListOf<String?>()
        InboxPendingItem.stash("inb_first")
        observed.add(InboxPendingItem.pending.value)
        InboxPendingItem.claim()
        InboxPendingItem.stash("inb_second")
        observed.add(InboxPendingItem.pending.value)
        assertEquals(listOf("inb_first", "inb_second"), observed)
    }

    @Test
    fun deviceApprovalPendingNavigationStashesYouTab() {
        OsPendingNavigation.request(
            MobileOsRouteDecision(
                destination = MobileOsDestination.DEVICES,
                deviceId = "mac_mini_1",
            ),
        )
        val pending = OsPendingNavigation.pending.value
        assertEquals(MobileOsDestination.DEVICES, pending?.destination)
        assertEquals("you", pending?.route)
        assertEquals(MobileOsDestination.DEVICES, OsPendingNavigation.claim()?.destination)
        assertNull(OsPendingNavigation.claim())
    }
}
