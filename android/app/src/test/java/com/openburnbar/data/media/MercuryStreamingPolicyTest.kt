@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MercuryStreamingPolicyTest {
    @Test
    fun codec_router_prefers_hevc_in_production_and_records_stats() {
        val local =
            snapshot(
                codecs =
                listOf(
                    codec(MercuryVideoCodec.AV1, encode = true, decode = true),
                    codec(MercuryVideoCodec.HEVC, encode = true, decode = true),
                    codec(MercuryVideoCodec.H264, encode = true, decode = true),
                ),
                versions = MercuryMediaFrameVersionSupport.V1_AND_V2,
                datagramBytes = 1_400,
            )
        val remote =
            snapshot(
                codecs =
                listOf(
                    codec(MercuryVideoCodec.AV1, encode = true, decode = true),
                    codec(MercuryVideoCodec.HEVC, encode = false, decode = true),
                    codec(MercuryVideoCodec.H264, encode = false, decode = true),
                ),
                versions = MercuryMediaFrameVersionSupport.V1_AND_V2,
                datagramBytes = 1_300,
            )

        val route = MercuryCodecRouter.route(local = local, remote = remote)

        assertEquals(MercuryCodecRoutingDecision.Status.ROUTED, route.status)
        assertEquals(MercuryVideoCodec.HEVC, route.codec)
        assertEquals(MercuryMediaFrameWireVersion.V2, route.wireVersion)
        assertEquals(MercuryVideoCodec.HEVC, route.stats.codec)
        assertEquals(1_236, route.datagramPayloadBudgetBytes)
    }

    @Test
    fun codec_router_keeps_active_session_codec_until_restart() {
        val active =
            MercuryCodecRoutingDecision(
                status = MercuryCodecRoutingDecision.Status.ROUTED,
                codec = MercuryVideoCodec.HEVC,
                wireVersion = MercuryMediaFrameWireVersion.V1,
                datagramPayloadBudgetBytes = null,
                stats = MercuryRtcStatsSnapshot(timestampMillis = 1L, codec = MercuryVideoCodec.HEVC),
                reason = "initial",
            )
        val h264Only = snapshot(codecs = listOf(codec(MercuryVideoCodec.H264, encode = true, decode = true)))

        val route =
            MercuryCodecRouter.route(
                local = h264Only,
                remote = h264Only,
                activeSessionRoute = active,
                timestampMillis = 2L,
            )

        assertEquals(MercuryVideoCodec.HEVC, route.codec)
        assertEquals(2L, route.stats.timestampMillis)
        assertTrue(route.reason.contains("restart"))
    }

    @Test
    fun shadow_bwe_reports_risk_without_touching_production_estimator() {
        val production = BweEstimator(BweEstimator.SCREEN_SHARE_STEPS)
        val before = production.currentBitsPerSecond
        val shadow = MercuryShadowBweController(BweEstimator.SCREEN_SHARE_STEPS)

        val decision =
            shadow.observe(
                MercuryBweShadowSample(
                    timestampMillis = 1uL,
                    roundTripMillis = 320,
                    packetLossRate = 0.08,
                    observedBitsPerSecond = 8_000_000,
                    expectedPresentationMillis = 1_000uL,
                    actualPresentationMillis = 1_130uL,
                    pacerQueueDepth = 12,
                    isProbe = true,
                ),
            )

        assertEquals(before, production.currentBitsPerSecond)
        assertTrue(decision.shadowTargetBitsPerSecond < before)
        assertTrue(decision.freezeRiskScore > 0.0)
        assertFalse(decision.promotionReady)
    }

    @Test
    fun shadow_bwe_requires_probe_and_clean_samples_for_promotion() {
        val shadow =
            MercuryShadowBweController(
                steps = BweEstimator.VIDEO_CALL_STEPS,
                minimumPromotionSamples = 3,
            )

        repeat(3) { index ->
            shadow.observe(
                MercuryBweShadowSample(
                    timestampMillis = index.toULong(),
                    roundTripMillis = 30,
                    packetLossRate = 0.0,
                    observedBitsPerSecond = 1_200_000,
                    expectedPresentationMillis = 1_000uL,
                    actualPresentationMillis = 1_004uL,
                    isProbe = index == 0,
                ),
            )
        }

        assertTrue(shadow.currentDecision.promotionReady)
        assertEquals(1, shadow.currentDecision.probeSamples)
    }

    @Test
    fun ltr_recovery_uses_real_tokens_only() {
        var state = MercuryLtrRecoveryState().requestRefresh()
        val missing = state.recordEncodedRefreshToken(null)
        state = missing.first

        assertNull(missing.second)
        assertEquals(1, state.idrFallbacks)

        val tokenValue = 0xCAFEuL
        val recorded = state.recordEncodedRefreshToken(tokenValue)
        state = recorded.first

        assertNotNull(recorded.second)
        assertEquals(1, state.pendingRefreshTokens.size)
        state = state.acknowledgeDecodedToken(requireNotNull(recorded.second))
        assertTrue(state.pendingRefreshTokens.isEmpty())
        assertEquals(tokenValue, state.acknowledgedTokenValuesForEncoder.first())
    }

    @Test
    fun datagram_scheduler_keeps_critical_video_reliable() {
        val capability = MercuryDatagramCapability(maxPayloadBytes = 1_200)
        val keyframe =
            MediaFrame(
                kind = MediaFrame.Kind.VIDEO_NAL,
                flags = MediaFrame.Flags.KEYFRAME,
                payload = ByteArray(100) { 1 },
            )
        val delta =
            MediaFrame(
                kind = MediaFrame.Kind.VIDEO_NAL,
                payload = ByteArray(100) { 2 },
            )

        assertEquals(
            MercuryFrameDelivery.RELIABLE_STREAM,
            MercuryVideoDatagramScheduler.schedule(
                frame = keyframe,
                datagramsEnabled = true,
                remoteCapability = capability,
            ).delivery,
        )
        assertEquals(
            MercuryFrameDelivery.DATAGRAM,
            MercuryVideoDatagramScheduler.schedule(
                frame = delta,
                datagramsEnabled = true,
                remoteCapability = capability,
            ).delivery,
        )
        assertEquals(
            MercuryFrameDelivery.RELIABLE_STREAM,
            MercuryVideoDatagramScheduler.schedule(
                frame = delta,
                datagramsEnabled = true,
                remoteCapability = MercuryDatagramCapability(maxPayloadBytes = null),
            ).delivery,
        )
    }

    @Test
    fun advanced_feature_gate_requires_full_benchmark_evidence() {
        val temporalCodec =
            MercuryVideoCodecCapability(
                codec = MercuryVideoCodec.HEVC,
                canEncode = true,
                canDecode = true,
                hardwareAccelerated = true,
                temporalLayering = true,
                screenContentCoding = true,
            )
        val local = snapshot(codecs = listOf(temporalCodec))
        val remote = snapshot(codecs = listOf(temporalCodec))

        val denied = MercuryAdvancedFeatureGate.evaluate(local = local, remote = remote, benchmark = null)
        assertFalse(denied.fecEnabled)
        assertFalse(denied.temporalLayersEnabled)
        assertFalse(denied.roiEnabled)

        val benchmark =
            MercuryBenchmarkEvidence(
                coveredImpairmentScenarios = MercuryImpairmentScenario.DEFAULT_MATRIX,
                freezeCountImprovementPercent = 12.0,
                presentTimeErrorDeltaMillis = -4.0,
                cpuUsageDeltaPercent = 2.0,
                batteryDrainDeltaPercent = 1.0,
            )
        val allowed =
            MercuryAdvancedFeatureGate.evaluate(
                local = local,
                remote = remote,
                benchmark = benchmark,
                dirtyRegionHintsSupported = true,
            )

        assertTrue(allowed.fecEnabled)
        assertTrue(allowed.temporalLayersEnabled)
        assertTrue(allowed.roiEnabled)
    }

    private fun snapshot(
        codecs: List<MercuryVideoCodecCapability>,
        versions: MercuryMediaFrameVersionSupport = MercuryMediaFrameVersionSupport.V1_ONLY,
        datagramBytes: Int? = null,
    ): MercuryStreamingCapabilitySnapshot = MercuryStreamingCapabilitySnapshot(
        codecCapabilities = codecs,
        mediaFrameVersions = versions,
        videoDatagrams = MercuryDatagramCapability(maxPayloadBytes = datagramBytes),
        source = "test",
    )

    private fun codec(codec: MercuryVideoCodec, encode: Boolean, decode: Boolean): MercuryVideoCodecCapability = MercuryVideoCodecCapability(
        codec = codec,
        canEncode = encode,
        canDecode = decode,
        hardwareAccelerated = true,
    )
}
