package com.openburnbar.data.firebase

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.cloud.CloudVaultSealedText
import com.openburnbar.data.hermes.PiConnectionMode
import com.openburnbar.data.hermes.PiConnectionStatus
import com.openburnbar.data.models.DeviceLinkCapability
import kotlinx.coroutines.tasks.await

data class CloudConversationSearchHit(
    val id: String,
    val chunkID: String,
    val documentID: String,
    val sourceKind: String,
    val sourceID: String,
    val provider: String?,
    val projectName: String?,
    val sealedTitle: CloudVaultSealedText,
    val sealedSnippet: CloudVaultSealedText,
    val sealedBodyPreview: CloudVaultSealedText?,
    val storagePath: String,
    val bodyHash: String,
    val score: Double,
    val tokenScore: Double? = null,
    val semanticScore: Double? = null,
    val matchKind: String? = null,
    val tokenHashVersion: Int? = null,
    val semanticHashVersion: Int? = null,
    val indexVersion: Int? = null
)

class FunctionsRepository {
    private val functions: FirebaseFunctions = Firebase.functions

    suspend fun searchStreams(query: String, limit: Int = 20): List<Map<String, Any>> {
        val result = functions.getHttpsCallable("searchStreams")
            .call(mapOf("query" to query, "limit" to limit))
            .await()
        val data = result.getData() as? Map<*, *> ?: return emptyList()
        @Suppress("UNCHECKED_CAST")
        return data["hits"] as? List<Map<String, Any>>
            ?: data["results"] as? List<Map<String, Any>>
            ?: emptyList()
    }

    suspend fun searchEncryptedConversationIndex(
        tokenHashes: List<String>,
        semanticHashes: List<String> = emptyList(),
        limit: Int = 25
    ): List<CloudConversationSearchHit> {
        val data = callMap(
            "searchEncryptedConversationIndex",
            mapOf(
                "tokenHashes" to tokenHashes.take(10),
                "semanticHashes" to semanticHashes.take(12),
                "limit" to limit.coerceIn(1, 50)
            )
        )
        @Suppress("UNCHECKED_CAST")
        val hits = data["hits"] as? List<Map<String, Any>> ?: return emptyList()
        return hits.mapNotNull { it.toCloudConversationSearchHit() }
    }

    suspend fun encryptedSessionBlobDownloadURL(storagePath: String): String {
        val data = callMap(
            "getEncryptedSessionBlobDownloadUrl",
            mapOf("storagePath" to storagePath)
        )
        return data["downloadURL"] as? String
            ?: throw IllegalStateException("Encrypted session download URL missing.")
    }

    suspend fun verifyGooglePlayBurnBarProSubscription(
        purchaseToken: String,
        productID: String = "com.openburnbar.pro.monthly"
    ): Map<String, Any> = callMap(
        "verifyGooglePlayBurnBarProSubscription",
        mapOf("purchaseToken" to purchaseToken, "productID" to productID)
    )

    suspend fun rebuildUsageRollups() {
        functions.getHttpsCallable("rebuildUsageRollups").call().await()
    }

    suspend fun seedAndroidDemoAccount(): Map<String, Any> {
        return callMap("seedAndroidDemoAccount", emptyMap())
    }

    suspend fun refreshQuota(accountId: String, providerId: String): Map<String, Any> {
        val result = functions.getHttpsCallable("refreshQuota")
            .call(mapOf("accountId" to accountId, "providerId" to providerId))
            .await()
        @Suppress("UNCHECKED_CAST")
        return result.getData() as? Map<String, Any> ?: emptyMap()
    }

