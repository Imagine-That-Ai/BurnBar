package com.openburnbar.data.square

import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.data.hermes.HermesConnectionStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairedMacIdentityTest {
    @Test
    fun pairedMacIdentityUsesConnectionScopedURIAndStatus() {
        val identity = AgentIdentity.pairedMac(
            HermesConnectionRecord(
                id = "relay-123",
                displayName = "Alberto's Mac Studio",
                mode = HermesConnectionMode.RELAY_LINK,
                status = HermesConnectionStatus.ONLINE,
                updatedAt = 1234L,
                lastSeenAt = 5678L
            )
        )

        assertEquals("device://paired-mac/relay-123", identity.id)
        assertEquals("Alberto's Mac Studio", identity.displayName)
        assertEquals(AgentAvailability.ONLINE, identity.availability)
        assertEquals(5678L, identity.lastRefreshedAtEpoch)
        assertTrue(identity.tagline.orEmpty().contains("control"))
    }

    @Test
    fun registryUpsertsPairedMacInsteadOfDuplicatingIt() {
        val registry = AgentIdentityRegistry.testInstance()
        val original = HermesConnectionRecord(
            id = "relay-abc",
            displayName = "Mac",
            mode = HermesConnectionMode.RELAY_LINK,
            status = HermesConnectionStatus.ONLINE
        )
        val updated = original.copy(displayName = "MacBook Pro", status = HermesConnectionStatus.OFFLINE)

        registry.upsertPairedMac(original)
        registry.upsertPairedMac(updated)

        val matches = registry.identities.filter { it.id == "device://paired-mac/relay-abc" }
        assertEquals(1, matches.size)
        assertEquals("MacBook Pro", matches.single().displayName)
        assertEquals(AgentAvailability.OFFLINE, matches.single().availability)
    }

    @Test
    fun registryResolvesPersistedPairedMacPinBeforeRelayHydrates() {
        val registry = AgentIdentityRegistry.testInstance()

        val identity = registry.identity("device://paired-mac/relay-late")

        requireNotNull(identity)
        assertEquals("device://paired-mac/relay-late", identity.id)
        assertEquals("My Mac", identity.displayName)
        assertEquals(AgentAvailability.UNKNOWN, identity.availability)
    }

    @Test
    fun pairedMacForcedPinWinsEvenWhenGridIsFull() {
        val fullGrid = PinnedAgentGridConfig(
            pinnedURIs = (0 until PinnedAgentGridConfig.MAX_SLOTS).map { "agent://test/$it" }
        )

        val pinned = fullGrid.pinningPairedMac("device://paired-mac/relay-live")

        assertEquals(PinnedAgentGridConfig.MAX_SLOTS, pinned.pinnedURIs.size)
        assertEquals("device://paired-mac/relay-live", pinned.pinnedURIs.first())
        assertTrue("agent://test/11" !in pinned.pinnedURIs)
    }

    @Test
    fun preferredPairedMacIncludesOfflinePairedRelayButSkipsRevoked() {
        val offline = HermesConnectionRecord(
            id = "relay-offline",
            displayName = "Mac",
            mode = HermesConnectionMode.RELAY_LINK,
            status = HermesConnectionStatus.OFFLINE,
            updatedAt = 2000L
        )
        val revoked = offline.copy(
            id = "relay-revoked",
            status = HermesConnectionStatus.REVOKED,
            updatedAt = 9000L
        )

        val preferred = AgentIdentity.preferredPairedMacConnection(listOf(revoked, offline))

        assertEquals("relay-offline", preferred?.id)
    }

    @Test
    fun preferredPairedMacUsesOnlineRelayBeforeNewerOfflineRelay() {
        val online = HermesConnectionRecord(
            id = "relay-online",
            displayName = "Mac",
            mode = HermesConnectionMode.RELAY_LINK,
            status = HermesConnectionStatus.ONLINE,
            updatedAt = 1000L
        )
        val newerOffline = online.copy(
            id = "relay-offline",
            status = HermesConnectionStatus.OFFLINE,
            updatedAt = 9000L
        )

        val preferred = AgentIdentity.preferredPairedMacConnection(listOf(newerOffline, online))

        assertEquals("relay-online", preferred?.id)
    }
}
