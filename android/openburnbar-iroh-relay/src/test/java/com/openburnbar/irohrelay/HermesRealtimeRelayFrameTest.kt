@file:Suppress("FunctionNaming", "MagicNumber")
// detekt: JUnit backtick BDD test names intentionally contain spaces; wire
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
 * Wire-shape tests for the `HermesRealtimeRelayFrame` JSON model (the codec
 * envelope around it is covered by [IrohRelayFrameCodecTest]): frame types use
 * the dotted Swift identifiers, `protocolVersion` is always emitted even at
 * its default, absent optionals are dropped (pre-F2 byte identity for the
 * authority envelope), and unknown fields from newer iOS senders are ignored.
 */
class HermesRealtimeRelayFrameTest {
    private fun encodeToObject(frame: HermesRealtimeRelayFrame): JsonObject =
        HermesRealtimeRelayJson.parseToJsonElement(
            HermesRealtimeRelayJson.encodeToString(HermesRealtimeRelayFrame.serializer(), frame),
        ).jsonObject

    private fun minimalFrame(type: HermesRealtimeRelayFrameType = HermesRealtimeRelayFrameType.HOST_READY) =
        HermesRealtimeRelayFrame(type = type, uid = "uid-1", connectionId = "conn-1")

    @Test
    fun `frame types serialize to the dotted swift identifiers`() {
        assertEquals("host.ready", encodeToObject(minimalFrame())["type"]?.jsonPrimitive?.content)
        assertEquals(
            "request.start",
            encodeToObject(minimalFrame(HermesRealtimeRelayFrameType.REQUEST_START))["type"]?.jsonPrimitive?.content,
        )
        assertEquals(
            "control.classify",
            encodeToObject(minimalFrame(HermesRealtimeRelayFrameType.CONTROL_CLASSIFY))["type"]?.jsonPrimitive?.content,
        )
    }

    @Test
    fun `protocolVersion is always emitted even at its default`() {
        // encodeDefaults=false would normally drop it; @EncodeDefault pins it
        // so the Mac can gate on the version of every frame.
        val encoded = encodeToObject(minimalFrame())
        assertEquals(HermesRealtimeRelayProtocol.VERSION, encoded["protocolVersion"]?.jsonPrimitive?.content?.toInt())
    }

    @Test
    fun `absent optionals are dropped from the wire`() {
        val encoded = encodeToObject(minimalFrame())
        for (absent in listOf("requestId", "runtime", "payload", "media", "control", "signalSessionCiphertextB64")) {
            assertFalse("$absent must not be on the wire when null", encoded.containsKey(absent))
        }
    }

    @Test
    fun `legacy authority envelopes gain no keyKind field but se-p256 carries it`() {
        fun frame(keyKind: String?) =
            minimalFrame(HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT).copy(
                control =
                    HermesRealtimeRelayControlPayload(
                        streamClass = "control.input",
                        inputIntent =
                            HermesRealtimeRelayInputIntent(
                                kind = HermesRealtimeRelayInputIntentKind.TAP,
                                normalizedX = 0.5,
                                normalizedY = 0.5,
                                authority =
                                    HermesRealtimeRelayAuthorityEnvelope(
                                        peerNodeId = "android-phone-1",
                                        counter = 7,
                                        timestamp = 721_692_800.0,
                                        intentHashBlake3 = "ab",
                                        signatureEd25519 = "sig",
                                        keyKind = keyKind,
                                    ),
                            ),
                    ),
            )

        val legacyAuthority =
            encodeToObject(frame(keyKind = null))
                .getValue("control").jsonObject
                .getValue("inputIntent").jsonObject
                .getValue("authority").jsonObject
        // F2 backward compatibility: pre-F2 envelopes stay byte-identical.
        assertFalse(legacyAuthority.containsKey("keyKind"))

        val hardwareAuthority =
            encodeToObject(frame(keyKind = "se-p256"))
                .getValue("control").jsonObject
                .getValue("inputIntent").jsonObject
                .getValue("authority").jsonObject
        assertEquals("se-p256", hardwareAuthority["keyKind"]?.jsonPrimitive?.content)
    }

    @Test
    fun `round trip preserves the frame and unknown fields are ignored`() {
        val frame =
            minimalFrame(HermesRealtimeRelayFrameType.CONTROL_CLASSIFY).copy(
                control =
                    HermesRealtimeRelayControlPayload(
                        streamClass = "control.input",
                        authorityPeerNodeId = "android-phone-1",
                    ),
            )
        val decoded =
            HermesRealtimeRelayJson.decodeFromString(
                HermesRealtimeRelayFrame.serializer(),
                HermesRealtimeRelayJson.encodeToString(HermesRealtimeRelayFrame.serializer(), frame),
            )
        assertEquals(frame, decoded)

        // A newer iOS sender adds fields this build does not know.
        val tolerant =
            HermesRealtimeRelayJson.decodeFromString(
                HermesRealtimeRelayFrame.serializer(),
                """
                {"type":"host.ready","uid":"uid-1","connectionId":"conn-1",
                 "futureField":{"nested":true},"anotherNewThing":42}
                """.trimIndent(),
            )
        assertEquals(HermesRealtimeRelayFrameType.HOST_READY, tolerant.type)
        assertEquals("uid-1", tolerant.uid)
        assertNull(tolerant.control)
        assertEquals(HermesRealtimeRelayProtocol.VERSION, tolerant.protocolVersion)
    }

    @Test
    fun `decoding never invents defaults for required identity fields`() {
        val missingUid =
            runCatching {
                HermesRealtimeRelayJson.decodeFromString(
                    HermesRealtimeRelayFrame.serializer(),
                    """{"type":"host.ready","connectionId":"conn-1"}""",
                )
            }
        assertTrue("a frame without a uid must fail to decode", missingUid.isFailure)
    }
}
