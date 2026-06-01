package com.openburnbar.data.media

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.tasks.await

private object MediaAnalyticsBuckets {
    const val ROUND_TRIP_LT_50_MS = 50
    const val ROUND_TRIP_LT_150_MS = 150
    const val ROUND_TRIP_LT_400_MS = 400
    const val SESSION_LT_30_SECONDS = 30
    const val SESSION_LT_120_SECONDS = 120
    const val SESSION_LT_600_SECONDS = 600
    const val SESSION_LT_1800_SECONDS = 1800
    const val SESSION_LT_3600_SECONDS = 3600
    const val TRANSFER_MB_LT_10 = 10
    const val BYTES_PER_MEGABYTE = 1_000_000
    const val BYTES_PER_MEGABYTE_DOUBLE = 1_000_000.0
    const val BITRATE_LT_300_KBPS = 300_000
    const val BITRATE_LT_600_KBPS = 600_000
    const val BITRATE_LT_1_MBPS = 1_000_000
    const val BITRATE_LT_2_MBPS = 2_000_000
    const val BITRATE_LT_4_MBPS = 4_000_000
    const val BITRATE_LT_8_MBPS = 8_000_000
    const val CONTROL_STREAM_REASON_MAX_CHARS = 120
    const val FREEZE_COUNT_LOW_MAX = 3
    const val FREEZE_COUNT_MID_MAX = 10
}

/**
 * 1:1 Kotlin port of `MediaAnalyticsLogger` (iOS + Mac side). Writes
 * structured analytics envelopes into the existing `iroh_audit_events`
 * collection so the existing `rollupIrohTransportDaily` Cloud Function
 * picks Android up automatically — same shape, same daily rollup.
 *
 * Privacy posture mirrors the iOS sink: every parameter is a bucketed
 * enum or count. Filenames, hashes, peer NodeIds, frame contents, and
 * payload bytes never appear in the event dictionary.
 */
