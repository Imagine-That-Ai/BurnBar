package com.openburnbar.services.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The `type=ai_inbox_item` push shape is a cross-repo contract with
 * `functions/src/aiInboxNotifications.ts`. Drift in it produces no crash — the
 * notification simply stops arriving — so it is pinned here.
 */
class AIInboxNotificationRoutingTest {
    @Test
    fun routesAP1PushToItsItemDeepLink() {
        val routing =
            aiInboxNotificationRouting(
                mapOf(
                    "type" to "ai_inbox_item",
                    "event_id" to "ai_inbox_inb_abc",
                    "item_id" to "inb_abc",
                    "kind" to "ci_waste",
                    "priority" to "1",
                ),
            )
        assertEquals("inb_abc", routing?.itemId)
        assertEquals("ci_waste", routing?.kind)
        assertEquals("Wasted CI", routing?.title)
        assertEquals("burnbar://inbox/inb_abc", routing?.deepLink)
    }

    @Test
    fun bodyCarriesNoItemContent() {
        // The mirrored item is sealed, so the server cannot supply a summary.
        // Any future attempt to render a payload string as the body would turn
        // this notification into a plaintext channel.
        val routing =
            aiInboxNotificationRouting(
                mapOf(
                    "item_id" to "inb_abc",
                    "kind" to "cost_anomaly",
                    "title" to "Spent $412 on Opus overnight",
                    "preview" to "38 of 40 nightly runs were cancelled",
                ),
            )
        assertEquals("Cost anomaly", routing?.title)
        assertEquals("Open OpenBurnBar to see what needs you.", routing?.body)
    }

    @Test
    fun unknownKindDegradesToSystemRatherThanRenderingRawServerText() {
        val routing = aiInboxNotificationRouting(mapOf("item_id" to "inb_1", "kind" to "kind_from_a_newer_mac"))
        assertEquals("system", routing?.kind)
        assertEquals("OpenBurnBar", routing?.title)
    }

    @Test
    fun dropsPushesThatCannotAddressAnItem() {
        assertNull(aiInboxNotificationRouting(emptyMap()))
        assertNull(aiInboxNotificationRouting(mapOf("item_id" to "   ")))
        assertNull(aiInboxNotificationRouting(mapOf("item_id" to "a".repeat(161))))
        // Bidi override — would let a payload spoof the rendered link.
        assertNull(aiInboxNotificationRouting(mapOf("item_id" to "inb_‮abc")))
    }
}
