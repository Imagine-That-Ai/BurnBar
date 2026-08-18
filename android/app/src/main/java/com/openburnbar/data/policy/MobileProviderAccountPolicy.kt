package com.openburnbar.data.policy

enum class MobileProviderConnectivity(val wire: String) {
    LOCAL_ONLY("local-only"),
    CLOUD_CONNECTED("cloud-connected"),
}

enum class MobileProviderErrorClass(val wire: String, val userVisibleLabel: String) {
    DENIED("denied", "Permission denied"),
    OFFLINE("offline", "Offline"),
    EXPIRED("expired", "Credential expired"),
    MALFORMED("malformed", "Provider data is malformed"),
}

object MobileProviderAccountPolicy {
    fun connectivity(storageScope: String): MobileProviderConnectivity = when (storageScope) {
        "cloud_refreshable", "server_private" -> MobileProviderConnectivity.CLOUD_CONNECTED
        else -> MobileProviderConnectivity.LOCAL_ONLY
    }

    fun isCloudConnected(storageScope: String): Boolean =
        connectivity(storageScope) == MobileProviderConnectivity.CLOUD_CONNECTED

    fun classifyError(code: String, message: String? = null): MobileProviderErrorClass {
        val haystack = listOf(code, message.orEmpty()).joinToString(" ").replace(" ", "").lowercase()
        return when {
            "permission-denied" in haystack || "permissiondenied" in haystack || "denied" in haystack ->
                MobileProviderErrorClass.DENIED
            "unavailable" in haystack || "network" in haystack || "offline" in haystack ->
                MobileProviderErrorClass.OFFLINE
            "expired" in haystack || "deadline-exceeded" in haystack ->
                MobileProviderErrorClass.EXPIRED
            else -> MobileProviderErrorClass.MALFORMED
        }
    }
}
