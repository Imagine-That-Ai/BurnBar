package com.openburnbar.data.stores

import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.firebase.FirestoreValueParsers
import java.util.Date

internal data class MacSyncDeviceContext(
    val macDeviceId: String,
    val macName: String,
    val macDeviceDoc: DocumentSnapshot?,
)

internal fun resolveMacSyncDeviceContext(macDevice: DocumentSnapshot?): MacSyncDeviceContext? {
    val macDeviceId =
        macDevice?.data?.get("deviceId") as? String
            ?: macDevice?.id
            ?: return null
    val macName = macDevice?.data?.get("deviceName") as? String ?: "Mac"
    return MacSyncDeviceContext(macDeviceId = macDeviceId, macName = macName, macDeviceDoc = macDevice)
}

internal fun macDeviceLastActiveMillis(doc: DocumentSnapshot): Long = (
    (doc.data?.get("lastActiveAt") as? Timestamp)?.toDate()
        ?: doc.data?.get("lastActiveAt") as? Date
    )
    ?.time ?: 0L

internal fun applySyncStatusDocument(data: Map<String, Any?>, macName: String, staleThresholdMs: Long, now: Date = Date()): CloudSyncHealthSnapshot {
    val publishedAt =
        cloudSyncDateValue(data["lastSyncAt"])
            ?: cloudSyncDateValue(data["lastPublishedAt"])
    val readAt = cloudSyncDateValue(data["lastReadAt"])
    val pubData = data["publisher"] as? Map<*, *>
    val publisher =
        pubData?.let {
            CloudPublisherDevice(
                displayName = it["displayName"] as? String ?: "",
                platform = it["platform"] as? String ?: "",
                lastSeen = (it["lastSeen"] as? Timestamp)?.toDate(),
            )
        } ?: CloudPublisherDevice(
            displayName = macName,
            platform = "macOS",
            lastSeen = publishedAt,
        )
    val stale = publishedAt?.let { now.time - it.time > staleThresholdMs } ?: true
    val lastError = data["lastError"] as? String
    val health =
        when {
            lastError != null -> CloudSyncHealth.DEGRADED
            stale -> CloudSyncHealth.DEGRADED
            else -> CloudSyncHealth.HEALTHY
        }
    return CloudSyncHealthSnapshot(
        health = health,
        lastPublishedAt = publishedAt,
        lastReadAt = readAt,
        publisher = publisher,
    )
}

internal fun applyUsageFallbackSnapshot(data: Map<String, Any>?, staleThresholdMs: Long): CloudSyncHealthSnapshot {
    val usageAt =
        data?.let {
            cloudSyncDateValue(it["startTime"])
                ?: cloudSyncDateValue(it["timestamp"])
                ?: cloudSyncDateValue(it["updatedAt"])
        }
    val publisher =
        data?.let {
            CloudPublisherDevice(
                displayName = it["sourceDeviceName"] as? String ?: it["deviceName"] as? String ?: "Mac",
                platform = "macOS",
                lastSeen = usageAt,
            )
        }
    val health =
        when {
            usageAt == null -> CloudSyncHealth.UNKNOWN
            Date().time - usageAt.time > staleThresholdMs -> CloudSyncHealth.DEGRADED
            else -> CloudSyncHealth.HEALTHY
        }
    return CloudSyncHealthSnapshot(
        health = health,
        lastPublishedAt = usageAt,
        lastReadAt = Date(),
        publisher = publisher,
    )
}

internal data class CloudSyncHealthSnapshot(
    val health: CloudSyncHealth,
    val lastPublishedAt: Date?,
    val lastReadAt: Date?,
    val publisher: CloudPublisherDevice?,
)

internal fun cloudSyncDateValue(raw: Any?): Date? {
    val millis = FirestoreValueParsers.millis(raw)
    return millis.takeIf { it > 0L }?.let { Date(it) }
}
