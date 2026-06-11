@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayControlSealKeyEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaPayload
import com.openburnbar.irohrelay.HermesRealtimeRelaySealedMediaFramePosition
import com.openburnbar.irohrelay.IrohRelayFrameCodec
import com.openburnbar.irohrelay.IrohRelayStream
import java.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val SEAL_GOP = 7
private const val SEAL_FRAME_INDEX = 3

/**
 * F7 — the coordinator (live read loop) and the [MediaControlFrameDispatcher]
 * both open sealed (OBMFA1) screen frames after chunk reassembly and DROP, fail
 * closed, anything that does not open: tampered ciphertext, a wrong cleartext
 * position, a missing session key. Plaintext legacy frames flow unchanged, and
 * `requestMirror` stays byte-identical when no seal session negotiates.
 */
class MediaControlStreamCoordinatorSealTest {
    private val sessionKey = ByteArray(32) { index -> (index + 11).toByte() }

    private fun sourceFrame() =
        MediaFrame(
            kind = MediaFrame.Kind.VIDEO_NAL,
            flags = MediaFrame.Flags.KEYFRAME,
            gopID = SEAL_GOP.toUInt(),
            frameIndex = SEAL_FRAME_INDEX.toUInt(),
            presentationTimestampMillis = 123uL,
            payload = byteArrayOf(0x01, 0x02, 0x03),
        )

    private fun sealedEncodedFrame(): ByteArray =
        MediaFrameAead.seal(
            plaintext = MediaPacketCodec().encode(sourceFrame()),
            key = sessionKey,
            streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
            kind = MediaFrame.Kind.VIDEO_NAL.rawValue.toUByte(),
            gopID = SEAL_GOP.toUInt(),
            frameIndex = SEAL_FRAME_INDEX.toUInt(),
        )

    private fun position(
        kind: Int = MediaFrame.Kind.VIDEO_NAL.rawValue.toInt(),
        gopId: Long = SEAL_GOP.toLong(),
        frameIndex: Long = SEAL_FRAME_INDEX.toLong(),
    ) = HermesRealtimeRelaySealedMediaFramePosition(kind = kind, gopId = gopId, frameIndex = frameIndex)

    private fun streamFrame(
        encoded: ByteArray,
        position: HermesRealtimeRelaySealedMediaFramePosition?,
    ) = HermesRealtimeRelayFrame(
        type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
        uid = "uid-1",
        connectionId = "conn-1",
        media =
            HermesRealtimeRelayMediaPayload(
                streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                encodedFrameBase64 = Base64.getEncoder().encodeToString(encoded),
                sealedFramePosition = position,
            ),
    )

    // MARK: live coordinator read loop

    @Test
    fun `readLoop opens sealed frames under the session key and drops tampered ones`() = runTest {
        val stream = RecordingStream()
        val coordinator =
            MediaControlStreamCoordinator(
                dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
                scope = backgroundScope,
            )
        val received = CompletableDeferred<MediaFrame>()
        coordinator.mirrorFrameHandler = { frame -> received.complete(frame) }
        coordinator.mediaFrameSealKey = sessionKey

        coordinator.start(uid = "uid-1", connectionID = "conn-1")

        // 1. tampered sealed frame → dropped (never reaches the handler)
        val tampered = sealedEncodedFrame()
        tampered[tampered.size - 1] = (tampered[tampered.size - 1].toInt() xor 0x01).toByte()
        stream.incoming.send(streamFrame(tampered, position()))
        // 2. wrong cleartext position → dropped
        stream.incoming.send(streamFrame(sealedEncodedFrame(), position(gopId = 99L)))
        // 3. missing position → dropped
        stream.incoming.send(streamFrame(sealedEncodedFrame(), position = null))
        // 4. valid sealed frame → opened and delivered
        stream.incoming.send(streamFrame(sealedEncodedFrame(), position()))

        val decoded = withTimeout(2_000) { received.await() }
        assertEquals(sourceFrame(), decoded)
    }

