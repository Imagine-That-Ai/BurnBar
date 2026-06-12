package com.openburnbar.data.firebase

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.BuildConfig
import com.openburnbar.data.cloud.CloudVaultSealedText
import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.models.DeviceLinkCapability
import kotlinx.coroutines.tasks.await

private const val MAX_SEARCH_TOKEN_HASHES = 10
private const val MAX_SEARCH_SEMANTIC_HASHES = 12
private const val MAX_SEARCH_RESULT_LIMIT = 50

data class CloudConversationSearchHit(
    val id: String,
    val chunkID: String,
    val documentID: String,
    val sourceKind: String,
    val sourceID: String,
    val provider: String?,
    val sealedTitle: CloudVaultSealedText,
    val sealedSnippet: CloudVaultSealedText,
    val sealedBodyPreview: CloudVaultSealedText?,
    val storagePath: String,
    val bodyHash: String,
    val bodyHashVersion: Int? = null,
    val score: Double,
    val tokenScore: Double? = null,
    val semanticScore: Double? = null,
    val matchKind: String? = null,
    val tokenHashVersion: Int? = null,
    val semanticHashVersion: Int? = null,
    val indexVersion: Int? = null,
)

/**
 * One encrypted session-log manifest row returned by the `queryConversations` callable. Facets are
 * operational cockpit metadata (provider/model/token & cost totals/timing/device/source); text-like
 * project/path/title/body fields stay sealed or hash-only. Numeric facets are nullable so manifests
 * written before the facet backfill still decode.
 */
data class ConversationFacetRow(
    val id: String,
    val provider: String?,
    val projectName: String?,
    val sourceType: String?,
    val deviceId: String?,
    val model: String?,
    val messageCount: Int?,
    val inputTokens: Int?,
    val outputTokens: Int?,
    val totalTokens: Int?,
    val costUSD: Double?,
    val workingDirectory: String?,
    val toolTags: List<String>,
    val durationSeconds: Int?,
    val sealedTitle: CloudVaultSealedText?,
    val sealedBodyPreview: CloudVaultSealedText?,
    val storagePath: String?,
    val bodyHash: String?,
    val bodyHashVersion: Int?,
    val startTimeMs: Long?,
    val endTimeMs: Long?,
    val updatedAtMs: Long?,
)

/** Filtered-set aggregates (count + cost + token sums) for the cockpit KPI header; `null` when the
 *  matching Firestore aggregate index is still building. */
data class ConversationQueryAggregates(
    val count: Int,
    val totalCostUSD: Double,
    val totalTokens: Long,
)

/** Decoded `queryConversations` response: a page of facet rows, an opaque pagination cursor
 *  (`null` when exhausted), the effective server-applied sort, and the optional aggregates. */
data class ConversationQueryResponse(
    val rows: List<ConversationFacetRow>,
    val nextCursor: String?,
    val sort: String?,
    val direction: String?,
    val aggregates: ConversationQueryAggregates?,
)

internal val DEFAULT_HERMES_GATEWAY_SCOPES =
    listOf(
        "hermes.gateway.read",
        "hermes.gateway.write",
        "hermes.gateway.manage",
    )

class FunctionsRepository {
    private val functions: FirebaseFunctions = Firebase.functions
    internal val piAgent: FunctionsPiAgentRepository by lazy { FunctionsPiAgentRepository(functions, ::callMap) }

    suspend fun searchStreams(query: String, limit: Int = 20): List<Map<String, Any>> {
        val result =
            functions.getHttpsCallable("searchStreams")
                .call(mapOf("query" to query, "limit" to limit))
                .await()
        val data = result.getData() as? Map<*, *> ?: return emptyList()
        return data["hits"].asStringAnyMapList()
            ?: data["results"].asStringAnyMapList()
            ?: emptyList()
    }

