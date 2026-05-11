package com.openburnbar.data.firebase

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.tasks.await
import org.json.JSONObject

class FunctionsRepository {
    private val functions: FirebaseFunctions = Firebase.functions

    suspend fun searchStreams(query: String, limit: Int = 20): List<Map<String, Any>> {
        val result = functions.getHttpsCallable("searchStreams")
            .call(mapOf("query" to query, "limit" to limit))
            .await()
        val data = result.getData() as? Map<*, *> ?: return emptyList()
        @Suppress("UNCHECKED_CAST")
        return data["results"] as? List<Map<String, Any>> ?: emptyList()
    }

    suspend fun rebuildUsageRollups() {
        functions.getHttpsCallable("rebuildUsageRollups").call().await()
    }

    suspend fun refreshQuota(accountId: String, providerId: String): Map<String, Any> {
        val result = functions.getHttpsCallable("refreshQuota")
            .call(mapOf("accountId" to accountId, "providerId" to providerId))
            .await()
        @Suppress("UNCHECKED_CAST")
        return result.getData() as? Map<String, Any> ?: emptyMap()
    }

    suspend fun deleteProviderAccount(accountId: String) {
        functions.getHttpsCallable("deleteProviderAccount")
            .call(mapOf("accountId" to accountId))
            .await()
    }

    suspend fun addProviderConnection(providerId: String, credentials: Map<String, String>): Map<String, Any> {
        val result = functions.getHttpsCallable("addProviderConnection")
            .call(mapOf("providerId" to providerId, "credentials" to credentials))
            .await()
        @Suppress("UNCHECKED_CAST")
        return result.getData() as? Map<String, Any> ?: emptyMap()
    }
}
