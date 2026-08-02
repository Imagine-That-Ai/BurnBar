package com.openburnbar.data.square

import org.junit.Assert.assertEquals
import org.junit.Test

class ThreadInboxRefreshRetryPolicyTest {
    @Test
    fun `backoff doubles per failure`() {
        assertEquals(2_000L, inboxRefreshRetryDelayMillis(1))
        assertEquals(4_000L, inboxRefreshRetryDelayMillis(2))
        assertEquals(8_000L, inboxRefreshRetryDelayMillis(3))
    }

    @Test
    fun `backoff is clamped for out-of-range failure counts`() {
        assertEquals(2_000L, inboxRefreshRetryDelayMillis(0))
        assertEquals(2_000L, inboxRefreshRetryDelayMillis(-5))
        assertEquals(8_000L, inboxRefreshRetryDelayMillis(INBOX_REFRESH_MAX_RETRIES + 10))
    }

    @Test
    fun `retry budget stays bounded`() {
        assertEquals(3, INBOX_REFRESH_MAX_RETRIES)
    }
}
