// fixtures are literal by design.

package com.openburnbar.irohrelay

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * F7/F10 wire-shape tests for the seal fields added to the relay frame model:
 * legacy frames gain NO new keys (byte stability with flags off), legacy JSON
 * without the fields still decodes, and populated fields round trip with the
 * Swift-compatible shapes.
 */
class HermesRealtimeRelaySealWireTest {
    private fun encodeToObject(frame: HermesRealtimeRelayFrame): JsonObject =
        HermesRealtimeRelayJson.parseToJsonElement(
            HermesRealtimeRelayJson.encodeToString(HermesRealtimeRelayFrame.serializer(), frame),
        ).jsonObject

    private fun sealKeyEnvelope() =
        HermesRealtimeRelayControlSealKeyEnvelope(
            encBase64 = "enc-base64",
            wrappedKeyBase64 = "wrapped-base64",
            senderDeviceId = "android-device-1",
            senderPeerNodeId = "android-device-1",
            senderKeyId = "relay-v3-abcdef0123456789abcdef01",
            senderCounter = 7L,
            relayKeyVersion = 3,
        )

    // MARK: F10 control payload

    @Test
    fun `legacy control payloads gain no seal keys on the wire`() {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
                uid = "uid-1",
                connectionId = "conn-1",
                control =
                    HermesRealtimeRelayControlPayload(
                        streamClass = "control.input",
                        authorityPeerNodeId = "android-phone-1",
                    ),
            )
        val control = encodeToObject(frame)["control"]!!.jsonObject
        // F10 backward compatibility: pre-F10 classify frames stay byte-identical.
        assertFalse(control.containsKey("controlSealKey"))
        assertFalse(control.containsKey("sealedFrameBase64"))
        assertEquals(setOf("streamClass", "authorityPeerNodeId"), control.keys)
    }

    @Test
    fun `classify frames carry the seal key envelope with the swift field names`() {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
                uid = "uid-1",
                connectionId = "conn-1",
                control =
                    HermesRealtimeRelayControlPayload(
                        streamClass = "control.input",
                        authorityPeerNodeId = "android-phone-1",
                        controlSealKey = sealKeyEnvelope(),
                    ),
            )
        val sealKey = encodeToObject(frame)["control"]!!.jsonObject["controlSealKey"]!!.jsonObject
        assertEquals("enc-base64", sealKey["encBase64"]?.jsonPrimitive?.content)
        assertEquals("wrapped-base64", sealKey["wrappedKeyBase64"]?.jsonPrimitive?.content)
        assertEquals("android-device-1", sealKey["senderDeviceId"]?.jsonPrimitive?.content)
        assertEquals("android-device-1", sealKey["senderPeerNodeId"]?.jsonPrimitive?.content)
        assertEquals("relay-v3-abcdef0123456789abcdef01", sealKey["senderKeyId"]?.jsonPrimitive?.content)
        assertEquals(7L, sealKey["senderCounter"]?.jsonPrimitive?.content?.toLong())
        assertEquals(3, sealKey["relayKeyVersion"]?.jsonPrimitive?.content?.toInt())

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame
        assertEquals(sealKeyEnvelope(), decoded.control?.controlSealKey)
    }

    @Test
    fun `sealed control shells round trip with only streamClass visible`() {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
                uid = "uid-1",
                connectionId = "conn-1",
                control =
                    HermesRealtimeRelayControlPayload(
                        streamClass = "control.input",
                        sealedFrameBase64 = "T0JDRlMx",
                    ),
            )
        val control = encodeToObject(frame)["control"]!!.jsonObject
        assertEquals(setOf("streamClass", "sealedFrameBase64"), control.keys)

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame
        assertEquals("T0JDRlMx", decoded.control?.sealedFrameBase64)
        assertNull(decoded.control?.inputIntent)
    }

    @Test
    fun `legacy control json without the new fields still decodes`() {
        val legacyJson =
            """
            {"type":"control.classify","uid":"uid-1","connectionId":"conn-1","protocolVersion":1,
             "control":{"streamClass":"control.input","authorityPeerNodeId":"android-phone-1"}}
            """.trimIndent()
        val decoded =
            HermesRealtimeRelayJson.decodeFromString(HermesRealtimeRelayFrame.serializer(), legacyJson)
        assertEquals("android-phone-1", decoded.control?.authorityPeerNodeId)
        assertNull(decoded.control?.controlSealKey)
        assertNull(decoded.control?.sealedFrameBase64)
    }

    // MARK: F7 mirror request + media payload

    @Test
    fun `legacy mirror requests gain no mediaSealKey on the wire`() {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST,
                uid = "uid-1",
                connectionId = "conn-1",
                media =
                    HermesRealtimeRelayMediaPayload(
                        mirrorRequest =
                            HermesRealtimeRelayMirrorRequest(
                                requestId = "req-1",
                                requestedAt = "2026-06-10T00:00:00.000Z",
                                requesterDisplayName = "Android",
                                streamClass = "media.screen.video",
                            ),
                    ),
            )
        val mirrorRequest = encodeToObject(frame)["media"]!!.jsonObject["mirrorRequest"]!!.jsonObject
        // F7 backward compatibility: pre-F7 mirror requests stay byte-identical.
        assertFalse(mirrorRequest.containsKey("mediaSealKey"))
    }

    @Test
    fun `mirror requests carry mediaSealKey and round trip`() {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_MIRROR_REQUEST,
                uid = "uid-1",
                connectionId = "conn-1",
                media =
                    HermesRealtimeRelayMediaPayload(
                        mirrorRequest =
                            HermesRealtimeRelayMirrorRequest(
                                requestId = "req-1",
                                requestedAt = "2026-06-10T00:00:00.000Z",
                                requesterDisplayName = "Android",
                                streamClass = "media.screen.video",
                                viewerId = "viewer-1",
                                mediaSealKey = sealKeyEnvelope(),
                            ),
                    ),
            )
        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame
        assertEquals(sealKeyEnvelope(), decoded.media?.mirrorRequest?.mediaSealKey)
    }

    @Test
    fun `legacy media stream frames gain no sealedFramePosition on the wire`() {
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
                uid = "uid-1",
                connectionId = "conn-1",
                media =
                    HermesRealtimeRelayMediaPayload(
                        streamClass = "media.screen.video",
                        encodedFrameBase64 = "AAAA",
                    ),
            )
        val media = encodeToObject(frame)["media"]!!.jsonObject
        assertFalse(media.containsKey("sealedFramePosition"))
        assertEquals(setOf("streamClass", "encodedFrameBase64"), media.keys)
    }

    @Test
    fun `sealed media frames carry the position with swift field names and round trip`() {
        val position = HermesRealtimeRelaySealedMediaFramePosition(kind = 1, gopId = 41, frameIndex = 9)
        val frame =
            HermesRealtimeRelayFrame(
                type = HermesRealtimeRelayFrameType.MEDIA_STREAM_FRAME,
                uid = "uid-1",
                connectionId = "conn-1",
                media =
                    HermesRealtimeRelayMediaPayload(
                        streamClass = "media.screen.video",
                        encodedFrameBase64 = "AAAA",
                        sealedFramePosition = position,
                    ),
            )
        val encoded = encodeToObject(frame)["media"]!!.jsonObject["sealedFramePosition"]!!.jsonObject
        assertEquals(1, encoded["kind"]?.jsonPrimitive?.content?.toInt())
        assertEquals(41L, encoded["gopId"]?.jsonPrimitive?.content?.toLong())
        assertEquals(9L, encoded["frameIndex"]?.jsonPrimitive?.content?.toLong())

        val codec = IrohRelayFrameCodec()
        val decoded = codec.decode(codec.encode(frame)).frame
        assertEquals(position, decoded.media?.sealedFramePosition)
    }

    @Test
    fun `legacy media json without sealedFramePosition still decodes`() {
        val legacyJson =
            """
            {"type":"media.stream.frame","uid":"uid-1","connectionId":"conn-1","protocolVersion":1,
             "media":{"streamClass":"media.screen.video","encodedFrameBase64":"AAAA"}}
            """.trimIndent()
        val decoded =
            HermesRealtimeRelayJson.decodeFromString(HermesRealtimeRelayFrame.serializer(), legacyJson)
        assertEquals("AAAA", decoded.media?.encodedFrameBase64)
        assertNull(decoded.media?.sealedFramePosition)
    }

    // MARK: shared helpers

    @Test
    fun `frame type wireValue matches the dotted swift raw values the codec emits`() {
        // The F10 AAD binds frame.type.rawValue — wireValue must equal the
        // @SerialName the codec writes for EVERY case.
        for (type in HermesRealtimeRelayFrameType.values()) {
            val onTheWire =
                encodeToObject(
                    HermesRealtimeRelayFrame(type = type, uid = "u", connectionId = "c"),
                )["type"]?.jsonPrimitive?.content
            assertEquals(onTheWire, type.wireValue)
        }
        assertEquals("control.input.intent", HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT.wireValue)
        assertEquals("control.classify", HermesRealtimeRelayFrameType.CONTROL_CLASSIFY.wireValue)
    }

    @Test
    fun `control payload codec round trips and drops absent optionals`() {
        val payload =
            HermesRealtimeRelayControlPayload(
                streamClass = "control.input",
                inputIntent =
                    HermesRealtimeRelayInputIntent(
                        kind = HermesRealtimeRelayInputIntentKind.TAP,
                        displayId = "display-1",
                        normalizedX = 0.25,
                        normalizedY = 0.75,
                        clientIntentId = "intent-1",
                        authority =
                            HermesRealtimeRelayAuthorityEnvelope(
                                peerNodeId = "android-phone-1",
                                counter = 42,
                                timestamp = 721_692_800.123,
                                intentHashBlake3 = "f".repeat(64),
                                signatureEd25519 = "signature",
                            ),
                    ),
            )
        val bytes = HermesRealtimeRelayControlPayloadCodec.encodeToBytes(payload)
        val text = bytes.toString(Charsets.UTF_8)
        assertTrue(text.contains("\"streamClass\""))
        assertFalse(text.contains("sealedFrameBase64"))
        assertFalse(text.contains("controlSealKey"))
        assertEquals(payload, HermesRealtimeRelayControlPayloadCodec.decodeFromBytes(bytes))
    }
}
