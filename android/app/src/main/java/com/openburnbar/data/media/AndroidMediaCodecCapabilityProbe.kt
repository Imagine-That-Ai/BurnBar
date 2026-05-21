package com.openburnbar.data.media

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

object AndroidMediaCodecCapabilityProbe {
    fun snapshot(
        datagramMaxPayloadBytes: Int? = null,
        mediaFrameVersions: MercuryMediaFrameVersionSupport = MercuryMediaFrameVersionSupport.V1_ONLY,
    ): MercuryStreamingCapabilitySnapshot =
        MercuryStreamingCapabilitySnapshot(
            codecCapabilities = MercuryVideoCodec.entries.map { capability(it) },
            mediaFrameVersions = mediaFrameVersions,
            videoDatagrams = MercuryDatagramCapability(maxPayloadBytes = datagramMaxPayloadBytes),
            source = "MediaCodec",
        )

    fun capability(codec: MercuryVideoCodec): MercuryVideoCodecCapability {
        val encoders = codecInfos(codec, encoder = true)
        val decoders = codecInfos(codec, encoder = false)
        return MercuryVideoCodecCapability(
            codec = codec,
            canEncode = encoders.isNotEmpty(),
            canDecode = decoders.isNotEmpty(),
            hardwareAccelerated = (encoders + decoders).any { it.isHardwareAcceleratedCompat() },
            lowLatencyEncode = encoders.any { it.supportsLowLatency(codec) },
            temporalLayering = false,
            longTermReference = false,
            screenContentCoding = false,
        )
    }

    private fun codecInfos(codec: MercuryVideoCodec, encoder: Boolean): List<MediaCodecInfo> =
        runCatching {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .filter { it.isEncoder == encoder }
                .filter { info -> info.supportedTypes.any { it.equals(codec.mimeType, ignoreCase = true) } }
        }.getOrDefault(emptyList())

    private fun MediaCodecInfo.isHardwareAcceleratedCompat(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            isHardwareAccelerated
        } else {
            !name.contains("google", ignoreCase = true) &&
                !name.contains("software", ignoreCase = true) &&
                !name.startsWith("omx.ffmpeg", ignoreCase = true)
        }

    private fun MediaCodecInfo.supportsLowLatency(codec: MercuryVideoCodec): Boolean =
        runCatching {
            val capabilities = getCapabilitiesForType(codec.mimeType)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                capabilities.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        }.getOrDefault(false)
}
