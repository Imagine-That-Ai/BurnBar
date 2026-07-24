package com.openburnbar.data.computeruse

import org.junit.Assert.assertEquals
import org.junit.Test

class ComputerUseSessionGrantNotificationCenterTest {
    @Test
    fun `dismissing one overlapping challenge preserves the other notification`() {
        val posted = mutableListOf<Pair<String, Long>>()
        val cancelled = mutableListOf<String>()
        val pending =
            PendingSessionGrantNotificationSet(
                post = { challengeId, timeoutMillis -> posted += challengeId to timeoutMillis },
                cancel = { cancelled += it },
            )

        pending.show("challenge-a", 5_000L)
        pending.show("challenge-b", 4_000L)
        pending.show("challenge-b", 3_000L)
        pending.dismiss("challenge-a")

        assertEquals(listOf("challenge-a" to 5_000L, "challenge-b" to 4_000L), posted)
        assertEquals(listOf("challenge-a"), cancelled)

        pending.dismiss("challenge-b")
        assertEquals(listOf("challenge-a", "challenge-b"), cancelled)
    }

    @Test
    fun `notification timeout follows signed expiry and is safely bounded`() {
        assertEquals(5_000L, sessionGrantNotificationTimeoutMillis(expiresAtMillis = 15_000L, nowMillis = 10_000L))
        assertEquals(1L, sessionGrantNotificationTimeoutMillis(expiresAtMillis = 9_999L, nowMillis = 10_000L))
        assertEquals(
            300_000L,
            sessionGrantNotificationTimeoutMillis(expiresAtMillis = 1_000_000L, nowMillis = 10_000L),
        )
    }
}
