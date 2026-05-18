package com.openburnbar.data.media

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.tasks.await

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
        val payload = mapOf(
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

    suspend fun sessionStarted(
        feature: MediaStreamClass.Feature,
        streamClass: MediaStreamClass,
    ) = record(
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
        mapOf("reason" to reason.take(120)),
    )

    private fun featureRaw(feature: MediaStreamClass.Feature): String = when (feature) {
        MediaStreamClass.Feature.FILE_TRANSFER -> "fileTransfer"
        MediaStreamClass.Feature.SCREEN_SHARE -> "screenShare"
        MediaStreamClass.Feature.VIDEO_CALL -> "videoCall"
        MediaStreamClass.Feature.COMPUTER_USE -> "computerUse"
    }

    companion object Buckets {
        fun sessionDurationBucket(duration: Double): String = when {
            duration < 30 -> "lt_30s"
            duration < 120 -> "30s_2m"
            duration < 600 -> "2m_10m"
            duration < 1800 -> "10m_30m"
            duration < 3600 -> "30m_60m"
            else -> "gte_60m"
        }

        fun transferSizeBucket(bytes: Long): String {
            val mb = bytes.toDouble() / 1_000_000.0
            return when {
                mb < 1 -> "lt_1mb"
                mb < 10 -> "1_10mb"
                mb < 100 -> "10_100mb"
                mb < 1000 -> "100mb_1gb"
                else -> "gte_1gb"
            }
        }

        fun roundTripBucket(millis: Int): String = when {
            millis < 50 -> "lt_50ms"
            millis < 150 -> "50_150ms"
            millis < 400 -> "150_400ms"
            else -> "gte_400ms"
        }

        fun freezeCountBucket(count: Int): String = when {
            count == 0 -> "0"
            count in 1..3 -> "1_3"
            count in 4..10 -> "4_10"
            else -> "gt_10"
        }

        fun bitrateBucket(bps: Int): String = when {
            bps < 300_000 -> "lt_300kbps"
            bps < 600_000 -> "300_600kbps"
            bps < 1_000_000 -> "600kbps_1mbps"
            bps < 2_000_000 -> "1_2mbps"
            bps < 4_000_000 -> "2_4mbps"
            bps < 8_000_000 -> "4_8mbps"
            else -> "gte_8mbps"
        }
    }
}
