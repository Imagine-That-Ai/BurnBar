package com.openburnbar

import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesRelayCapability
import com.openburnbar.data.hermes.HermesService
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
    fun `addDirectConnection appends and selects on valid URL`() = runTest {
        val service = HermesService()
        try {
            val record = service.addDirectConnection("Test", "http://192.168.1.10:8642")
            assertNotNull(record)
            assertEquals(HermesConnectionMode.DIRECT_URL, record!!.mode)
            assertTrue(service.connections.value.any { it.id == record.id })
            assertEquals(record.id, service.selectedConnection.value.id)
        } finally {
            service.destroy()
        }
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
                service.connections.value.any { it.id == HermesConnectionRecord.localDefault.id }
            )
        } finally {
            service.destroy()
        }
    }

    @Test
    fun `revokeConnection removes a direct connection and falls back to local default`() = runTest {
        val service = HermesService()
        try {
            val record = service.addDirectConnection("Drop", "http://192.168.1.20:8642")
            assertNotNull(record)
            service.revokeConnection(record!!)
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
}
