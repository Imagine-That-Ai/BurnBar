package com.openburnbar.data.models

import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName

// Plan 2 — Android counterpart of `ProviderAccountDeviceLinkDoc` in
// `functions/src/types.ts`. Persisted at:
//   users/{uid}/provider_account_device_links/{accountID}_{deviceID}
//
// Reads are owner-scoped (firestore.rules). Writes funnel exclusively
// through the adoptProviderAccountForDevice /
// revokeProviderAccountDeviceLink / backfillProviderAccountDeviceLinks
// callables on the functions side.

enum class DeviceLinkCapability(val token: String) {
    OWNER("owner"),
    USE("use"),
    ADD("add");

    companion object {
        fun fromToken(value: String?): DeviceLinkCapability =
            values().firstOrNull { it.token == value } ?: USE
    }
}

enum class DeviceLinkStatus(val token: String) {
    ACTIVE("active"),
    REVOKED("revoked");

    companion object {
        fun fromToken(value: String?): DeviceLinkStatus =
            values().firstOrNull { it.token == value } ?: ACTIVE
    }
}

@IgnoreExtraProperties
data class ProviderAccountDeviceLink(
    @get:PropertyName("id") @set:PropertyName("id") var id: String = "",
    @get:PropertyName("accountID") @set:PropertyName("accountID") var accountId: String = "",
    @get:PropertyName("deviceID") @set:PropertyName("deviceID") var deviceId: String = "",
    @get:PropertyName("deviceDisplayName")
    @set:PropertyName("deviceDisplayName")
    var deviceDisplayName: String = "",
    var capability: String = DeviceLinkCapability.USE.token,
    var status: String = DeviceLinkStatus.ACTIVE.token,
    @get:PropertyName("lastObservedAt")
    @set:PropertyName("lastObservedAt")
    var lastObservedAtMillis: Long = 0L,
    @get:PropertyName("createdAt")
    @set:PropertyName("createdAt")
    var createdAtMillis: Long = 0L,
    @get:PropertyName("updatedAt")
    @set:PropertyName("updatedAt")
    var updatedAtMillis: Long = 0L,
    var schemaVersion: Int = 1
) {
    val resolvedCapability: DeviceLinkCapability
        get() = DeviceLinkCapability.fromToken(capability)

    val resolvedStatus: DeviceLinkStatus
        get() = DeviceLinkStatus.fromToken(status)
}
