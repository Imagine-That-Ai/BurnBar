package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayCallAck
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaFrameChunk
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayMirrorAck
import com.openburnbar.irohrelay.IrohRelayStream
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        assertEquals(
            MercuryMediaFrameVersionSupport.V1_AND_V2,
            mirror.media?.mirrorRequest?.streamingCapabilities?.toMercury()?.mediaFrameVersions,
        )
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
        assertEquals("Alberto's Android", heartbeat.media?.presence?.deviceDisplayName)
        assertTrue(heartbeat.media?.presence?.capabilities?.contains("media.mirror.request") == true)
        assertTrue(heartbeat.media?.presence?.capabilities?.contains("media.call.invite") == true)
        assertTrue(heartbeat.media?.presence?.capabilities?.contains("media.blob.transfer") == true)
        assertEquals(
            MercuryMediaFrameVersionSupport.V1_AND_V2,
            heartbeat.media?.presence?.streamingCapabilities?.toMercury()?.mediaFrameVersions,
        )
        assertNotNull(heartbeat.media?.presence?.sentAt)
    }

    @Test
    fun readLoop_routesV1ScreenFramesToMirrorFrameHandler() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )
        val received = CompletableDeferred<MediaFrame>()
        coordinator.mirrorFrameHandler = { frame -> received.complete(frame) }
        val source = MediaFrame(
            kind = MediaFrame.Kind.VIDEO_NAL,
            flags = MediaFrame.Flags.KEYFRAME,
            gopID = 7u,
            frameIndex = 3u,
            presentationTimestampMillis = 123uL,
            payload = byteArrayOf(0x01, 0x02, 0x03),
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        stream.incoming.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
                uid = "uid-1",
                connectionId = "conn-1",
                media = HermesRealtimeRelayMediaPayload(
                    streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                    encodedFrameBase64 = Base64.getEncoder().encodeToString(MediaPacketCodec().encode(source)),
                ),
            )
        )

        val decoded = kotlinx.coroutines.withTimeout(1_000) { received.await() }
        assertEquals(source, decoded)
    }

    @Test
    fun readLoop_routesV2ScreenFramesToMirrorFrameV2HandlerWithoutFallingBackToV1() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )
        val v1Received = CompletableDeferred<MediaFrame>()
        val v2Received = CompletableDeferred<MediaFrameV2>()
        coordinator.mirrorFrameHandler = { frame -> v1Received.complete(frame) }
        coordinator.mirrorFrameV2Handler = { frame -> v2Received.complete(frame) }
        val source = MediaFrameV2(
            kind = MediaFrameV2Kind.VIDEO_NAL,
            flags = 0x0001u,
            gopID = 11u,
            frameIndex = 5u,
            presentationTimestampMillis = 456uL,
            metadata = MediaFrameV2Metadata(
                codec = "hevc",
                longTermReferenceToken = MediaFrameV2LongTermReferenceToken(value = 42L),
            ).encode(),
            payload = byteArrayOf(0x04, 0x05, 0x06),
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        stream.incoming.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
                uid = "uid-1",
                connectionId = "conn-1",
                media = HermesRealtimeRelayMediaPayload(
                    streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                    encodedFrameBase64 = Base64.getEncoder().encodeToString(
                        MediaFrameV2Codec().encode(source, MercuryMediaFrameWireVersion.V2)
                    ),
                ),
            )
        )

        val decoded = kotlinx.coroutines.withTimeout(1_000) { v2Received.await() }
        assertEquals(source, decoded)
        assertFalse(v1Received.isCompleted)
    }

    @Test
    fun readLoop_reassemblesChunkedV2ScreenFramesBeforeDecoding() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )
        val v2Received = CompletableDeferred<MediaFrameV2>()
        coordinator.mirrorFrameV2Handler = { frame -> v2Received.complete(frame) }
        val source = MediaFrameV2(
            kind = MediaFrameV2Kind.VIDEO_NAL,
            gopID = 12u,
            frameIndex = 34u,
            presentationTimestampMillis = 56uL,
            metadata = byteArrayOf(0x01, 0x02),
            payload = ByteArray(700_000) { 0x7A.toByte() },
        )
        val encoded = MediaFrameV2Codec().encode(source, MercuryMediaFrameWireVersion.V2)
        val chunkSize = 100_000
        val chunks = encoded.asList().chunked(chunkSize).map { it.toByteArray() }

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        chunks.asReversed().forEachIndexed { reverseIndex, bytes ->
            val chunkIndex = chunks.lastIndex - reverseIndex
            stream.incoming.send(
                HermesRealtimeRelayFrame(
                    type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
                    uid = "uid-1",
                    connectionId = "conn-1",
                    media = HermesRealtimeRelayMediaPayload(
                        streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                        encodedFrameBase64 = Base64.getEncoder().encodeToString(bytes),
                        frameChunk = HermesRealtimeRelayMediaFrameChunk(
                            chunkId = "frame-1",
                            chunkIndex = chunkIndex,
                            chunkCount = chunks.size,
                            totalBytes = encoded.size,
                        ),
                    ),
                )
            )
        }

        val decoded = kotlinx.coroutines.withTimeout(1_000) { v2Received.await() }
        assertEquals(source, decoded)
    }

    @Test
    fun readLoop_ignoresMalformedStreamFramesAndKeepsControlStreamAlive() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        stream.incoming.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
                uid = "uid-1",
                connectionId = "conn-1",
                media = HermesRealtimeRelayMediaPayload(
                    streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                    encodedFrameBase64 = "not-valid-base64",
                ),
            )
        )
        stream.incoming.send(
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_ACK,
                uid = "uid-1",
                connectionId = "conn-1",
                requestId = "mirror-1",
                media = HermesRealtimeRelayMediaPayload(
                    mirrorAck = HermesRealtimeRelayMirrorAck(
                        requestId = "mirror-1",
                        decision = HermesRealtimeRelayMirrorAck.Decision.ACCEPTED,
                    )
                ),
            )
        )

        kotlinx.coroutines.withTimeout(1_000) {
            while (coordinator.lastMirrorAck.value?.requestId != "mirror-1") {
                kotlinx.coroutines.yield()
            }
        }
        assertEquals(HermesRealtimeRelayMirrorAck.Decision.ACCEPTED, coordinator.lastMirrorAck.value?.decision)
    }

    @Test
    fun sendLongTermReferenceAcknowledgement_usesActiveControlStreamAndRequestId() = runTest {
        val stream = RecordingStream()
        val coordinator = MediaControlStreamCoordinator(
            dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
            scope = backgroundScope,
        )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        coordinator.sendLongTermReferenceAcknowledgement(
            token = MediaFrameV2LongTermReferenceToken(value = 42L),
            requestID = "mirror-1",
        )

        val ack = stream.sent.first { it.type == HermesRealtimeRelayFrameType.MEDIA_LONG_TERM_REFERENCE_ACK }
        assertEquals("uid-1", ack.uid)
        assertEquals("conn-1", ack.connectionId)
        assertEquals("mirror-1", ack.requestId)
        assertEquals("mirror-1", ack.media?.longTermReferenceAck?.requestId)
        assertEquals(42L, ack.media?.longTermReferenceAck?.tokenValue)
        assertNotNull(ack.media?.longTermReferenceAck?.decodedAt)
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
