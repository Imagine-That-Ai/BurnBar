package com.openburnbar.services.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentReplyConsumedStoreTest {
    @Test
    fun persistAndBindAreUidScoped() {
        val store = mutableMapOf<String, String>()
        AgentReplyConsumedStore.lastConsumedEventId = null
        AgentReplyConsumedStore.persistConsumedTo(store, "evt-1", null)
        assertEquals("evt-1", AgentReplyConsumedStore.lastConsumedEventId)
        assertTrue(store.isEmpty())

        AgentReplyConsumedStore.persistConsumedTo(store, "evt-a", "uid-a")
        AgentReplyConsumedStore.persistConsumedTo(store, "evt-b", "uid-b")
        assertEquals("last_consumed_uid-a", AgentReplyConsumedStore.consumedKey("uid-a"))
        assertEquals("evt-a", store[AgentReplyConsumedStore.consumedKey("uid-a")])
        assertEquals("evt-b", store[AgentReplyConsumedStore.consumedKey("uid-b")])

        assertEquals("evt-a", AgentReplyConsumedStore.bindConsumedFrom(store, "uid-a"))
        assertEquals("evt-a", AgentReplyConsumedStore.lastConsumedEventId)
        assertNull(AgentReplyConsumedStore.bindConsumedFrom(store, "uid-missing"))
        assertNull(AgentReplyConsumedStore.lastConsumedEventId)
        assertNull(AgentReplyConsumedStore.bindConsumedFrom(store, null))
    }

    @Test
    fun shouldClearLastConsumedOnlyWhenBoundUidMatchesTombstone() {
        assertTrue(AgentReplyConsumedStore.shouldClearLastConsumed("uid-a", "uid-a"))
        assertFalse(AgentReplyConsumedStore.shouldClearLastConsumed("uid-a", "uid-b"))
        assertFalse(AgentReplyConsumedStore.shouldClearLastConsumed("uid-a", null))
    }
}