class MediaAnalyticsLogger(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
) {
    enum class EventName(val raw: String) {
        SESSION_STARTED("media_session_started"),
        SESSION_ENDED("media_session_ended"),
        TRANSFER_COMPLETED("media_transfer_completed"),
        TRANSFER_FAILED("media_transfer_failed"),
        QUOTA_DENIED("media_quota_denied"),
        BUDGET_LEVEL_CHANGED("media_budget_level_changed"),
        CONTROL_STREAM_CONNECTED("media_control_stream_connected"),
        CONTROL_STREAM_LOST("media_control_stream_lost"),
    }

    suspend fun record(event: EventName, parameters: Map<String, Any?> = emptyMap()) {
        val uid = auth.currentUser?.uid ?: return
        val payload =
            mapOf(
                "name" to event.raw,
                "platform" to "android",
                "occurredAtMillis" to nowMillis(),
                "parameters" to parameters.filterValues { it != null },
            )
        try {
            firestore.collection("users").document(uid)
                .collection("iroh_audit_events").document()
                .set(payload).await()
        } catch (_: Throwable) {
            // Telemetry must never break a media session — the rollup
            // function is best-effort.
        }
    }

    suspend fun sessionStarted(feature: MediaStreamClass.Feature, streamClass: MediaStreamClass) = record(
        EventName.SESSION_STARTED,
        mapOf(
            "feature" to featureRaw(feature),
            "streamClass" to streamClass.raw,
        ),
    )

    suspend fun sessionEnded(
        feature: MediaStreamClass.Feature,
        durationSeconds: Double,
        endReason: String,
        freezeCount: Int,
        p95RoundTripMillis: Int? = null,
        p95BitsPerSecond: Int? = null,
    ) = record(
        EventName.SESSION_ENDED,
        mapOf(
            "feature" to featureRaw(feature),
            "endReason" to endReason,
            "durationBucket" to sessionDurationBucket(durationSeconds),
            "freezeCountBucket" to freezeCountBucket(freezeCount),
            "p95RoundTripBucket" to p95RoundTripMillis?.let { roundTripBucket(it) },
            "p95BitsPerSecondBucket" to p95BitsPerSecond?.let { bitrateBucket(it) },
        ),
    )

    suspend fun transferCompleted(sizeBytes: Long, durationSeconds: Double, didResume: Boolean) = record(
        EventName.TRANSFER_COMPLETED,
        mapOf(
            "sizeBucket" to transferSizeBucket(sizeBytes),
            "durationBucket" to sessionDurationBucket(durationSeconds),
            "didResume" to didResume,
        ),
    )

    suspend fun transferFailed(sizeBytes: Long, failureCode: String) = record(
        EventName.TRANSFER_FAILED,
        mapOf("sizeBucket" to transferSizeBucket(sizeBytes), "failureCode" to failureCode),
    )

    suspend fun quotaDenied(feature: MediaStreamClass.Feature, reason: String) = record(
        EventName.QUOTA_DENIED,
        mapOf("feature" to featureRaw(feature), "quotaReason" to reason),
    )

    suspend fun controlStreamConnected() = record(EventName.CONTROL_STREAM_CONNECTED)

    suspend fun controlStreamLost(reason: String) = record(
        EventName.CONTROL_STREAM_LOST,
        mapOf("reason" to reason.take(MediaAnalyticsBuckets.CONTROL_STREAM_REASON_MAX_CHARS)),
    )

    private fun featureRaw(feature: MediaStreamClass.Feature): String = when (feature) {
        MediaStreamClass.Feature.FILE_TRANSFER -> "fileTransfer"
        MediaStreamClass.Feature.SCREEN_SHARE -> "screenShare"
        MediaStreamClass.Feature.VIDEO_CALL -> "videoCall"
        MediaStreamClass.Feature.COMPUTER_USE -> "computerUse"
    }

    companion object Buckets {
        fun sessionDurationBucket(duration: Double): String = when {
            duration < MediaAnalyticsBuckets.SESSION_LT_30_SECONDS -> "lt_30s"
            duration < MediaAnalyticsBuckets.SESSION_LT_120_SECONDS -> "30s_2m"
            duration < MediaAnalyticsBuckets.SESSION_LT_600_SECONDS -> "2m_10m"
            duration < MediaAnalyticsBuckets.SESSION_LT_1800_SECONDS -> "10m_30m"
            duration < MediaAnalyticsBuckets.SESSION_LT_3600_SECONDS -> "30m_60m"
            else -> "gte_60m"
        }

        fun transferSizeBucket(bytes: Long): String {
            val mb = bytes.toDouble() / MediaAnalyticsBuckets.BYTES_PER_MEGABYTE_DOUBLE
            return when {
                mb < 1 -> "lt_1mb"
                mb < MediaAnalyticsBuckets.TRANSFER_MB_LT_10 -> "1_10mb"
                mb < 100 -> "10_100mb"
                mb < 1000 -> "100mb_1gb"
                else -> "gte_1gb"
            }
        }

        fun roundTripBucket(millis: Int): String = when {
            millis < MediaAnalyticsBuckets.ROUND_TRIP_LT_50_MS -> "lt_50ms"
            millis < MediaAnalyticsBuckets.ROUND_TRIP_LT_150_MS -> "50_150ms"
            millis < MediaAnalyticsBuckets.ROUND_TRIP_LT_400_MS -> "150_400ms"
            else -> "gte_400ms"
        }

        fun freezeCountBucket(count: Int): String = when {
            count == 0 -> "0"
            count in 1..MediaAnalyticsBuckets.FREEZE_COUNT_LOW_MAX -> "1_3"
            count in MediaAnalyticsBuckets.FREEZE_COUNT_LOW_MAX + 1..MediaAnalyticsBuckets.FREEZE_COUNT_MID_MAX -> "4_10"
            else -> "gt_10"
        }

        fun bitrateBucket(bps: Int): String = when {
            bps < MediaAnalyticsBuckets.BITRATE_LT_300_KBPS -> "lt_300kbps"
            bps < MediaAnalyticsBuckets.BITRATE_LT_600_KBPS -> "300_600kbps"
            bps < MediaAnalyticsBuckets.BITRATE_LT_1_MBPS -> "600kbps_1mbps"
            bps < MediaAnalyticsBuckets.BITRATE_LT_2_MBPS -> "1_2mbps"
            bps < MediaAnalyticsBuckets.BITRATE_LT_4_MBPS -> "2_4mbps"
            bps < MediaAnalyticsBuckets.BITRATE_LT_8_MBPS -> "4_8mbps"
            else -> "gte_8mbps"
        }
    }
}
