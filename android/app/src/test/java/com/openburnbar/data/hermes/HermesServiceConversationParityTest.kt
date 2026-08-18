package com.openburnbar.data.hermes

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HermesServiceConversationParityTest {
    @Test
    fun cancelGenerationKeepsPartialAndIsNotError() = runTest {
        val service = HermesService()
        try {
            service.messagesInternal.value = listOf(
                HermesMessage(role = "user", content = "hello"),
                HermesMessage(role = "assistant", content = "Partial reply", isStreaming = true),
            )
            service.isStreamingInternal.value = true
            service.cancelGeneration()
            val last = service.messages.value.last()
            assertFalse(service.isStreaming.value)
            assertEquals("Partial reply", last.content)
            assertFalse(last.isStreaming)
            assertFalse(last.isError)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun cancelGenerationKeepsToolCalls() = runTest {
        val service = HermesService()
        try {
            service.messagesInternal.value = listOf(
                HermesMessage(role = "user", content = "search"),
                HermesMessage(
                    role = "assistant",
                    content = "",
                    isStreaming = true,
                    toolCalls = listOf(ToolCall(id = "t1", name = "search")),
                ),
            )
            service.isStreamingInternal.value = true
            service.cancelGeneration()
            val last = service.messages.value.last()
            assertEquals(1, last.toolCalls.size)
            assertFalse(last.isStreaming)
            assertFalse(last.isError)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun missingConversationDeepLinkIsHonest() = runTest {
        val service = HermesService()
        try {
            val outcome = service.loadThread("thread-missing")
            assertEquals("missing", outcome)
            assertTrue(service.messages.value.isEmpty())
            assertEquals(
                "This conversation is no longer on this device.",
                service.runtimeErrorText.value,
            )
        } finally {
            service.destroy()
        }
    }

    @Test
    fun malformedAttachmentIsRejected() = runTest {
        val service = HermesService()
        try {
            service.sendMessage(
                content = "see this",
                modelName = "hermes",
                attachments = listOf(
                    HermesAttachment(id = "", fileName = "x.png", mimeType = "image/png", uriString = null),
                ),
            )
            assertTrue(service.messages.value.any { it.isError })
            assertTrue(service.messages.value.any { it.content.contains("malformed") })
            assertFalse(service.isStreaming.value)
        } finally {
            service.destroy()
        }
    }
}
