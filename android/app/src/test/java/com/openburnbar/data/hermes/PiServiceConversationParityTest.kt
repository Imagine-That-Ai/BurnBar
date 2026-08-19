package com.openburnbar.data.hermes

import com.openburnbar.data.policy.MobileHermesConversationPolicy
import com.openburnbar.data.policy.MobileHermesStreamTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PiServiceConversationParityTest {
    @Test
    fun cancelKeepsPartialAndDoesNotMarkError() {
        val service = PiService()
        service.stageStreamingForTest("Partial reply")
        service.cancel()
        val last = service.messages.value.last()
        assertFalse(service.isStreaming.value)
        assertEquals("Partial reply", last.content)
        assertFalse(last.isStreaming)
        assertFalse(last.isError)
        assertEquals(
            MobileHermesConversationPolicy.terminal("stop"),
            MobileHermesStreamTerminal.STOPPED,
        )
    }

    @Test
    fun cancelDropsEmptyAssistantWithoutToolCalls() {
        val service = PiService()
        service.stageStreamingForTest("")
        service.cancel()
        assertTrue(service.messages.value.none { it.role == "assistant" })
        assertEquals("hello", service.messages.value.single().content)
    }

    @Test
    fun cancelKeepsToolCallTurn() {
        val service = PiService()
        service.stageStreamingForTest(
            text = "",
            toolCalls = listOf(PiToolCall(id = "t1", name = "search", status = "running", arguments = "{}", detail = null)),
        )
        service.cancel()
        val last = service.messages.value.last()
        assertEquals("assistant", last.role)
        assertEquals(1, last.toolCalls.size)
        assertFalse(last.isStreaming)
        assertFalse(last.isError)
    }

    @Test
    fun missingConversationDeepLinkIsHonest() {
        val service = PiService()
        val outcome = service.loadThread("thread-missing")
        assertEquals("missing", outcome)
        assertTrue(service.messages.value.isEmpty())
        assertEquals(
            "This conversation is no longer on this device.",
            service.runtimeErrorText.value,
        )
    }

    @Test
    fun reconnectDoesNotDuplicateUser() {
        val service = PiService()
        service.stageStreamingForTest(text = "", userText = "Continue the draft")
        service.cancel()
        assertEquals(1, service.messages.value.count { it.role == "user" })
        service.send("Continue the draft")
        assertEquals(1, service.messages.value.count { it.role == "user" })
    }
}
