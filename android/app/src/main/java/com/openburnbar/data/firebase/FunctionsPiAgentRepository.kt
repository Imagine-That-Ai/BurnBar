package com.openburnbar.data.firebase

import com.google.firebase.functions.FirebaseFunctions
import com.openburnbar.data.hermes.PiConnectionMode
import com.openburnbar.data.hermes.PiConnectionStatus
import kotlinx.coroutines.tasks.await

internal class FunctionsPiAgentRepository(
    private val functions: FirebaseFunctions,
    private val callMap: suspend (String, Map<String, Any>) -> Map<String, Any>,
) {
    suspend fun createPiAgentPairing(deviceId: String? = null, platform: String? = null, displayName: String? = null): Map<String, Any> {
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
        deviceId: String? = null,
    ): Map<String, Any> {
        val payload =
            mutableMapOf<String, Any>(
                "pairingId" to pairingId,
                "code" to code,
                "displayName" to displayName,
                "mode" to mode.token,
                "endpointURL" to endpointURL,
                "capabilities" to capabilities,
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
        return data["connections"].asStringAnyMapList() ?: emptyList()
    }

    suspend fun revokePiAgentConnection(connectionId: String, deviceId: String? = null) {
        val payload = mutableMapOf<String, Any>("connectionId" to connectionId)
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        functions.getHttpsCallable("revokePiAgentConnection").call(payload).await()
    }

    suspend fun updatePiAgentConnectionStatus(
        connectionId: String,
        status: PiConnectionStatus,
        advertisedModel: String? = null,
        selectedInstanceId: String? = null,
        capabilities: List<String>? = null,
        instances: List<Map<String, Any>>? = null,
        models: List<Map<String, Any>>? = null,
        deviceId: String? = null,
    ) {
        val payload =
            mutableMapOf<String, Any>(
                "connectionId" to connectionId,
                "status" to status.token,
            )
        advertisedModel?.takeIf { it.isNotBlank() }?.let { payload["advertisedModel"] = it }
        selectedInstanceId?.takeIf { it.isNotBlank() }?.let { payload["selectedInstanceID"] = it }
        capabilities?.let { payload["capabilities"] = it }
        instances?.let { payload["instances"] = it }
        models?.let { payload["models"] = it }
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        functions.getHttpsCallable("updatePiAgentConnectionStatus").call(payload).await()
    }
}
