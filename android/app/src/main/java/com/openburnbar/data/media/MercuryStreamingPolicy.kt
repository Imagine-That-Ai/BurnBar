package com.openburnbar.data.media

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

data class MercuryCodecRoutingDecision(
    val status: Status,
    val codec: MercuryVideoCodec?,
    val wireVersion: MercuryMediaFrameWireVersion,
    val datagramPayloadBudgetBytes: Int?,
    val stats: MercuryRtcStatsSnapshot,
    val reason: String,
) {
    enum class Status {
        ROUTED,
        NO_COMPATIBLE_CODEC,
    }
}

object MercuryCodecRouter {
    private const val VAL_0_04 = 0.04
    private const val VAL_0_1 = 0.1
    private const val VAL_0_2 = 0.2
    private const val VAL_0_3 = 0.3
    private const val VAL_0_30 = 0.30
    private const val VAL_0_4 = 0.4
    private const val VAL_0_45 = 0.45
    private const val VAL_0_5 = 0.5
    private const val VAL_20_0 = 20.0
    private const val VAL_300_0 = 300.0
    private const val VAL_4_0 = 4.0
    private const val VAL_50 = 50
    private const val VAL_500_0 = 500.0
    private const val VAL_600_0 = 600.0
    private const val VAL_8 = 8
    private const val VAL_80 = 80
    const val DATAGRAM_ENVELOPE_OVERHEAD_BYTES: Int = 64

    fun route(
        local: MercuryStreamingCapabilitySnapshot,
        remote: MercuryStreamingCapabilitySnapshot,
        policy: MercuryCodecPolicy = MercuryCodecPolicy.PRODUCTION,
        activeSessionRoute: MercuryCodecRoutingDecision? = null,
        timestampMillis: Long = System.currentTimeMillis(),
        runtimeHealth: MercuryRuntimeHealthSnapshot? = null,
    ): MercuryCodecRoutingDecision {
        val wireVersion = MercuryWireVersionNegotiator.resolve(local.mediaFrameVersions, remote.mediaFrameVersions)
        val datagramBudget = remote.videoDatagrams.payloadBudget(DATAGRAM_ENVELOPE_OVERHEAD_BYTES)

        if (activeSessionRoute != null) {
            return activeSessionRoute.copy(
                stats =
                activeSessionRoute.stats.copy(
                    timestampMillis = timestampMillis,
                    runtimeHealth = runtimeHealth,
                ),
                reason = "active session keeps its negotiated codec until restart",
            )
        }

        val codec = MercuryCodecResolver.resolveSendCodec(local, remote, policy)
        val stats =
            MercuryRtcStatsSnapshot(
                timestampMillis = timestampMillis,
                codec = codec,
                wireVersion = wireVersion,
                runtimeHealth = runtimeHealth,
            )
        if (codec == null) {
            return MercuryCodecRoutingDecision(
                status = MercuryCodecRoutingDecision.Status.NO_COMPATIBLE_CODEC,
                codec = null,
                wireVersion = wireVersion,
                datagramPayloadBudgetBytes = datagramBudget,
                stats = stats,
                reason = "no codec has local encode and remote decode support under policy",
            )
        }
        return MercuryCodecRoutingDecision(
            status = MercuryCodecRoutingDecision.Status.ROUTED,
            codec = codec,
            wireVersion = wireVersion,
            datagramPayloadBudgetBytes = datagramBudget,
            stats = stats,
            reason = "selected ${codec.name.lowercase()} from runtime capability probes",
        )
    }
}

data class MercuryBweShadowSample(
    val timestampMillis: ULong,
    val roundTripMillis: Int,
    val packetLossRate: Double,
    val observedBitsPerSecond: Int,
    val expectedPresentationMillis: ULong? = null,
    val actualPresentationMillis: ULong? = null,
    val pacerQueueDepth: Int = 0,
    val isProbe: Boolean = false,
)

data class MercuryBweShadowDecision(
    val shadowTargetBitsPerSecond: Int,
    val delayTrendMillis: Int,
    val lossResponseFactor: Double,
    val probeSamples: Int,
    val pacerQueueDepth: Int,
    val presentTimeErrorMillis: Double?,
    val freezeRiskScore: Double,
    val promotionReady: Boolean,
)