    suspend fun searchEncryptedConversationIndex(
        tokenHashes: List<String>,
        semanticHashes: List<String> = emptyList(),
        limit: Int = 25,
    ): List<CloudConversationSearchHit> {
        val data =
            callMap(
                "searchEncryptedConversationIndex",
                mapOf(
                    "tokenHashes" to tokenHashes.take(MAX_SEARCH_TOKEN_HASHES),
                    "semanticHashes" to semanticHashes.take(MAX_SEARCH_SEMANTIC_HASHES),
                    "limit" to limit.coerceIn(1, MAX_SEARCH_RESULT_LIMIT),
                ),
            )
        val hits = data["hits"].asStringAnyMapList() ?: return emptyList()
        return hits.mapNotNull { it.toCloudConversationSearchHit() }
    }

    /**
     * Faceted, paginated query over the signed-in paid user's encrypted session-log manifests.
     * Filtering and sorting run server-side only on operational facets. Project/path/title/body
     * search must use encrypted search hashes and local decryption. `providers` and `models` may be
     * multi-valued, but the server rejects filtering by multiple of *both* at once (one Firestore
     * `in` clause per query). A date window forces a `startTime` sort server-side.
     */
    suspend fun queryConversations(
        providers: List<String> = emptyList(),
        models: List<String> = emptyList(),
        deviceId: String? = null,
        sourceType: String? = null,
        dateFromIso: String? = null,
        dateToIso: String? = null,
        sort: String = "updatedAt",
        direction: String = "desc",
        limit: Int = 30,
        cursorDocId: String? = null,
        includeAggregates: Boolean = true,
    ): ConversationQueryResponse {
        val payload =
            mutableMapOf<String, Any>(
                "sort" to sort,
                "direction" to direction,
                "limit" to limit.coerceIn(1, 100),
                "includeAggregates" to includeAggregates,
            )
        if (providers.isNotEmpty()) payload["providers"] = providers
        if (models.isNotEmpty()) payload["models"] = models
        deviceId?.takeIf { it.isNotBlank() }?.let { payload["deviceId"] = it }
        sourceType?.takeIf { it.isNotBlank() }?.let { payload["sourceType"] = it }
        dateFromIso?.takeIf { it.isNotBlank() }?.let { payload["dateFrom"] = it }
        dateToIso?.takeIf { it.isNotBlank() }?.let { payload["dateTo"] = it }
        cursorDocId?.takeIf { it.isNotBlank() }?.let { payload["cursorDocId"] = it }

        val data = callMap("queryConversations", payload)
        val rows =
            data["rows"].asStringAnyMapList()
                ?.mapNotNull { it.toConversationFacetRow() }
                ?: emptyList()
        val aggregates =
            (data["aggregates"] as? Map<*, *>)?.let { agg ->
                ConversationQueryAggregates(
                    count = (agg["count"] as? Number)?.toInt() ?: 0,
                    totalCostUSD = (agg["totalCostUSD"] as? Number)?.toDouble() ?: 0.0,
                    totalTokens = (agg["totalTokens"] as? Number)?.toLong() ?: 0L,
                )
            }
        return ConversationQueryResponse(
            rows = rows,
            nextCursor = data["nextCursor"] as? String,
            sort = data["sort"] as? String,
            direction = data["direction"] as? String,
            aggregates = aggregates,
        )
    }

    suspend fun encryptedSessionBlobDownloadURL(storagePath: String): String {
        val data =
            callMap(
                "getEncryptedSessionBlobDownloadUrl",
                mapOf("storagePath" to storagePath),
            )
        return data["downloadURL"] as? String
            ?: error("Encrypted session download URL missing.")
    }

    suspend fun verifyGooglePlayBurnBarProSubscription(purchaseToken: String, productID: String = "com.openburnbar.pro.monthly"): Map<String, Any> = callMap(
        "verifyGooglePlayBurnBarProSubscription",
        mapOf("purchaseToken" to purchaseToken, "productID" to productID),
    )

    suspend fun verifyGooglePlayCloudProTopUp(purchaseToken: String, productID: String): Map<String, Any> = callMap(
        "verifyGooglePlayCloudProTopUp",
        mapOf("purchaseToken" to purchaseToken, "productID" to productID),
    )

