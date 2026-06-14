package com.openburnbar.data.hermes

import com.openburnbar.data.hermes.relay.HermesRelayClient
import com.openburnbar.data.hermes.relay.HermesRelayException
import com.openburnbar.data.hermes.relay.HermesRelayTransporting
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesServiceMessageLaunchTest {
    @Test
    fun relay_send_failure_surfaces_assistant_error_instead_of_escaping_launch_coroutine() = runBlocking {
        val failure = "Could not verify iroh pairing record: pairing record expired"
        val relayTransport = mockk<HermesRelayTransporting>()
        coEvery { relayTransport.sendStreaming(any(), any(), any()) } throws HermesRelayException(failure)
        val relayClient = mockk<HermesRelayClient> {
            every { isUsable() } returns true
        }
        val service = HermesService(relayClient = relayClient, relayTransport = relayTransport)
        service.connectionsInternal.value = listOf(relayConnection())
        service.selectedConnectionInternal.value = relayConnection()

        try {
            service.sendMessage("hello from android", modelName = "hermes")

            val messages = withTimeout(2_000L) {
                service.messages.first { list -> list.any { it.isError && it.content.contains(failure) } }
            }
            withTimeout(2_000L) { service.isStreaming.first { streaming -> !streaming } }

            assertTrue(messages.any { it.role == "user" && it.content == "hello from android" })
            val assistantError = messages.last()
            assertEquals("assistant", assistantError.role)
            assertTrue(assistantError.isError)
            assertEquals("Error: $failure", assistantError.content)
            assertEquals(failure, service.runtimeErrorText.value)
            assertFalse(service.isStreaming.value)
        } finally {
            service.destroy()
        }
    }

    private fun relayConnection(): HermesConnectionRecord = HermesConnectionRecord(
        id = "conn-expired",
        displayName = "Mac Relay",
        mode = HermesConnectionMode.RELAY_LINK,
        status = HermesConnectionStatus.ONLINE,
        relayPublicKey = "relay-public-key",
    )
}
