@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.ui.hermes

import com.openburnbar.data.hermes.HermesMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * LazyColumn-key stability tests for `HermesViewChatSections`:
 * [hermesChatMessageKey] must stay unique across a mixed id/legacy list and —
 * the property the retry flow depends on — keep every surviving message's key
 * identical when the list is truncated and re-appended, so Compose reuses
 * their item state instead of remounting the transcript.
 */
class HermesViewChatSectionsTest {
    private fun message(id: String, content: String = "m") = HermesMessage(id = id, content = content)

    @Test
    fun `keys for a mixed id and legacy list are all unique`() {
        val messages = listOf(
            message(id = "a"),
            message(id = ""),
            message(id = "b"),
            message(id = ""),
        )
        val keys = messages.mapIndexed { index, msg -> hermesChatMessageKey(index, msg) }
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun `retry truncation keeps surviving keys stable`() {
        val before = listOf(message("m-1"), message("m-2"), message("m-3"), message("m-4"))
        // Retry drops the failed tail and re-appends a fresh streaming row.
        val after = listOf(message("m-1"), message("m-2"), message("m-5"))

        for (index in 0 until 2) {
            assertEquals(
                "surviving message ${before[index].id} must keep its key",
                hermesChatMessageKey(index, before[index]),
                hermesChatMessageKey(index, after[index]),
            )
        }
        assertNotEquals(
            hermesChatMessageKey(2, before[2]),
            hermesChatMessageKey(2, after[2]),
        )
    }

    @Test
    fun `identified messages key on the id independent of position`() {
        val msg = message("stable-id")
        // A mid-list deletion shifts positions; the id-keyed row must not care.
        assertEquals(hermesChatMessageKey(3, msg), hermesChatMessageKey(0, msg))
        assertEquals("stable-id", hermesChatMessageKey(7, msg))
    }

    @Test
    fun `legacy empty ids fall back to a positional key`() {
        val legacy = message(id = "")
        assertEquals("hermes-msg-4", hermesChatMessageKey(4, legacy))
        assertNotEquals(hermesChatMessageKey(4, legacy), hermesChatMessageKey(5, legacy))
    }
}
