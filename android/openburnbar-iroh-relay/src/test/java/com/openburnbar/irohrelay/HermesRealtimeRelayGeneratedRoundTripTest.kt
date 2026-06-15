package com.openburnbar.irohrelay

import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Encode-byte prover for the schema-generated relay payload types.
 *
 * Swift encodes a NON-OPTIONAL Codable field unconditionally (`container.encode(...)`),
 * so it always emits the field even at its default value. Kotlin's relay `Json` uses
 * `encodeDefaults = false`, which would OMIT a defaulted field — a silent encode-side
 * Swift↔Kotlin drift. The generator therefore annotates exactly those fields with
 * `@EncodeDefault`. This test pins that behavior: every field Swift always emits must
 * appear in Kotlin's all-defaults encoding, AND a genuinely optional (nullable, null)
 * field must still be omitted (so the assertion is not vacuous).
 */
class HermesRealtimeRelayGeneratedRoundTripTest {
    private fun encode(value: HermesRealtimeRelayMediaFrameVersionSupport) =
        HermesRealtimeRelayJson.encodeToString(HermesRealtimeRelayMediaFrameVersionSupport.serializer(), value)

    @Test
    fun allDefaultsEmitTheFieldsSwiftAlwaysEmits() {
        // MediaFrameVersionSupport: both flags have defaults; Swift (non-optional) emits both.
        val versions = encode(HermesRealtimeRelayMediaFrameVersionSupport())
        assertTrue("supportsV1 must be emitted at default", versions.contains("\"supportsV1\":true"))
        assertTrue("supportsV2 must be emitted at default", versions.contains("\"supportsV2\":false"))

        // VideoCodecCapability: the four capability flags default to false; all must emit.
        val codec =
            HermesRealtimeRelayJson.encodeToString(
                HermesRealtimeRelayVideoCodecCapability.serializer(),
                HermesRealtimeRelayVideoCodecCapability(
                    codec = HermesRealtimeRelayVideoCodec.AV1,
                    canEncode = true,
                    canDecode = true,
                    hardwareAccelerated = false,
                ),
            )
        for (key in listOf("lowLatencyEncode", "temporalLayering", "longTermReference", "screenContentCoding")) {
            assertTrue("$key must be emitted at default false", codec.contains("\"$key\":false"))
        }

        // DisplayDescriptor.isPrimary defaults to false; Swift always emits it.
        val display =
            HermesRealtimeRelayJson.encodeToString(
                HermesRealtimeRelayDisplayDescriptor.serializer(),
                HermesRealtimeRelayDisplayDescriptor(id = "d1", name = "Main", width = 1920, height = 1080),
            )
        assertTrue("isPrimary must be emitted at default", display.contains("\"isPrimary\":false"))

        // StreamingCapabilities: nested struct defaults must be emitted as objects.
        val streaming =
            HermesRealtimeRelayJson.encodeToString(
                HermesRealtimeRelayStreamingCapabilities.serializer(),
                HermesRealtimeRelayStreamingCapabilities(codecCapabilities = emptyList(), source = "mac"),
            )
        assertTrue("mediaFrameVersions object must be emitted", streaming.contains("\"mediaFrameVersions\":{"))
        assertTrue("videoDatagrams object must be emitted", streaming.contains("\"videoDatagrams\":{"))
    }

    @Test
    fun nullableDefaultsAreStillOmitted() {
        // Guards against over-emitting: a genuinely optional Swift field (encodeIfPresent /
        // omit-when-nil) maps to a nullable Kotlin field with NO @EncodeDefault, so a null
        // value must NOT appear on the wire. Proves the positive assertions above are real.
        val datagram =
            HermesRealtimeRelayJson.encodeToString(
                HermesRealtimeRelayDatagramCapability.serializer(),
                HermesRealtimeRelayDatagramCapability(),
            )
        assertEquals("{}", datagram)
        assertFalse("a null optional must be omitted", datagram.contains("maxPayloadBytes"))
    }

    @Test
    fun remoteUnlockCapabilitiesEmitsAllAlwaysEmitDefaults() {
        // RemoteUnlockCapabilities is the largest @EncodeDefault group (6 fields). Swift
        // (custom Codable, plain container.encode) emits all of them even at default; a
        // default-constructed Kotlin instance must emit the exact same key set.
        val caps =
            HermesRealtimeRelayJson.encodeToString(
                HermesRealtimeRelayRemoteUnlockCapabilities.serializer(),
                HermesRealtimeRelayRemoteUnlockCapabilities(
                    enabled = false,
                    certificationStatus = HermesRealtimeRelayRemoteUnlockCertificationStatus.UNCERTIFIED,
                    activeBackend = HermesRealtimeRelayRemoteUnlockBackend.UNAVAILABLE,
                ),
            )
        val keys = HermesRealtimeRelayJson.parseToJsonElement(caps).jsonObject.keys
        for (key in listOf(
            "supportedBackends",
            "supportedLockStates",
            "blockers",
            "allowsCredentialPaste",
            "allowsSavedCredentialUnlock",
            "fileVaultSSHSupported",
        )) {
            assertTrue("$key must be emitted at default", keys.contains(key))
        }
        // Nullable-no-default fields must still be omitted (not over-emitted).
        assertFalse("certifiedAt (null optional) must be omitted", keys.contains("certifiedAt"))

        // AgentTerminalRequest.interactive defaults to true; Swift always emits it.
        val term =
            HermesRealtimeRelayJson.encodeToString(
                HermesRealtimeRelayAgentTerminalRequest.serializer(),
                HermesRealtimeRelayAgentTerminalRequest(runtimeId = "rt-1"),
            )
        assertTrue("interactive must be emitted at default", term.contains("\"interactive\":true"))
    }

    @Test
    fun generatedTypesRoundTripLosslessly() {
        val capability =
            HermesRealtimeRelayVideoCodecCapability(
                codec = HermesRealtimeRelayVideoCodec.HEVC,
                canEncode = true,
                canDecode = false,
                hardwareAccelerated = true,
                lowLatencyEncode = true,
            )
        val json =
            HermesRealtimeRelayJson.encodeToString(HermesRealtimeRelayVideoCodecCapability.serializer(), capability)
        val decoded =
            HermesRealtimeRelayJson.decodeFromString(HermesRealtimeRelayVideoCodecCapability.serializer(), json)
        assertEquals(capability, decoded)
    }
}