    suspend fun refreshProviderAccountQuota(accountId: String): Map<String, Any> {
        val result = functions.getHttpsCallable("refreshProviderAccountQuota")
            .call(mapOf("accountID" to accountId))
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

    suspend fun createPiAgentPairing(
        deviceId: String? = null,
        platform: String? = null,
        displayName: String? = null
    ): Map<String, Any> {
        val payload = mutableMapOf<String, Any>()
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        platform?.takeIf { it.isNotBlank() }?.let { payload["platform"] = it }
        displayName?.takeIf { it.isNotBlank() }?.let { payload["displayName"] = it }
        return callMap("createPiAgentPairing", payload)
    }

    suspend fun completePiAgentPairing(
        pairingId: String,
        code: String,
        displayName: String,
        endpointURL: String,
        connectionId: String? = null,
        mode: PiConnectionMode = PiConnectionMode.DIRECT_URL,
        advertisedModel: String? = null,
        selectedInstanceId: String? = null,
        redisURL: String? = null,
        capabilities: List<String> = listOf("chat_completions"),
        instances: List<Map<String, Any>> = emptyList(),
        models: List<Map<String, Any>> = emptyList(),
        relayPublicKey: String? = null,
        relayKeyVersion: Int? = null,
        relayEncryption: String? = null,
        realtimeRelayURL: String? = null,
        realtimeRelayStatus: String? = null,
        deviceId: String? = null
    ): Map<String, Any> {
        val payload = mutableMapOf<String, Any>(
            "pairingId" to pairingId,
            "code" to code,
            "displayName" to displayName,
            "mode" to mode.token,
            "endpointURL" to endpointURL,
            "capabilities" to capabilities
        )
        connectionId?.takeIf { it.isNotBlank() }?.let { payload["connectionId"] = it }
        advertisedModel?.takeIf { it.isNotBlank() }?.let { payload["advertisedModel"] = it }
        selectedInstanceId?.takeIf { it.isNotBlank() }?.let { payload["selectedInstanceID"] = it }
        redisURL?.takeIf { it.isNotBlank() }?.let { payload["redisURL"] = it }
        if (instances.isNotEmpty()) payload["instances"] = instances
        if (models.isNotEmpty()) payload["models"] = models
        relayPublicKey?.takeIf { it.isNotBlank() }?.let { payload["relayPublicKey"] = it }
        relayKeyVersion?.let { payload["relayKeyVersion"] = it }
        relayEncryption?.takeIf { it.isNotBlank() }?.let { payload["relayEncryption"] = it }
        realtimeRelayURL?.takeIf { it.isNotBlank() }?.let { payload["realtimeRelayURL"] = it }
        realtimeRelayStatus?.takeIf { it.isNotBlank() }?.let { payload["realtimeRelayStatus"] = it }
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        return callMap("completePiAgentPairing", payload)
    }

    suspend fun listPiAgentConnections(includeRevoked: Boolean = false): List<Map<String, Any>> {
        val data = callMap("listPiAgentConnections", mapOf("includeRevoked" to includeRevoked))
        @Suppress("UNCHECKED_CAST")
        return data["connections"] as? List<Map<String, Any>> ?: emptyList()
    }

    suspend fun revokePiAgentConnection(connectionId: String, deviceId: String? = null) {
        val payload = mutableMapOf<String, Any>("connectionId" to connectionId)
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        functions.getHttpsCallable("revokePiAgentConnection").call(payload).await()
    }

    suspend fun revokeRemoteMcpClient(clientId: String) {
        functions.getHttpsCallable("revokeRemoteMcpClient")
            .call(mapOf("clientId" to clientId))
            .await()
    }

    suspend fun updatePiAgentConnectionStatus(
        connectionId: String,
        status: PiConnectionStatus,
        advertisedModel: String? = null,
        selectedInstanceId: String? = null,
        capabilities: List<String>? = null,
        instances: List<Map<String, Any>>? = null,
        models: List<Map<String, Any>>? = null,
        deviceId: String? = null
    ) {
        val payload = mutableMapOf<String, Any>(
            "connectionId" to connectionId,
            "status" to status.token
        )
        advertisedModel?.takeIf { it.isNotBlank() }?.let { payload["advertisedModel"] = it }
        selectedInstanceId?.takeIf { it.isNotBlank() }?.let { payload["selectedInstanceID"] = it }
        capabilities?.let { payload["capabilities"] = it }
        instances?.let { payload["instances"] = it }
        models?.let { payload["models"] = it }
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        functions.getHttpsCallable("updatePiAgentConnectionStatus").call(payload).await()
    }

    suspend fun adoptProviderAccountForDevice(
        accountId: String,
        deviceId: String,
        deviceDisplayName: String? = null,
        capability: DeviceLinkCapability = DeviceLinkCapability.USE
    ): Map<String, Any> {
        val payload = mutableMapOf<String, Any>(
            "accountID" to accountId,
            "deviceID" to deviceId,
            "capability" to capability.token
        )
        deviceDisplayName?.takeIf { it.isNotBlank() }?.let { payload["deviceDisplayName"] = it }
        return callMap("adoptProviderAccountForDevice", payload)
    }

    suspend fun revokeProviderAccountDeviceLink(accountId: String, deviceId: String) {
        functions.getHttpsCallable("revokeProviderAccountDeviceLink")
            .call(mapOf("accountID" to accountId, "deviceID" to deviceId))
            .await()
    }

    suspend fun backfillProviderAccountDeviceLinks(
        callerDeviceId: String? = null,
        callerDeviceDisplayName: String? = null
    ) {
        val payload = mutableMapOf<String, Any>()
        callerDeviceId?.takeIf { it.isNotBlank() }?.let { payload["callerDeviceID"] = it }
        callerDeviceDisplayName?.takeIf { it.isNotBlank() }?.let { payload["callerDeviceDisplayName"] = it }
        functions.getHttpsCallable("backfillProviderAccountDeviceLinks").call(payload).await()
    }

    private suspend fun callMap(name: String, payload: Map<String, Any>): Map<String, Any> {
        val result = functions.getHttpsCallable(name).call(payload).await()
        @Suppress("UNCHECKED_CAST")
        return result.getData() as? Map<String, Any> ?: emptyMap()
    }
}

private fun Map<String, Any>.toCloudConversationSearchHit(): CloudConversationSearchHit? {
    val sealedTitle = (this["sealedTitle"] as? Map<*, *>)?.toSealedText() ?: return null
    val sealedSnippet = (this["sealedSnippet"] as? Map<*, *>)?.toSealedText() ?: return null
    return CloudConversationSearchHit(
        id = this["id"] as? String ?: return null,
        chunkID = this["chunkID"] as? String ?: "",
        documentID = this["documentID"] as? String ?: return null,
        sourceKind = this["sourceKind"] as? String ?: "conversation",
        sourceID = this["sourceID"] as? String ?: "",
        provider = this["provider"] as? String,
        projectName = this["projectName"] as? String,
        sealedTitle = sealedTitle,
        sealedSnippet = sealedSnippet,
        sealedBodyPreview = (this["sealedBodyPreview"] as? Map<*, *>)?.toSealedText(),
        storagePath = this["storagePath"] as? String ?: return null,
        bodyHash = this["bodyHash"] as? String ?: return null,
        score = (this["score"] as? Number)?.toDouble() ?: 0.0,
        tokenScore = (this["tokenScore"] as? Number)?.toDouble(),
        semanticScore = (this["semanticScore"] as? Number)?.toDouble(),
        matchKind = this["matchKind"] as? String,
        tokenHashVersion = (this["tokenHashVersion"] as? Number)?.toInt(),
        semanticHashVersion = (this["semanticHashVersion"] as? Number)?.toInt(),
        indexVersion = (this["indexVersion"] as? Number)?.toInt()
    )
}

private fun Map<*, *>.toSealedText(): CloudVaultSealedText? {
    val algorithm = this["algorithm"] as? String ?: return null
    val keyVersion = (this["keyVersion"] as? Number)?.toInt() ?: return null
    val nonce = this["nonce"] as? String ?: return null
    val ciphertext = this["ciphertext"] as? String ?: return null
    val tag = this["tag"] as? String ?: return null
    return CloudVaultSealedText(
        algorithm = algorithm,
        keyVersion = keyVersion,
        nonce = nonce,
        ciphertext = ciphertext,
        tag = tag
    )
}
