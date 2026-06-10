package com.openburnbar.ui.hermes

import com.openburnbar.data.computeruse.PhoneControlSystemPermissionKind
import com.openburnbar.data.computeruse.SystemPermissionItem
import com.openburnbar.data.computeruse.SystemPermissionStatus
import com.openburnbar.data.hermes.HermesMessage
import com.openburnbar.data.hermes.ToolCall
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class HermesChatPermissionIndexTest {
    private fun item(toolCallId: String?, id: String = "item-$toolCallId", threadId: String = "thread-1") =
        SystemPermissionItem(
            id = id,
            threadId = threadId,
            kind = PhoneControlSystemPermissionKind.CAMERA,
            bundleId = null,
            status = SystemPermissionStatus.NEEDS_ACCESS,
            originatingToolCallId = toolCallId,
            originatingToolName = null,
            deepLink = null,
            instructions = null,
            failureCategory = null,
            lastChangedAtMillis = 0L,
            source = SystemPermissionItem.Source.MAC_STRUCTURED,
        )

    private fun inbox(vararg items: SystemPermissionItem): Map<String, Map<String, SystemPermissionItem>> =
        items.groupBy { it.threadId }.mapValues { (_, threadItems) ->
            threadItems.withIndex().associate { (index, item) -> "$index" to item }
        }

    @Test
    fun indexScopesToTheRequestedThread() {
        val mine = item("tc-1")
        val other = item("tc-2", threadId = "thread-2")
        val index = systemPermissionItemsByToolCallId(inbox(mine, other), "thread-1")
        assertEquals(mapOf("tc-1" to mine), index)
        assertEquals(emptyMap<String, SystemPermissionItem>(), systemPermissionItemsByToolCallId(inbox(mine), "thread-3"))
    }

    @Test
    fun indexSkipsItemsWithoutAnOriginatingToolCall() {
        // Items without an originating tool call never matched a bubble before.
        val index = systemPermissionItemsByToolCallId(inbox(item(null), item("tc-1")), "thread-1")
        assertEquals(setOf("tc-1"), index.keys)
    }

    @Test
    fun indexKeepsTheFirstItemOnDuplicateToolCallIds() {
        // The replaced inline predicate used firstOrNull over inbox order.
        val first = item("tc-1", id = "first")
        val second = item("tc-1", id = "second")
        val index = systemPermissionItemsByToolCallId(inbox(first, second), "thread-1")
        assertSame(first, index["tc-1"])
    }

    @Test
    fun matchesByMessageIdAndByToolCallId() {
        val byMessage = item("msg-1")
        val byToolCall = item("tc-9")
        val index = systemPermissionItemsByToolCallId(inbox(byMessage, byToolCall), "thread-1")
        assertSame(byMessage, matchingSystemPermissionItem(index, HermesMessage(id = "msg-1")))
        assertSame(
            byToolCall,
            matchingSystemPermissionItem(index, HermesMessage(id = "msg-2", toolCalls = listOf(ToolCall(id = "tc-9")))),
        )
        assertNull(matchingSystemPermissionItem(index, HermesMessage(id = "msg-3", toolCalls = listOf(ToolCall(id = "tc-0")))))
    }

    @Test
    fun matchesExactlyLikeTheInlinePredicateItReplaced() {
        val items = listOf(item("a"), item(null), item("b"))
        val messages = listOf(
            HermesMessage(id = "a"),
            HermesMessage(id = "m1", toolCalls = listOf(ToolCall(id = "b"))),
            HermesMessage(id = "m2", toolCalls = listOf(ToolCall(id = "c"))),
            HermesMessage(id = ""),
        )
        val index = systemPermissionItemsByToolCallId(inbox(*items.toTypedArray()), "thread-1")
        for (message in messages) {
            val legacy = items.firstOrNull { item ->
                item.originatingToolCallId == message.id ||
                    message.toolCalls.any { tc -> tc.id == item.originatingToolCallId }
            }
            assertEquals(legacy, matchingSystemPermissionItem(index, message))
        }
    }
}
