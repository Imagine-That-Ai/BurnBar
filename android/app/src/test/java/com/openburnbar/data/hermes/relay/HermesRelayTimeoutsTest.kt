package com.openburnbar.data.hermes.relay

import org.junit.Assert.assertEquals
import org.junit.Test

private const val MILLIS = 601_000L
private const val MILLIS_2 = 600_000L
private const val MILLIS_3 = 631_000L
private const val MILLIS_4 = 31_000L
private const val MILLIS_5 = 61_000L

class HermesRelayTimeoutsTest {
    @Test
    fun longRelayTimeoutsAreHonoredForAgentChatWindows() {
        val now = 1_000L

        assertEquals(MILLIS, HermesRelayTimeouts.deadlineMillis(now, MILLIS_2))
        assertEquals(MILLIS_3, HermesRelayTimeouts.expiresAtMillis(now, MILLIS_2))
    }

    @Test
    fun invalidRelayTimeoutsFallBackToDefaultWindow() {
        val now = 1_000L

        assertEquals(MILLIS_4, HermesRelayTimeouts.deadlineMillis(now, 0L))
        assertEquals(MILLIS_5, HermesRelayTimeouts.expiresAtMillis(now, -1L))
    }
}
