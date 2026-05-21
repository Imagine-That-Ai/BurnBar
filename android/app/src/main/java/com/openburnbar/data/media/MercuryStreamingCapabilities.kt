package com.openburnbar.data.media

import com.openburnbar.irohrelay.HermesRealtimeRelayDatagramCapability
import com.openburnbar.irohrelay.HermesRealtimeRelayMediaFrameVersionSupport
import com.openburnbar.irohrelay.HermesRealtimeRelayStreamingCapabilities
import com.openburnbar.irohrelay.HermesRealtimeRelayVideoCodec
import com.openburnbar.irohrelay.HermesRealtimeRelayVideoCodecCapability

enum class MercuryVideoCodec(val mimeType: String) {
    AV1("video/av01"),
    HEVC("video/hevc"),
    H264("video/avc"),
}

data class MercuryVideoCodecCapability(
    val codec: MercuryVideoCodec,
    val canEncode: Boolean,
    val canDecode: Boolean,
    val hardwareAccelerated: Boolean,
    val lowLatencyEncode: Boolean = false,
    val temporalLayering: Boolean = false,
    val longTermReference: Boolean = false,
    val screenContentCoding: Boolean = false,
)

data class MercuryMediaFrameVersionSupport(
    val supportsV1: Boolean = true,
    val supportsV2: Boolean = false,
) {
    companion object {
        val V1_ONLY = MercuryMediaFrameVersionSupport(supportsV1 = true, supportsV2 = false)
        val V1_AND_V2 = MercuryMediaFrameVersionSupport(supportsV1 = true, supportsV2 = true)
    }
}

enum class MercuryMediaFrameWireVersion {
    V1,
    V2,
}

data class MercuryDatagramCapability(
    val maxPayloadBytes: Int?,
) {
    val isSupported: Boolean
        get() = maxPayloadBytes != null && maxPayloadBytes > 0

    fun payloadBudget(reservingOverheadBytes: Int): Int? {
        val max = maxPayloadBytes ?: return null
        if (max <= reservingOverheadBytes) return null
        return max - reservingOverheadBytes
    }
}

object MercuryDatagramCapabilityProbe {
    fun snapshot(maxDatagramSize: Int?): MercuryDatagramCapability =
        MercuryDatagramCapability(maxPayloadBytes = maxDatagramSize?.takeIf { it > 0 })

    suspend fun snapshot(readMaxDatagramSize: suspend () -> Int): MercuryDatagramCapability =
        runCatching { snapshot(readMaxDatagramSize()) }.getOrDefault(MercuryDatagramCapability(maxPayloadBytes = null))
}

data class MercuryStreamingCapabilitySnapshot(
    val codecCapabilities: List<MercuryVideoCodecCapability>,
    val mediaFrameVersions: MercuryMediaFrameVersionSupport = MercuryMediaFrameVersionSupport.V1_ONLY,
    val videoDatagrams: MercuryDatagramCapability = MercuryDatagramCapability(maxPayloadBytes = null),
    val source: String,
) {
    fun capability(codec: MercuryVideoCodec): MercuryVideoCodecCapability? =
        codecCapabilities.firstOrNull { it.codec == codec }

    fun canEncode(codec: MercuryVideoCodec): Boolean = capability(codec)?.canEncode == true

    fun canDecode(codec: MercuryVideoCodec): Boolean = capability(codec)?.canDecode == true
}

data class MercuryCodecPolicy(
    val allowExperimentalAV1: Boolean = false,
    val preferredCodecs: List<MercuryVideoCodec> = listOf(
        MercuryVideoCodec.AV1,
        MercuryVideoCodec.HEVC,
        MercuryVideoCodec.H264,
    ),
) {
    companion object {
        val PRODUCTION = MercuryCodecPolicy(
            allowExperimentalAV1 = false,
            preferredCodecs = listOf(MercuryVideoCodec.HEVC, MercuryVideoCodec.H264),
        )

        val EXPERIMENTAL_AV1 = MercuryCodecPolicy(
            allowExperimentalAV1 = true,
            preferredCodecs = listOf(MercuryVideoCodec.AV1, MercuryVideoCodec.HEVC, MercuryVideoCodec.H264),
        )
    }
}

