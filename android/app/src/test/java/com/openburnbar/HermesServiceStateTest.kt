package com.openburnbar

import com.openburnbar.data.hermes.ChatTilePreferences
import com.openburnbar.data.hermes.ConnectionType
import com.openburnbar.data.hermes.HermesConnection
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesRelayCapability
import com.openburnbar.data.hermes.HermesRuntimeModelOption
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.HermesServiceEndpointSupport
import com.openburnbar.data.hermes.addDirectConnection
import com.openburnbar.data.hermes.clearMessages
import com.openburnbar.data.hermes.refreshRelayConnections
import com.openburnbar.data.hermes.revokeConnection
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioral tests for HermesService state transitions that don't require
 * an Android Context. Uses the no-arg constructor (context=null) so we
 * exercise the pure in-memory paths.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HermesServiceStateTest {
    @Test
    fun `initial state surfaces local default connection`() = runTest {
        val service = HermesService()
        try {
            val selected = service.selectedConnection.value
            assertEquals(HermesConnectionRecord.localDefault.id, selected.id)
            assertEquals(HermesConnectionMode.LOCAL, selected.mode)
            assertFalse(service.isStreaming.value)
            assertTrue(service.connections.value.any { it.id == HermesConnectionRecord.localDefault.id })
            // No Context, no relay client → relay capability reports NOT_IMPLEMENTED.
            assertEquals(HermesRelayCapability.NOT_IMPLEMENTED, service.relayCapability.value)
            assertNull(service.currentConversationID.value)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `addDirectConnection appends and selects on trusted HTTPS URL`() = runTest {
        val service = HermesService()
        try {
            val record = requireNotNull(service.addDirectConnection("Test", "https://192.168.1.10:8642"))
            assertEquals(HermesConnectionMode.DIRECT_URL, record.mode)
            assertEquals("https://192.168.1.10:8642", record.endpointURL)
            assertTrue(service.connections.value.any { it.id == record.id })
            assertEquals(record.id, service.selectedConnection.value.id)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `addDirectConnection accepts loopback HTTP for local development`() = runTest {
        val service = HermesService()
        try {
            val record = requireNotNull(service.addDirectConnection("Local", "localhost:8642"))
            assertEquals(HermesConnectionMode.DIRECT_URL, record.mode)
            assertEquals("http://localhost:8642", record.endpointURL)
            assertEquals(record.id, service.selectedConnection.value.id)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `addDirectConnection rejects plaintext LAN endpoints`() = runTest {
        val service = HermesService()
        try {
            val record = service.addDirectConnection("LAN", "http://192.168.1.10:8642")
            assertNull(record)
            assertEquals(HermesConnectionRecord.localDefault.id, service.selectedConnection.value.id)
            assertEquals(HermesServiceEndpointSupport.UNTRUSTED_DIRECT_ENDPOINT_MESSAGE, service.runtimeErrorText.value)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `addDirectConnection rejects plaintext hostname that starts like loopback`() = runTest {
        val service = HermesService()
        try {
            val record = service.addDirectConnection("Spoofed loopback", "http://127.evil.com:8642")
            assertNull(record)
            assertEquals(HermesConnectionRecord.localDefault.id, service.selectedConnection.value.id)
            assertEquals(HermesServiceEndpointSupport.UNTRUSTED_DIRECT_ENDPOINT_MESSAGE, service.runtimeErrorText.value)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `addDirectConnection rejects plaintext websocket endpoints off loopback`() = runTest {
        val service = HermesService()
        try {
            val record = service.addDirectConnection("LAN socket", "ws://192.168.1.10:8642")
            assertNull(record)
            assertEquals(HermesConnectionRecord.localDefault.id, service.selectedConnection.value.id)
            assertEquals(HermesServiceEndpointSupport.UNTRUSTED_DIRECT_ENDPOINT_MESSAGE, service.runtimeErrorText.value)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `endpoint policy rejects unsafe preexisting and legacy LAN endpoints`() {
        val unsafeDirect =
            HermesConnectionRecord(
                id = "unsafe-direct",
                displayName = "Unsafe Direct",
                mode = HermesConnectionMode.DIRECT_URL,
                endpointURL = "http://192.168.1.10:8642",
            )

        assertNull(HermesServiceEndpointSupport.selectedEndpointURL(unsafeDirect))
        assertNull(
            HermesServiceEndpointSupport.legacyEndpointURL(
                HermesConnection(type = ConnectionType.LAN, host = "192.168.1.10", port = 8642),
            ),
        )
        assertEquals(
            "http://127.0.0.1:8642",
            HermesServiceEndpointSupport.selectedEndpointURL(HermesConnectionRecord.localDefault),
        )
    }

    @Test
    fun `addDirectConnection returns null for empty url`() = runTest {
        val service = HermesService()
        try {
            val record = service.addDirectConnection("Empty", "")
            assertNull(record)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `clearMessages resets streaming and thread`() = runTest {
        val service = HermesService()
        try {
            service.clearMessages()
            assertTrue(service.messages.value.isEmpty())
            assertFalse(service.isStreaming.value)
            assertNull(service.currentThreadID.value)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `revokeConnection ignores the local default`() = runTest {
        val service = HermesService()
        try {
            service.revokeConnection(HermesConnectionRecord.localDefault)
            assertTrue(
                "Local default should remain after revoke attempt",
                service.connections.value.any { it.id == HermesConnectionRecord.localDefault.id },
            )
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `revokeConnection removes a direct connection and falls back to local default`() = runTest {
        val service = HermesService()
        try {
            val record = requireNotNull(service.addDirectConnection("Drop", "https://192.168.1.20:8642"))
            service.revokeConnection(record)
            assertFalse(service.connections.value.any { it.id == record.id })
            assertEquals(HermesConnectionRecord.localDefault.id, service.selectedConnection.value.id)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `refreshRelayConnections without a relay client stays NOT_IMPLEMENTED`() = runTest {
        val service = HermesService()
        try {
            service.refreshRelayConnections()
            assertEquals(HermesRelayCapability.NOT_IMPLEMENTED, service.relayCapability.value)
            assertTrue(service.relayConnections.value.isEmpty())
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `connectToSuggestedRelay selects correct online relay connection`() = runTest {
        val mockRelayClient = io.mockk.mockk<com.openburnbar.data.hermes.relay.HermesRelayClient>()
        io.mockk.every { mockRelayClient.isUsable() } returns true

        val descriptors =
            listOf(
                com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor(
                    id = "mac-relay-1",
                    displayName = "Alberto's Mac",
                    relayPublicKey = "somekey",
                    capabilities = listOf("cli_agent_chat"),
                    status = "online",
                    updatedAt = 1000L,
                ),
                com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor(
                    id = "mac-relay-2",
                    displayName = "Older Mac",
                    relayPublicKey = "somekey2",
                    capabilities = listOf("cli_agent_chat"),
                    status = "online",
                    updatedAt = 500L,
                ),
            )
        io.mockk.coEvery { mockRelayClient.listConnections() } returns descriptors

        val service = HermesService(relayClient = mockRelayClient)
        try {
            service.refreshRelayConnections()

            // It should successfully identify the fresh suggested relay (mac-relay-1 has larger updatedAt/lastSeenAt)
            val suggested = requireNotNull(service.suggestedRelayConnection)
            assertEquals("mac-relay-1", suggested.id)

            // When connecting to suggested relay, selectedConnection changes to mac-relay-1
            val connected = service.connectToSuggestedRelay(refresh = false)
            assertTrue(connected)
            assertEquals("mac-relay-1", service.selectedConnection.value.id)
        } finally {
            service.destroy()
        }
    }

    @Test
    fun preferenceActionsSelectAndToggleFavoriteModels() {
        val service = HermesService()
        try {
            val option = HermesRuntimeModelOption(
                providerID = "anthropic",
                providerName = "Anthropic",
                modelID = "claude-opus",
                displayName = "Opus",
            )
            service.preferenceActions.selectModel(option)
            assertEquals("claude-opus", service.selectedModelID.value)
            service.preferenceActions.toggleFavoriteModel(option)
            assertTrue(service.favoriteModelIDs.value.contains("claude-opus"))
            service.preferenceActions.toggleFavoriteModel(option)
            assertFalse(service.favoriteModelIDs.value.contains("claude-opus"))
            service.preferenceActions.setChatTilePreferences(ChatTilePreferences(enabledTiles = emptySet()))
            assertTrue(service.chatTilePreferencesInternal.enabledTiles.isNotEmpty())
        } finally {
            service.destroy()
        }
    }
}
