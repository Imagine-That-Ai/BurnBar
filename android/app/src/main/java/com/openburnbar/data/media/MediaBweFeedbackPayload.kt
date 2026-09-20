package com.openburnbar.data.media

import org.json.JSONObject

/**
 * JSON payload inside `MediaFrame.Kind.BWE_FEEDBACK`. 1:1 port of
 * `MediaBweFeedbackPayload.swift`.
 */
data class MediaBweFeedbackPayload(
    val roundTripMillis: Int,
    val packetLossRate: Double,
    val observedBitsPerSecond: Int,
    val pathConstrained: Boolean,
) {
    fun toSample(): BweEstimator.Sample =
        BweEstimator.Sample(
            roundTripMillis = roundTripMillis,
            packetLossRate = packetLossRate,
            observedBitsPerSecond = observedBitsPerSecond,
            pathConstrained = pathConstrained,
        )

    fun encoded(): ByteArray =
        JSONObject()
            .put("observedBitsPerSecond", observedBitsPerSecond)
            .put("packetLossRate", packetLossRate)
            .put("pathConstrained", pathConstrained)
            .put("roundTripMillis", roundTripMillis)
            .toString()
            .toByteArray(Charsets.UTF_8)

    companion object {
        fun decode(data: ByteArray): MediaBweFeedbackPayload {
            val json = JSONObject(String(data, Charsets.UTF_8))
            return MediaBweFeedbackPayload(
                roundTripMillis = json.getInt("roundTripMillis"),
                packetLossRate = json.getDouble("packetLossRate"),
                observedBitsPerSecond = json.getInt("observedBitsPerSecond"),
                pathConstrained = json.optBoolean("pathConstrained", false),
            )
        }

        fun decodeIfPresent(frame: MediaFrame): MediaBweFeedbackPayload? {
            if (frame.kind != MediaFrame.Kind.BWE_FEEDBACK) return null
            return runCatching { decode(frame.payload) }.getOrNull()
        }

        fun isConstrainedPath(usesCellular: Boolean, isExpensive: Boolean, isConstrained: Boolean): Boolean =
            usesCellular || isExpensive || isConstrained
    }
}