    suspend fun rebuildUsageRollups() {
        functions.getHttpsCallable("rebuildUsageRollups").call().await()
    }

    suspend fun seedAndroidDemoAccount(): Map<String, Any> {
        return callMap("seedAndroidDemoAccount", emptyMap())
    }

    suspend fun refreshQuota(accountId: String, providerId: String): Map<String, Any> {
        val result =
            functions.getHttpsCallable("refreshQuota")
                .call(mapOf("accountId" to accountId, "providerId" to providerId))
                .await()
        return result.getData().asStringAnyMap() ?: emptyMap()
    }

    suspend fun refreshProviderAccountQuota(accountId: String): Map<String, Any> {
        val result =
            functions.getHttpsCallable("refreshProviderAccountQuota")
                .call(mapOf("accountID" to accountId))
                .await()
        return result.getData().asStringAnyMap() ?: emptyMap()
    }

    suspend fun deleteProviderAccount(accountId: String) {
        functions.getHttpsCallable("deleteProviderAccount")
            .call(mapOf("accountId" to accountId))
            .await()
    }

    suspend fun addProviderConnection(providerId: String, credentials: Map<String, String>): Map<String, Any> {
        val result =
            functions.getHttpsCallable("addProviderConnection")
                .call(mapOf("providerId" to providerId, "credentials" to credentials))
                .await()
        return result.getData().asStringAnyMap() ?: emptyMap()
    }

    suspend fun connectProviderAccount(
        providerId: String,
        credential: String,
        credentialKind: String = "token",
        label: String? = null,
        endpointProfileId: String? = null,
        region: String? = null,
        tokenPlanTier: String? = null,
        tokenPlanBillingCycle: String? = null,
        authMethodId: String? = null,
    ): Map<String, Any> {
        val payload =
            mutableMapOf<String, Any>(
                "provider" to providerId,
                "credential" to credential,
                "credentialKind" to credentialKind,
            )
        label?.takeIf { it.isNotBlank() }?.let { payload["label"] = it }
        endpointProfileId?.takeIf { it.isNotBlank() }?.let { payload["endpointProfileID"] = it }
        region?.takeIf { it.isNotBlank() }?.let { payload["region"] = it }
        tokenPlanTier?.takeIf { it.isNotBlank() }?.let { payload["tokenPlanTier"] = it }
        tokenPlanBillingCycle?.takeIf { it.isNotBlank() }?.let { payload["tokenPlanBillingCycle"] = it }
        authMethodId?.takeIf { it.isNotBlank() }?.let { payload["authMethodID"] = it }
        return callMap("connectProviderAccount", payload)
    }

    suspend fun revokeRemoteMcpClient(clientId: String) {
        functions.getHttpsCallable("revokeRemoteMcpClient")
            .call(mapOf("clientId" to clientId))
            .await()
    }