object MercuryCodecResolver {
    fun resolveSendCodec(
        local: MercuryStreamingCapabilitySnapshot,
        remote: MercuryStreamingCapabilitySnapshot,
        policy: MercuryCodecPolicy = MercuryCodecPolicy.PRODUCTION,
    ): MercuryVideoCodec? {
        for (codec in policy.preferredCodecs) {
            if (codec == MercuryVideoCodec.AV1 && !policy.allowExperimentalAV1) continue
            if (local.canEncode(codec) && remote.canDecode(codec)) return codec
        }
        return null
    }
}

object MercuryWireVersionNegotiator {
    fun resolve(
        local: MercuryMediaFrameVersionSupport,
        remote: MercuryMediaFrameVersionSupport,
    ): MercuryMediaFrameWireVersion =
        if (local.supportsV2 && remote.supportsV2) MercuryMediaFrameWireVersion.V2 else MercuryMediaFrameWireVersion.V1

    fun canSendMetadataV2(
        local: MercuryMediaFrameVersionSupport,
        remote: MercuryMediaFrameVersionSupport,
    ): Boolean = resolve(local, remote) == MercuryMediaFrameWireVersion.V2
}

fun MercuryVideoCodec.toWire(): HermesRealtimeRelayVideoCodec = when (this) {
    MercuryVideoCodec.AV1 -> HermesRealtimeRelayVideoCodec.AV1
    MercuryVideoCodec.HEVC -> HermesRealtimeRelayVideoCodec.HEVC
    MercuryVideoCodec.H264 -> HermesRealtimeRelayVideoCodec.H264
}

fun HermesRealtimeRelayVideoCodec.toMercury(): MercuryVideoCodec = when (this) {
    HermesRealtimeRelayVideoCodec.AV1 -> MercuryVideoCodec.AV1
    HermesRealtimeRelayVideoCodec.HEVC -> MercuryVideoCodec.HEVC
    HermesRealtimeRelayVideoCodec.H264 -> MercuryVideoCodec.H264
}

fun MercuryVideoCodecCapability.toWire(): HermesRealtimeRelayVideoCodecCapability =
    HermesRealtimeRelayVideoCodecCapability(
        codec = codec.toWire(),
        canEncode = canEncode,
        canDecode = canDecode,
        hardwareAccelerated = hardwareAccelerated,
        lowLatencyEncode = lowLatencyEncode,
        temporalLayering = temporalLayering,
        longTermReference = longTermReference,
        screenContentCoding = screenContentCoding,
    )

fun HermesRealtimeRelayVideoCodecCapability.toMercury(): MercuryVideoCodecCapability =
    MercuryVideoCodecCapability(
        codec = codec.toMercury(),
        canEncode = canEncode,
        canDecode = canDecode,
        hardwareAccelerated = hardwareAccelerated,
        lowLatencyEncode = lowLatencyEncode,
        temporalLayering = temporalLayering,
        longTermReference = longTermReference,
        screenContentCoding = screenContentCoding,
    )

fun MercuryMediaFrameVersionSupport.toWire(): HermesRealtimeRelayMediaFrameVersionSupport =
    HermesRealtimeRelayMediaFrameVersionSupport(
        supportsV1 = supportsV1,
        supportsV2 = supportsV2,
    )

fun HermesRealtimeRelayMediaFrameVersionSupport.toMercury(): MercuryMediaFrameVersionSupport =
    MercuryMediaFrameVersionSupport(
        supportsV1 = supportsV1,
        supportsV2 = supportsV2,
    )

fun MercuryDatagramCapability.toWire(): HermesRealtimeRelayDatagramCapability =
    HermesRealtimeRelayDatagramCapability(maxPayloadBytes = maxPayloadBytes)

fun HermesRealtimeRelayDatagramCapability.toMercury(): MercuryDatagramCapability =
    MercuryDatagramCapability(maxPayloadBytes = maxPayloadBytes)

fun MercuryStreamingCapabilitySnapshot.toWire(): HermesRealtimeRelayStreamingCapabilities =
    HermesRealtimeRelayStreamingCapabilities(
        codecCapabilities = codecCapabilities.map { it.toWire() },
        mediaFrameVersions = mediaFrameVersions.toWire(),
        videoDatagrams = videoDatagrams.toWire(),
        source = source,
    )

fun HermesRealtimeRelayStreamingCapabilities.toMercury(): MercuryStreamingCapabilitySnapshot =
    MercuryStreamingCapabilitySnapshot(
        codecCapabilities = codecCapabilities.map { it.toMercury() },
        mediaFrameVersions = mediaFrameVersions.toMercury(),
        videoDatagrams = videoDatagrams.toMercury(),
        source = source,
    )
