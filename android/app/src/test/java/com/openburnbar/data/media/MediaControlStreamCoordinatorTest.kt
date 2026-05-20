package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.IrohRelayStream
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaControlStreamCoordinatorTest {
    @Test
    fun requestMirror_sendsSwiftCompatibleMirrorRequestFrameAfterClassify() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        val requestID = coordinator.requestMirror("Alberto's Android")

        val classify = stream.sent[0]
        assertEquals(HermesRealtimeRelayFrameType.MEDIA_CLASSIFY, classify.type)
        assertEquals(MediaStreamClass.CONTROL.raw, classify.media?.streamClass)

        val mirror = stream.sent[1]
        assertEquals(HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST, mirror.type)
        assertEquals("uid-1", mirror.uid)
        assertEquals("conn-1", mirror.connectionId)
        assertEquals(requestID, mirror.requestId)
        assertEquals(requestID, mirror.media?.mirrorRequest?.requestId)
        assertEquals("Alberto's Android", mirror.media?.mirrorRequest?.requesterDisplayName)
        assertEquals("media.screen.video", mirror.media?.mirrorRequest?.streamClass)
        assertNotNull(mirror.media?.mirrorRequest?.requestedAt)
    }

    @Test
    fun readLoop_publishesMirrorAckForUiStatus() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        val requestID = coordinator.requestMirror("Android")
        stream.incoming.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_ACK,
                uid = "uid-1",
                connectionId = "conn-1",
                requestId = requestID,
                media = HermesRealtimeRelayMediaPayload(
                    mirrorAck = HermesRealtimeRelayMirrorAck(
                        requestId = requestID,
                        decision = HermesRealtimeRelayMirrorAck.Decision.BUSY,
                        detail = "Mac is busy",
                    )
                ),
            )
        )

        kotlinx.coroutines.withTimeout(1_000) {
            while (coordinator.lastMirrorAck.value?.requestId != requestID) {
                kotlinx.coroutines.yield()
            }
        }
        assertEquals(HermesRealtimeRelayMirrorAck.Decision.BUSY, coordinator.lastMirrorAck.value?.decision)
        assertEquals("Mac is busy", coordinator.lastMirrorAck.value?.detail)
    }

    @Test
    fun requestCall_sendsSwiftCompatibleCallInviteFrameAfterClassify() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        val requestID = coordinator.requestCall("Alberto's Android")

        val call = stream.sent[1]
        assertEquals(HermesRealtimeRelayFrameType.MEDIA_CALL_INVITE, call.type)
        assertEquals("uid-1", call.uid)
        assertEquals("conn-1", call.connectionId)
        assertEquals(requestID, call.requestId)
        assertEquals(requestID, call.media?.callInvite?.requestId)
        assertEquals("Alberto's Android", call.media?.callInvite?.requesterDisplayName)
        assertEquals("video", call.media?.callInvite?.callKind)
        assertNotNull(call.media?.callInvite?.requestedAt)
    }

    @Test
    fun readLoop_publishesCallAckForUiStatus() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        val requestID = coordinator.requestCall("Android")
        stream.incoming.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_CALL_ACK,
                uid = "uid-1",
                connectionId = "conn-1",
                requestId = requestID,
                media = HermesRealtimeRelayMediaPayload(
                    callAck = HermesRealtimeRelayCallAck(
                        requestId = requestID,
                        decision = HermesRealtimeRelayCallAck.Decision.ACCEPTED,
                        detail = "Mac accepted",
                    )
                ),
            )
        )

        kotlinx.coroutines.withTimeout(1_000) {
            while (coordinator.lastCallAck.value?.requestId != requestID) {
                kotlinx.coroutines.yield()
            }
        }
        assertEquals(HermesRealtimeRelayCallAck.Decision.ACCEPTED, coordinator.lastCallAck.value?.decision)
        assertEquals("Mac accepted", coordinator.lastCallAck.value?.detail)
    }

    @Test
    fun mediaControlStreamStartsWithoutFileTransferReceiver() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            receiver = null,
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        coordinator.requestMirror("Android")

        assertTrue(stream.sent.any { it.type == HermesRealtimeRelayFrameType.MEDIA_CLASSIFY })
        assertTrue(stream.sent.any { it.type == HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST })
    }

    @Test
    fun activePairReflectsCurrentUidAndConnectionUntilStopped() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")

        assertEquals("uid-1", coordinator.activePair.value?.uid)
        assertEquals("conn-1", coordinator.activePair.value?.connectionID)

        coordinator.stop()

        assertEquals(null, coordinator.activePair.value)
    }

    @Test
    fun start_sendsOutboundPresenceHeartbeatWithAndroidCapabilities() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
            peerDeviceIdProvider = { "android-device-1" },
            displayNameProvider = { "Alberto's Android" },
            presenceHeartbeatIntervalMillis = 50,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")

        kotlinx.coroutines.withTimeout(1_000) {
            while (stream.sent.none { it.type == HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT }) {
                kotlinx.coroutines.yield()
            }
        }

        val heartbeat = stream.sent.first { it.type == HermesRealtimeRelayFrameType.MEDIA_PRESENCE_HEARTBEAT }
        assertEquals("uid-1", heartbeat.uid)
        assertEquals("conn-1", heartbeat.connectionId)
        assertEquals("android-device-1", heartbeat.media?.presence?.peerDeviceId)
        assertEquals("Alberto's Android", heartbeat.media?.presence?.displayName)
        assertTrue(heartbeat.media?.presence?.capabilities?.contains("media.mirror.request") == true)
        assertTrue(heartbeat.media?.presence?.capabilities?.contains("media.call.invite") == true)
        assertTrue(heartbeat.media?.presence?.capabilities?.contains("media.blob.transfer") == true)
        assertNotNull(heartbeat.media?.presence?.sentAt)
    }

    private class RecordingStream : IrohRelayStream {
        val sent = mutableListOf<HermesRealtimeRelayFrame>()
        val incoming = Channel<HermesRealtimeRelayFrame?>(Channel.UNLIMITED)

        override suspend fun send(frame: HermesRealtimeRelayFrame) {
            sent.add(frame)
        }

        override suspend fun receive(): HermesRealtimeRelayFrame? =
            incoming.receiveCatching().getOrNull()

        override suspend fun close() {
            incoming.close()
        }
    }
}