class MercuryShadowBweController(
    private val steps: List<Int>,
    private val minimumPromotionSamples: Int = 30,
) {
    init {
        require(steps.isNotEmpty()) { "MercuryShadowBweController requires at least one step" }
    }

    private val sortedSteps = steps.sorted()
    private var previousRoundTripMillis: Int? = null
    private var sampleCount: Int = 0
    private var probeSamples: Int = 0
    private var cumulativePresentTimeErrorMillis: Double = 0.0
    private var presentTimeErrorSamples: Int = 0
    private var riskySamples: Int = 0

    var currentDecision: MercuryBweShadowDecision =
        MercuryBweShadowDecision(
            shadowTargetBitsPerSecond = sortedSteps.last(),
            delayTrendMillis = 0,
            lossResponseFactor = 1.0,
            probeSamples = 0,
            pacerQueueDepth = 0,
            presentTimeErrorMillis = null,
            freezeRiskScore = 0.0,
            promotionReady = false,
        )
        private set

    fun observe(sample: MercuryBweShadowSample): MercuryBweShadowDecision {
        sampleCount += 1
        if (sample.isProbe) probeSamples += 1
        val delayTrend = previousRoundTripMillis?.let { sample.roundTripMillis - it } ?: 0
        previousRoundTripMillis = sample.roundTripMillis

        val presentError = presentTimeError(sample.expectedPresentationMillis, sample.actualPresentationMillis)
        if (presentError != null) {
            cumulativePresentTimeErrorMillis += abs(presentError)
            presentTimeErrorSamples += 1
        }

        val lossResponse = max(VAL_0_45, 1.0 - min(VAL_0_5, sample.packetLossRate * VAL_4_0))
        val delayPenalty = if (delayTrend > 0) min(VAL_0_30, delayTrend / VAL_600_0) else 0.0
        val rawTarget = (sample.observedBitsPerSecond * lossResponse * (1.0 - delayPenalty)).toInt()
        val quantizedTarget = quantize(rawTarget)

        var risk = 0.0
        if (sample.packetLossRate >= VAL_0_04) risk += min(VAL_0_4, sample.packetLossRate * VAL_4_0)
        if (delayTrend >= VAL_50) risk += min(VAL_0_3, delayTrend / VAL_300_0)
        if (presentError != null && abs(presentError) >= VAL_80) risk += min(VAL_0_2, abs(presentError) / VAL_500_0)
        if (sample.pacerQueueDepth >= VAL_8) risk += min(VAL_0_1, sample.pacerQueueDepth / 100.0)
        risk = min(1.0, risk)
        if (risk > 0.0) riskySamples += 1

        val averagePresentError =
            if (presentTimeErrorSamples == 0) {
                0.0
            } else {
                cumulativePresentTimeErrorMillis / presentTimeErrorSamples
            }
        val promotionReady =
            sampleCount >= minimumPromotionSamples &&
                riskySamples == 0 &&
                averagePresentError <= VAL_20_0 &&
                probeSamples > 0

        currentDecision =
            MercuryBweShadowDecision(
                shadowTargetBitsPerSecond = quantizedTarget,
                delayTrendMillis = delayTrend,
                lossResponseFactor = lossResponse,
                probeSamples = probeSamples,
                pacerQueueDepth = sample.pacerQueueDepth,
                presentTimeErrorMillis = presentError,
                freezeRiskScore = risk,
                promotionReady = promotionReady,
            )
        return currentDecision
    }

    private fun presentTimeError(expected: ULong?, actual: ULong?): Double? {
        if (expected == null || actual == null) return null
        return actual.toLong().minus(expected.toLong()).toDouble()
    }

    private fun quantize(rawTarget: Int): Int {
        if (rawTarget <= sortedSteps.first()) return sortedSteps.first()
        if (rawTarget >= sortedSteps.last()) return sortedSteps.last()
        return sortedSteps.lastOrNull { it <= rawTarget } ?: sortedSteps.first()
    }
}

data class MercuryLtrToken(
    val value: ULong,
)

data class MercuryLtrRecoveryState(
    val refreshRequested: Boolean = false,
    val pendingRefreshTokens: List<MercuryLtrToken> = emptyList(),
    val acknowledgedTokens: List<MercuryLtrToken> = emptyList(),
    val idrFallbacks: Int = 0,
) {
    fun requestRefresh(): MercuryLtrRecoveryState = copy(refreshRequested = true)

    fun recordEncodedRefreshToken(token: ULong?): Pair<MercuryLtrRecoveryState, MercuryLtrToken?> {
        if (token == null) {
            return copy(refreshRequested = false, idrFallbacks = idrFallbacks + 1) to null
        }
        val wrapped = MercuryLtrToken(token)
        return copy(
            refreshRequested = false,
            pendingRefreshTokens = pendingRefreshTokens + wrapped,
        ) to wrapped
    }

    fun acknowledgeDecodedToken(token: MercuryLtrToken): MercuryLtrRecoveryState = copy(
        pendingRefreshTokens = pendingRefreshTokens.filterNot { it == token },
        acknowledgedTokens = if (acknowledgedTokens.contains(token)) acknowledgedTokens else acknowledgedTokens + token,
    )

    fun markRecoveryFailed(): MercuryLtrRecoveryState = copy(
        refreshRequested = true,
        acknowledgedTokens = emptyList(),
        idrFallbacks = idrFallbacks + 1,
    )

    val acknowledgedTokenValuesForEncoder: List<ULong>
        get() = acknowledgedTokens.map { it.value }
}

