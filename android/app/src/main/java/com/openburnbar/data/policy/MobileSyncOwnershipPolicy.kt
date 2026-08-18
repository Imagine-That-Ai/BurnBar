package com.openburnbar.data.policy

enum class MobileSyncPublisherRole(val wire: String) {
    MAC_PUBLISHES("mac-publishes"),
    MOBILE_MIRRORS_READ_ONLY("mobile-mirrors-read-only"),
}

enum class MobileSyncFreshness(val wire: String, val label: String) {
    LIVE("live", "Live"),
    STALE("stale", "Stale"),
    OFFLINE("offline", "Offline"),
    EMPTY("empty", "No Mac-published data"),
    FAILED("failed", "Cloud load failed"),
    PARTIAL("partial", "Partial"),
    ;

    val looksLikeLiveZero: Boolean get() = this == LIVE
}

object MobileSyncOwnershipPolicy {
    val macRole = MobileSyncPublisherRole.MAC_PUBLISHES
    val mobileRole = MobileSyncPublisherRole.MOBILE_MIRRORS_READ_ONLY
    const val mobileMayPublishUsage = false

    fun freshness(
        hasData: Boolean,
        failed: Boolean,
        offline: Boolean,
        stale: Boolean,
        partial: Boolean,
    ): MobileSyncFreshness = when {
        failed -> MobileSyncFreshness.FAILED
        offline -> MobileSyncFreshness.OFFLINE
        !hasData -> MobileSyncFreshness.EMPTY
        partial -> MobileSyncFreshness.PARTIAL
        stale -> MobileSyncFreshness.STALE
        else -> MobileSyncFreshness.LIVE
    }

    fun shouldApply(startedGeneration: Int, currentGeneration: Int, cancelled: Boolean): Boolean =
        !cancelled && startedGeneration == currentGeneration

    fun nextGeneration(current: Int): Int = current + 1
}
