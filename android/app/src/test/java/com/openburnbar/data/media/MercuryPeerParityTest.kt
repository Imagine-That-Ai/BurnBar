package com.openburnbar.data.media

import com.openburnbar.data.policy.MobileMercuryMediaPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MercuryPeerParityTest {
    @Test
    fun unknownCapabilityIsFiltered() {
        val filtered = MercuryPeer.Feature.filterKnown(
            listOf("mirror.host", "future.teleport", "call.receive", "not-a-capability"),
        )
        assertEquals(
            setOf(MercuryPeer.Feature.MIRROR_HOST, MercuryPeer.Feature.CALL_RECEIVE),
            filtered,
        )
    }

    @Test
    fun denialIsNeverConnected() {
        val peer = MercuryPeerSource.resolve(
            connectionID = "conn-1",
            displayName = "Alberto's Mac",
            phase = MediaControlStreamCoordinator.Phase.Live,
            lastSeenAtMillis = 1L,
            heartbeatCapabilities = listOf("mirror.host"),
            denied = true,
        )
        requireNotNull(peer)
        assertFalse(peer.isOnline)
        assertEquals(
            "denied",
            MobileMercuryMediaPolicy.sessionPresentation("live", denied = true).wire,
        )
    }

    @Test
    fun reconnectPresentationIsNotConnected() {
        val peer = MercuryPeerSource.resolve(
            connectionID = "conn-1",
            displayName = "Alberto's Mac",
            phase = MediaControlStreamCoordinator.Phase.Reconnecting(1_000L, "lost"),
            lastSeenAtMillis = 1L,
            heartbeatCapabilities = MercuryPeer.macFallbackCapabilities.map { it.raw },
            denied = false,
        )
        requireNotNull(peer)
        assertFalse(peer.isOnline)
        assertEquals(
            "reconnecting",
            MobileMercuryMediaPolicy.sessionPresentation("reconnecting", denied = false).wire,
        )
    }

    @Test
    fun livePeerAdvertisesFilteredCapabilities() {
        val peer = MercuryPeerSource.resolve(
            connectionID = "conn-1",
            displayName = "Alberto's Mac",
            phase = MediaControlStreamCoordinator.Phase.Live,
            lastSeenAtMillis = 9L,
            heartbeatCapabilities = listOf("mirror.host", "file.receive", "mystery"),
            denied = false,
        )
        requireNotNull(peer)
        assertTrue(peer.isOnline)
        assertTrue(peer.canRequestMirror)
        assertTrue(peer.canSendFile)
        assertFalse(peer.canPlaceCall)
    }

    @Test
    fun heartbeatIntervalIsSixtySeconds() {
        assertEquals(60_000L, MobileMercuryMediaPolicy.HEARTBEAT_INTERVAL_MS)
    }
}