enum class MercuryFrameDelivery {
    RELIABLE_STREAM,
    DATAGRAM,
}

data class MercuryDatagramSchedulingDecision(
    val delivery: MercuryFrameDelivery,
    val payloadBudgetBytes: Int?,
    val reason: String,
)

object MercuryVideoDatagramScheduler {
    fun schedule(
        frame: MediaFrame,
        datagramsEnabled: Boolean,
        remoteCapability: MercuryDatagramCapability,
        overheadBytes: Int = MercuryCodecRouter.DATAGRAM_ENVELOPE_OVERHEAD_BYTES,
        carriesParameterSets: Boolean = false,
    ): MercuryDatagramSchedulingDecision {
        val budget = remoteCapability.payloadBudget(overheadBytes)
        val reliableReason =
            when {
                !datagramsEnabled -> "experiment flag disabled"
                MediaFrame.Flags.KEYFRAME in frame.flags || carriesParameterSets ->
                    "keyframes and parameter sets stay reliable"
                budget == null -> "runtime datagram max payload is unavailable"
                frame.payload.size > budget -> "payload exceeds runtime datagram budget"
                else -> null
            }
        return if (reliableReason != null) {
            MercuryDatagramSchedulingDecision(
                delivery = MercuryFrameDelivery.RELIABLE_STREAM,
                payloadBudgetBytes = if (datagramsEnabled) budget else null,
                reason = reliableReason,
            )
        } else {
            MercuryDatagramSchedulingDecision(
                delivery = MercuryFrameDelivery.DATAGRAM,
                payloadBudgetBytes = budget,
                reason = "delta video frame fits runtime datagram budget",
            )
        }
    }
}

data class MercuryBenchmarkEvidence(
    val coveredImpairmentScenarios: List<MercuryImpairmentScenario>,
    val freezeCountImprovementPercent: Double,
    val presentTimeErrorDeltaMillis: Double,
    val cpuUsageDeltaPercent: Double,
    val batteryDrainDeltaPercent: Double,
) {
    val coversDefaultMatrix: Boolean
        get() = coveredImpairmentScenarios.toSet() == MercuryImpairmentScenario.DEFAULT_MATRIX.toSet()

    val isPositive: Boolean
        get() =
            coversDefaultMatrix &&
                freezeCountImprovementPercent > 0.0 &&
                presentTimeErrorDeltaMillis <= 0.0 &&
                cpuUsageDeltaPercent <= 5.0 &&
                batteryDrainDeltaPercent <= 5.0
}

data class MercuryAdvancedFeatureDecision(
    val fecEnabled: Boolean,
    val temporalLayersEnabled: Boolean,
    val roiEnabled: Boolean,
    val reasons: List<String>,
)

object MercuryAdvancedFeatureGate {
    fun evaluate(
        local: MercuryStreamingCapabilitySnapshot,
        remote: MercuryStreamingCapabilitySnapshot,
        benchmark: MercuryBenchmarkEvidence?,
        dirtyRegionHintsSupported: Boolean = false,
    ): MercuryAdvancedFeatureDecision {
        if (benchmark?.isPositive != true) {
            return MercuryAdvancedFeatureDecision(
                fecEnabled = false,
                temporalLayersEnabled = false,
                roiEnabled = false,
                reasons = listOf("benchmark evidence is missing or not positive across the full impairment matrix"),
            )
        }

        val localVideo = local.capability(MercuryVideoCodec.HEVC) ?: local.capability(MercuryVideoCodec.H264)
        val remoteVideo = remote.capability(MercuryVideoCodec.HEVC) ?: remote.capability(MercuryVideoCodec.H264)
        val temporal = localVideo?.temporalLayering == true && remoteVideo?.temporalLayering == true
        val roi = dirtyRegionHintsSupported && localVideo?.screenContentCoding == true
        val reasons =
            buildList {
                add("benchmark evidence covers the full impairment matrix")
                if (!temporal) add("temporal layering is not proven on both peers")
                if (!roi) add("ROI/dirty-region hints are not proven by capture and encoder APIs")
            }
        return MercuryAdvancedFeatureDecision(
            fecEnabled = true,
            temporalLayersEnabled = temporal,
            roiEnabled = roi,
            reasons = reasons,
        )
    }
}
