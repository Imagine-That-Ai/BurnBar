package com.openburnbar.ui.smartdisplay

import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.tasks.await

internal suspend fun readCastDiscoveryResults(actionId: String?): Result<List<CastDisplayDevice>> = runCatching {
    val uid =
        FirebaseAuth.getInstance().currentUser?.uid
            ?: return@runCatching emptyList()
    val data =
        SmartHubBridgeClient.firestore
            .collection("users")
            .document(uid)
            .collection("cast_discovery_results")
            .document("latest")
            .get()
            .await()
            .data
            .orEmpty()
    val resultActionId = data["actionId"] as? String
    if (!actionId.isNullOrBlank() && resultActionId != null && resultActionId != actionId) {
        return@runCatching emptyList()
    }
    (data["devices"] as? List<*>).orEmpty().mapNotNull { raw ->
        decodeCastDevice(raw.asStringAnyNullableMap() ?: return@mapNotNull null)
    }
}

internal fun decodeCastDevice(data: Map<String, Any?>): CastDisplayDevice? {
    val serviceName = data["serviceName"] as? String ?: return null
    val friendlyName = data["friendlyName"] as? String ?: serviceName
    return CastDisplayDevice(
        serviceName = serviceName,
        friendlyName = friendlyName,
        model = data["model"] as? String ?: "Cast Device",
        host = data["host"] as? String ?: "",
        port = (data["port"] as? Number)?.toInt() ?: 8009,
        identifier = data["identifier"] as? String ?: serviceName,
        iconKind = data["iconKind"] as? String ?: "generic",
        supportsDisplay = data["supportsDisplay"] as? Boolean ?: true,
    )
}