    @Test
    fun `readLoop drops sealed frames when no session key is installed`() = runTest {
        val stream = RecordingStream()
        val coordinator =
            MediaControlStreamCoordinator(
                dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
                scope = backgroundScope,
            )
        val received = CompletableDeferred<MediaFrame>()
        coordinator.mirrorFrameHandler = { frame -> received.complete(frame) }

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        stream.incoming.send(streamFrame(sealedEncodedFrame(), position()))
        // A plaintext legacy frame after it proves the loop survived the drop.
        stream.incoming.send(
            streamFrame(MediaPacketCodec().encode(sourceFrame()), position = null),
        )

        val decoded = withTimeout(2_000) { received.await() }
        assertEquals(sourceFrame(), decoded)
    }

    @Test
    fun `openSealedMercuryMediaFrame opens valid frames and fails closed otherwise`() = runTest {
        val coordinator =
            MediaControlStreamCoordinator(
                dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> RecordingStream() },
                scope = backgroundScope,
            )
        val sealed = sealedEncodedFrame()
        val media =
            HermesRealtimeRelayMediaPayload(
                streamClass = MediaStreamClass.SCREEN_VIDEO.raw,
                sealedFramePosition = position(),
            )

        assertNull(coordinator.openSealedMercuryMediaFrame(sealed, media))
        coordinator.mediaFrameSealKey = sessionKey
        assertArrayEquals(
            MediaPacketCodec().encode(sourceFrame()),
            coordinator.openSealedMercuryMediaFrame(sealed, media),
        )
        assertNull(
            coordinator.openSealedMercuryMediaFrame(
                sealed,
                media.copy(sealedFramePosition = position(frameIndex = 8L)),
            ),
        )
        assertNull(coordinator.openSealedMercuryMediaFrame(sealed, media.copy(sealedFramePosition = null)))
    }

    // MARK: mirror request negotiation

    @Test
    fun `requestMirror attaches mediaSealKey and installs the session key when negotiated`() = runTest {
        val stream = RecordingStream()
        val envelope =
            HermesRealtimeRelayControlSealKeyEnvelope(
                encBase64 = "enc",
                wrappedKeyBase64 = "wrapped",
                senderDeviceId = "android-device-1",
                senderPeerNodeId = "android-device-1",
                senderKeyId = "relay-v3-abcdef0123456789abcdef01",
                senderCounter = 5L,
                relayKeyVersion = 3,
            )
        var seenViewerId: String? = null
        val coordinator =
            MediaControlStreamCoordinator(
                dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
                scope = backgroundScope,
                mediaSealSessionFactory = { _, _, viewerId, _ ->
                    seenViewerId = viewerId
                    MediaSealSessionEstablisher.Session(envelope = envelope, key = sessionKey)
                },
            )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        coordinator.requestMirror("Alberto's Android")

        val mirror = stream.sent.last()
        assertEquals(HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST, mirror.type)
        assertEquals(envelope, mirror.media?.mirrorRequest?.mediaSealKey)
        assertEquals(mirror.media?.mirrorRequest?.viewerId, seenViewerId)
        assertArrayEquals(sessionKey, coordinator.mediaFrameSealKey)
    }

    @Test
    fun `requestMirror stays byte-identical when no seal session negotiates`() = runTest {
        val stream = RecordingStream()
        val coordinator =
            MediaControlStreamCoordinator(
                dialer = MediaControlStreamCoordinator.StreamDialer { _, _ -> stream },
                scope = backgroundScope,
                mediaSealSessionFactory = { _, _, _, _ -> null },
            )

        coordinator.start(uid = "uid-1", connectionID = "conn-1")
        coordinator.requestMirror("Alberto's Android")
        yield()

        val mirror = stream.sent.last()
        assertNull(coordinator.mediaFrameSealKey)
        assertNull(mirror.media?.mirrorRequest?.mediaSealKey)
        // Wire-level byte stability: the flags-off request gains no key.
        val encodedJson = IrohRelayFrameCodec().encode(mirror).toString(Charsets.ISO_8859_1)
        assertFalse(encodedJson.contains("mediaSealKey"))
    }

    // MARK: parallel dispatcher

    private fun dispatcher(
        sealKey: ByteArray?,
        onFrame: (MediaFrame) -> Unit,
    ) = MediaControlFrameDispatcher(
        handlers =
            MediaControlFrameDispatcherHandlers(
                receiverProvider = { null },
                mirrorFrameHandler = { { frame -> onFrame(frame) } },
                mirrorFrameV2Handler = { null },
                focusContextHandler = { null },
                mediaFrameSealKeyProvider = { sealKey },
            ),
        callbacks =
            MediaControlFrameDispatcherCallbacks(
                onMirrorAck = {},
                onCallAck = {},
                onAgentGrantReceipt = {},
                onControlDenied = {},
                onClipboardResponse = {},
                onRemoteUnlockState = {},
                onRemoteUnlockResult = {},
                onPeerHeartbeat = { _, _ -> },
                onRoundTripMillis = {},
                pendingHeartbeatSentAtMillis = { null },
                clearPendingHeartbeat = {},
            ),
    )

    private val noopAckSender = AndroidFileTransferService.AdvertiseSender { }

    @Test
    fun `dispatcher opens sealed frames after reassembly and drops failures`() = runTest {
        val delivered = mutableListOf<MediaFrame>()
        val withKey = dispatcher(sealKey = sessionKey) { delivered += it }

        // valid sealed frame → delivered
        withKey.dispatch(streamFrame(sealedEncodedFrame(), position()), noopAckSender)
        assertEquals(listOf(sourceFrame()), delivered)

        // tampered → dropped
        val tampered = sealedEncodedFrame()
        tampered[tampered.size - 1] = (tampered[tampered.size - 1].toInt() xor 0x01).toByte()
        withKey.dispatch(streamFrame(tampered, position()), noopAckSender)
        // wrong position → dropped
        withKey.dispatch(streamFrame(sealedEncodedFrame(), position(gopId = 99L)), noopAckSender)
        // missing position → dropped
        withKey.dispatch(streamFrame(sealedEncodedFrame(), position = null), noopAckSender)
        assertEquals(1, delivered.size)

        // no key → sealed frames dropped, plaintext legacy still flows
        val deliveredWithoutKey = mutableListOf<MediaFrame>()
        val withoutKey = dispatcher(sealKey = null) { deliveredWithoutKey += it }
        withoutKey.dispatch(streamFrame(sealedEncodedFrame(), position()), noopAckSender)
        assertTrue(deliveredWithoutKey.isEmpty())
        withoutKey.dispatch(
            streamFrame(MediaPacketCodec().encode(sourceFrame()), position = null),
            noopAckSender,
        )
        assertEquals(listOf(sourceFrame()), deliveredWithoutKey)
    }

    @Test
    fun `dispatcher default handlers keep the legacy plaintext lane unchanged`() = runTest {
        val delivered = mutableListOf<MediaFrame>()
        val dispatcher =
            MediaControlFrameDispatcher(
                handlers =
                    MediaControlFrameDispatcherHandlers(
                        receiverProvider = { null },
                        mirrorFrameHandler = { { frame -> delivered += frame } },
                        mirrorFrameV2Handler = { null },
                        focusContextHandler = { null },
                    ),
                callbacks =
                    MediaControlFrameDispatcherCallbacks(
                        onMirrorAck = {},
                        onCallAck = {},
                        onAgentGrantReceipt = {},
                        onControlDenied = {},
                        onClipboardResponse = {},
                        onRemoteUnlockState = {},
                        onRemoteUnlockResult = {},
                        onPeerHeartbeat = { _, _ -> },
                        onRoundTripMillis = {},
                        pendingHeartbeatSentAtMillis = { null },
                        clearPendingHeartbeat = {},
                    ),
            )
        dispatcher.dispatch(
            streamFrame(MediaPacketCodec().encode(sourceFrame()), position = null),
            noopAckSender,
        )
        assertEquals(listOf(sourceFrame()), delivered)
        assertNotNull(dispatcher)
    }

    private class RecordingStream : IrohRelayStream {
        val sent = mutableListOf<HermesRealtimeRelayFrame>()
        val incoming = Channel<HermesRealtimeRelayFrame?>(Channel.UNLIMITED)
        var closed = false

        override suspend fun send(frame: HermesRealtimeRelayFrame) {
            sent.add(frame)
        }

        override suspend fun receive(): HermesRealtimeRelayFrame? = incoming.receiveCatching().getOrNull()

        override suspend fun close() {
            closed = true
            incoming.close()
        }
    }
}
