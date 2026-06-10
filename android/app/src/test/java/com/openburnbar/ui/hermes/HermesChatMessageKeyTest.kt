package com.openburnbar.ui.hermes

import com.openburnbar.data.hermes.HermesMessage
import org.junit.Assert.assertEquals
import org.junit.Test

class HermesChatMessageKeyTest {
    @Test
    fun usesTheMessageIdWhenPresent() {
        val message = HermesMessage(id = "abc")
        assertEquals("abc", hermesChatMessageKey(5, message))
        // The key must not depend on position: retry truncates the tail and re-appends,
        // and stale streaming rows are dropped mid-list, shifting later indices.
        assertEquals(hermesChatMessageKey(0, message), hermesChatMessageKey(9, message))
    }

    @Test
    fun emptyLegacyIdsFallBackToUniquePositionalKeys() {
        // Duplicate LazyColumn keys crash at runtime; legacy messages may carry an empty
        // id, so every empty id must still yield a distinct key.
        val messages = List(3) { HermesMessage(id = "") }
        val keys = messages.mapIndexed { index, message -> hermesChatMessageKey(index, message) }
        assertEquals(keys.size, keys.toSet().size)
    }
}
