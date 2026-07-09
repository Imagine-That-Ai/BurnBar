package com.openburnbar.data.community

import com.google.firebase.functions.FirebaseFunctions
import com.openburnbar.data.firebase.asStringAnyMap
import kotlinx.coroutines.tasks.await

class CommunityFunctions(
    private val functions: FirebaseFunctions = FirebaseFunctions.getInstance(),
) {
    suspend fun joinCommunity(payload: Map<String, Any?>): Map<String, Any> {
        val wire = payload.mapNotNull { (k, v) -> v?.let { k to it } }.toMap()
        return functions.getHttpsCallable("joinCommunity").call(wire).await().getData().asStringAnyMap() ?: emptyMap()
    }

    suspend fun updateCommunityProfile(payload: Map<String, Any?>): Map<String, Any> {
        val wire = payload.mapNotNull { (k, v) -> v?.let { k to it } }.toMap()
        return functions.getHttpsCallable("updateCommunityProfile").call(wire).await().getData().asStringAnyMap() ?: emptyMap()
    }

    suspend fun revokeCommunityParticipation(): Map<String, Any> {
        return functions.getHttpsCallable("revokeCommunityParticipation").call(emptyMap<String, Any>())
            .await().getData().asStringAnyMap() ?: emptyMap()
    }

    suspend fun exportLookingGlassBundle(format: String = "jsonl"): Map<String, Any> {
        return functions.getHttpsCallable("exportLookingGlassBundle").call(mapOf("format" to format))
            .await().getData().asStringAnyMap() ?: emptyMap()
    }
}