    suspend fun approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String? = null,
        destinationId: String = "burnbar:home",
        scopes: List<String> = DEFAULT_HERMES_GATEWAY_SCOPES,
        phoneRelayPublicKey: String? = null,
        phoneRelayKeyVersion: Int? = null,
        phoneRelayEncryption: String? = null,
    ): Map<String, Any> =
        callMap(
            "approveHermesGatewayDeviceGrant",
            buildHermesGatewayDeviceGrantPayload(
                userCode = userCode,
                displayName = displayName,
                destinationId = destinationId,
                scopes = scopes,
                phoneRelayPublicKey = phoneRelayPublicKey,
                phoneRelayKeyVersion = phoneRelayKeyVersion,
                phoneRelayEncryption = phoneRelayEncryption,
                clientAppBuild = BuildConfig.VERSION_NAME.ifBlank { BuildConfig.VERSION_CODE.toString() },
            ),
        )

    suspend fun adoptProviderAccountForDevice(
        accountId: String,
        deviceId: String,
        deviceDisplayName: String? = null,
        capability: DeviceLinkCapability = DeviceLinkCapability.USE,
    ): Map<String, Any> {
        val payload =
            mutableMapOf<String, Any>(
                "accountID" to accountId,
                "deviceID" to deviceId,
                "capability" to capability.token,
            )
        deviceDisplayName?.takeIf { it.isNotBlank() }?.let { payload["deviceDisplayName"] = it }
        return callMap("adoptProviderAccountForDevice", payload)
    }

    suspend fun revokeProviderAccountDeviceLink(accountId: String, deviceId: String) {
        functions.getHttpsCallable("revokeProviderAccountDeviceLink")
            .call(mapOf("accountID" to accountId, "deviceID" to deviceId))
            .await()
    }

    suspend fun backfillProviderAccountDeviceLinks(callerDeviceId: String? = null, callerDeviceDisplayName: String? = null) {
        val payload = mutableMapOf<String, Any>()
        callerDeviceId?.takeIf { it.isNotBlank() }?.let { payload["callerDeviceID"] = it }
        callerDeviceDisplayName?.takeIf { it.isNotBlank() }?.let { payload["callerDeviceDisplayName"] = it }
        functions.getHttpsCallable("backfillProviderAccountDeviceLinks").call(payload).await()
    }

    private suspend fun callMap(name: String, payload: Map<String, Any>): Map<String, Any> {
        val result = functions.getHttpsCallable(name).call(payload).await()
        return result.getData().asStringAnyMap() ?: emptyMap()
    }
}

internal fun buildHermesGatewayDeviceGrantPayload(
    userCode: String,
    displayName: String? = null,
    destinationId: String = "burnbar:home",
    scopes: List<String> = DEFAULT_HERMES_GATEWAY_SCOPES,
    phoneRelayPublicKey: String? = null,
    phoneRelayKeyVersion: Int? = null,
    phoneRelayEncryption: String? = null,
    clientAppBuild: String = "unknown",
): Map<String, Any> {
    val payload =
        linkedMapOf<String, Any>(
            "userCode" to userCode,
            "destinationId" to destinationId,
            "scopes" to scopes,
        )
    displayName?.takeIf { it.isNotBlank() }?.let { payload["displayName"] = it }
    phoneRelayPublicKey?.takeIf { it.isNotBlank() }?.let {
        payload["phoneRelayPublicKey"] = it
        payload["supportsRelayEnvelopeVersions"] =
            listOf(HermesRelayCrypto.GATEWAY_KEY_VERSION, HermesRelayCrypto.KEY_VERSION_V3)
        payload["preferredRelayEnvelopeVersion"] = HermesRelayCrypto.KEY_VERSION_V3
        payload["supportsHpkeV3"] = true
        payload["clientPlatform"] = "android"
        payload["clientAppBuild"] = clientAppBuild.ifBlank { "unknown" }
    }
    phoneRelayKeyVersion?.let { payload["phoneRelayKeyVersion"] = it }
    phoneRelayEncryption?.takeIf { it.isNotBlank() }?.let { payload["phoneRelayEncryption"] = it }
    return payload
}

private fun Any?.asStringAnyMap(): Map<String, Any>? {
    val raw = this as? Map<*, *> ?: return null
    val typed = LinkedHashMap<String, Any>(raw.size)
    for ((key, value) in raw) {
        val stringKey = key as? String ?: return null
        if (value != null) typed[stringKey] = value
    }
    return typed
}

internal fun Any?.asStringAnyMapList(): List<Map<String, Any>>? {
    val raw = this as? List<*> ?: return null
    return raw.mapNotNull { it.asStringAnyMap() }
}

