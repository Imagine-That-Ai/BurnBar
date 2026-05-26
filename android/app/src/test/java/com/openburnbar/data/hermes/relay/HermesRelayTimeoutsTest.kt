package com.openburnbar.data.hermes.relay

import org.junit.Assert.assertEquals
import org.junit.Test

class HermesRelayTimeoutsTest {

    @Test
    fun longRelayTimeoutsAreHonoredForAgentChatWindows() {
        val now = 1_000L

        assertEquals(601_000L, HermesRelayTimeouts.deadlineMillis(now, 600_000L))
        assertEquals(631_000L, HermesRelayTimeouts.expiresAtMillis(now, 600_000L))
    }

    @Test
    fun invalidRelayTimeoutsFallBackToDefaultWindow() {
        val now = 1_000L

        assertEquals(31_000L, HermesRelayTimeouts.deadlineMillis(now, 0L))
        assertEquals(61_000L, HermesRelayTimeouts.expiresAtMillis(now, -1L))
    }
}
