@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val VAL_1176 = 1176

class MercuryStreamingCapabilitiesTest {
    @Test
    fun production_policy_does_not_select_av1_before_experiment_flag() {
        val local =
            snapshot(
                capability(MercuryVideoCodec.AV1, encode = true, decode = true),
                capability(MercuryVideoCodec.HEVC, encode = true, decode = true),
                capability(MercuryVideoCodec.H264, encode = true, decode = true),
            )
        val remote =
            snapshot(
                capability(MercuryVideoCodec.AV1, encode = false, decode = true),
                capability(MercuryVideoCodec.HEVC, encode = false, decode = true),
                capability(MercuryVideoCodec.H264, encode = false, decode = true),
            )

        assertEquals(
            MercuryVideoCodec.HEVC,
            MercuryCodecResolver.resolveSendCodec(local, remote, MercuryCodecPolicy.PRODUCTION),
        )
        assertEquals(
            MercuryVideoCodec.AV1,
            MercuryCodecResolver.resolveSendCodec(local, remote, MercuryCodecPolicy.EXPERIMENTAL_AV1),
        )
    }

    @Test
    fun codec_resolver_falls_back_to_h264_when_hevc_is_not_mutual() {
        val local =
            snapshot(
                capability(MercuryVideoCodec.HEVC, encode = true, decode = true),
                capability(MercuryVideoCodec.H264, encode = true, decode = true),
            )
        val remote =
            snapshot(
                capability(MercuryVideoCodec.HEVC, encode = false, decode = false),
                capability(MercuryVideoCodec.H264, encode = false, decode = true),
            )

        assertEquals(MercuryVideoCodec.H264, MercuryCodecResolver.resolveSendCodec(local, remote))
    }

    @Test
    fun codec_resolver_returns_null_without_mutual_send_codec() {
        val local =
            snapshot(
                capability(MercuryVideoCodec.HEVC, encode = true, decode = true),
                capability(MercuryVideoCodec.H264, encode = false, decode = true),
            )
        val remote =
            snapshot(
                capability(MercuryVideoCodec.HEVC, encode = false, decode = false),
                capability(MercuryVideoCodec.H264, encode = false, decode = true),
            )

        assertNull(MercuryCodecResolver.resolveSendCodec(local, remote))
    }

    @Test
    fun wire_version_negotiator_keeps_v1_until_both_peers_support_v2() {
        assertEquals(
            MercuryMediaFrameWireVersion.V1,
            MercuryWireVersionNegotiator.resolve(
                MercuryMediaFrameVersionSupport.V1_ONLY,
                MercuryMediaFrameVersionSupport.V1_AND_V2,
            ),
        )
        assertFalse(
            MercuryWireVersionNegotiator.canSendMetadataV2(
                MercuryMediaFrameVersionSupport.V1_ONLY,
                MercuryMediaFrameVersionSupport.V1_AND_V2,
            ),
        )

        assertEquals(
            MercuryMediaFrameWireVersion.V2,
            MercuryWireVersionNegotiator.resolve(
                MercuryMediaFrameVersionSupport.V1_AND_V2,
                MercuryMediaFrameVersionSupport.V1_AND_V2,
            ),
        )
        assertTrue(
            MercuryWireVersionNegotiator.canSendMetadataV2(
                MercuryMediaFrameVersionSupport.V1_AND_V2,
                MercuryMediaFrameVersionSupport.V1_AND_V2,
            ),
        )
    }

    @Test
    fun datagram_capability_requires_runtime_max_payload() {
        assertFalse(MercuryDatagramCapability(maxPayloadBytes = null).isSupported)
        assertNull(MercuryDatagramCapability(maxPayloadBytes = null).payloadBudget(reservingOverheadBytes = 24))
        assertNull(MercuryDatagramCapability(maxPayloadBytes = 16).payloadBudget(reservingOverheadBytes = 24))
        assertEquals(VAL_1176, MercuryDatagramCapability(maxPayloadBytes = 1200).payloadBudget(reservingOverheadBytes = 24))
    }

    @Test
    fun datagram_probe_normalizes_runtime_max_size() {
        assertEquals(
            MercuryDatagramCapability(maxPayloadBytes = 1200),
            MercuryDatagramCapabilityProbe.snapshot(maxDatagramSize = 1200),
        )
        assertEquals(
            MercuryDatagramCapability(maxPayloadBytes = null),
            MercuryDatagramCapabilityProbe.snapshot(maxDatagramSize = 0),
        )
    }

    @Test
    fun streaming_capabilities_convert_to_relay_wire_shape() {
        val snapshot =
            MercuryStreamingCapabilitySnapshot(
                codecCapabilities =
                listOf(
                    MercuryVideoCodecCapability(
                        codec = MercuryVideoCodec.HEVC,
                        canEncode = true,
                        canDecode = true,
                        hardwareAccelerated = true,
                        lowLatencyEncode = true,
                        longTermReference = true,
                    ),
                ),
                mediaFrameVersions = MercuryMediaFrameVersionSupport.V1_ONLY,
                videoDatagrams = MercuryDatagramCapability(maxPayloadBytes = 1200),
                source = "test",
            )

        val roundTripped = snapshot.toWire().toMercury()

        assertEquals(snapshot, roundTripped)
        assertEquals(com.openburnbar.irohrelay.HermesRealtimeRelayVideoCodec.HEVC, snapshot.toWire().codecCapabilities.first().codec)
    }

    private fun snapshot(vararg capabilities: MercuryVideoCodecCapability): MercuryStreamingCapabilitySnapshot = MercuryStreamingCapabilitySnapshot(
        codecCapabilities = capabilities.toList(),
        source = "test",
    )

    private fun capability(codec: MercuryVideoCodec, encode: Boolean, decode: Boolean): MercuryVideoCodecCapability = MercuryVideoCodecCapability(
        codec = codec,
        canEncode = encode,
        canDecode = decode,
        hardwareAccelerated = encode || decode,
        lowLatencyEncode = encode,
        temporalLayering = false,
        longTermReference = false,
        screenContentCoding = false,
    )
}