private fun Map<String, Any>.toCloudConversationSearchHit(): CloudConversationSearchHit? {
    val sealedTitle = (this["sealedTitle"] as? Map<*, *>)?.toSealedText()
    val sealedSnippet = (this["sealedSnippet"] as? Map<*, *>)?.toSealedText()
    val id = this["id"] as? String
    val documentID = this["documentID"] as? String
    val storagePath = this["storagePath"] as? String
    val bodyHash = this["bodyHash"] as? String
    val hasRequiredSearchFields =
        sealedTitle != null &&
            sealedSnippet != null &&
            id != null &&
            documentID != null &&
            storagePath != null &&
            bodyHash != null
    if (!hasRequiredSearchFields) {
        return null
    }
    return CloudConversationSearchHit(
        id = id,
        chunkID = this["chunkID"] as? String ?: "",
        documentID = documentID,
        sourceKind = this["sourceKind"] as? String ?: "conversation",
        sourceID = this["sourceID"] as? String ?: "",
        provider = this["provider"] as? String,
        sealedTitle = sealedTitle,
        sealedSnippet = sealedSnippet,
        sealedBodyPreview = (this["sealedBodyPreview"] as? Map<*, *>)?.toSealedText(),
        storagePath = storagePath,
        bodyHash = bodyHash,
        bodyHashVersion = (this["bodyHashVersion"] as? Number)?.toInt(),
        score = (this["score"] as? Number)?.toDouble() ?: 0.0,
        tokenScore = (this["tokenScore"] as? Number)?.toDouble(),
        semanticScore = (this["semanticScore"] as? Number)?.toDouble(),
        matchKind = this["matchKind"] as? String,
        tokenHashVersion = (this["tokenHashVersion"] as? Number)?.toInt(),
        semanticHashVersion = (this["semanticHashVersion"] as? Number)?.toInt(),
        indexVersion = (this["indexVersion"] as? Number)?.toInt(),
    )
}

private fun Map<String, Any>.toConversationFacetRow(): ConversationFacetRow? {
    val id = this["id"] as? String ?: return null
    return ConversationFacetRow(
        id = id,
        provider = this["provider"] as? String,
        projectName = null,
        sourceType = this["sourceType"] as? String,
        deviceId = this["deviceId"] as? String,
        model = this["model"] as? String,
        messageCount = (this["messageCount"] as? Number)?.toInt(),
        inputTokens = (this["inputTokens"] as? Number)?.toInt(),
        outputTokens = (this["outputTokens"] as? Number)?.toInt(),
        totalTokens = (this["totalTokens"] as? Number)?.toInt(),
        costUSD = (this["costUSD"] as? Number)?.toDouble(),
        workingDirectory = null,
        toolTags = (this["toolTags"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList(),
        durationSeconds = (this["durationSeconds"] as? Number)?.toInt(),
        sealedTitle = (this["sealedTitle"] as? Map<*, *>)?.toSealedText(),
        sealedBodyPreview = (this["sealedBodyPreview"] as? Map<*, *>)?.toSealedText(),
        storagePath = this["storagePath"] as? String,
        bodyHash = this["bodyHash"] as? String,
        bodyHashVersion = (this["bodyHashVersion"] as? Number)?.toInt(),
        startTimeMs = parseIsoTimestampMs(this["startTime"]),
        endTimeMs = parseIsoTimestampMs(this["endTime"]),
        updatedAtMs = parseIsoTimestampMs(this["updatedAt"]),
    )
}

private fun parseIsoTimestampMs(value: Any?): Long? {
    val raw = value as? String ?: return null
    return runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
}

private fun Map<*, *>.toSealedText(): CloudVaultSealedText? {
    val algorithm = this["algorithm"] as? String
    val keyVersion = (this["keyVersion"] as? Number)?.toInt()
    val nonce = this["nonce"] as? String
    val ciphertext = this["ciphertext"] as? String
    val tag = this["tag"] as? String
    val hasRequiredSealedTextFields =
        algorithm != null &&
            keyVersion != null &&
            nonce != null &&
            ciphertext != null &&
            tag != null
    if (!hasRequiredSealedTextFields) {
        return null
    }
    return CloudVaultSealedText(
        schemaVersion = (this["schemaVersion"] as? Number)?.toInt(),
        algorithm = algorithm,
        keyVersion = keyVersion,
        nonce = nonce,
        ciphertext = ciphertext,
        tag = tag,
        aad = this["aad"] as? String,
    )
}
