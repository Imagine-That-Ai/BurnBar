package com.openburnbar.data.firebase

import com.google.firebase.firestore.*
import com.google.firebase.Timestamp
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.insights.InsightDigest
import com.openburnbar.data.models.*
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Date

class FirestoreRepository {
    private val db = Firebase.firestore
    private val functions = Firebase.functions

    /** Returns the currently-authenticated user's document ID for subcollection paths.
     *  Falls back to the auth uid, then to a mock so the client ships without crashing. */
    fun currentUserId(): String {
        return com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid ?: "mock-user"
    }

    // ── Convenience collection refs ──
    private val usageCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("usage")

    private val rollupsCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("usage_rollups")

    private val rollupWindowKeys = listOf("today", "7d", "30d", "90d", "all_time")

    private val quotaCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("quota_snapshots")

    private val providerAccountsCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("provider_accounts")

    private val projectsCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("projects")

    private val modelBenchmarkSnapshotsCollection: CollectionReference
        get() = db.collection("model_benchmark_snapshots")

    // ── Rollups ──
    suspend fun fetchRollups(): UsageRollups {
        // Cloud Functions write one document per window key:
        //   users/{uid}/usage_rollups/today, /7d, /30d, /90d, /all_time
        // Each is a full UsageRollupDoc for that window.
        // Read all 5 and merge the window-value fields into a flat client model.
        val windowDocs = rollupWindowKeys.associateWith { key ->
            rollupsCollection.document(key).get().await()
        }
        return mergeWindowDocs(windowDocs)
    }

    suspend fun fetchModelBenchmarkSnapshots(limit: Long = 160): List<InsightDigest.ModelBenchmarkSummary> {
        val snapshot = modelBenchmarkSnapshotsCollection
            .orderBy("updatedAt", Query.Direction.DESCENDING)
            .limit(limit)
            .get()
            .await()
        return snapshot.documents.mapNotNull { doc -> doc.toModelBenchmarkSummary() }
    }

    fun listenToRollups(): Flow<UsageRollups> = callbackFlow {
        val listeners = mutableListOf<ListenerRegistration>()
        val cache = mutableMapOf<String, DocumentSnapshot?>()
        val lock = Any()

        fun emitMerged() {
            val merged = mergeWindowDocs(cache)
            trySend(merged)
        }

        for (key in rollupWindowKeys) {
            val listener = rollupsCollection.document(key)
                .addSnapshotListener { snapshot, error ->
                    if (error != null) { close(error); return@addSnapshotListener }
                    synchronized(lock) {
                        cache[key] = snapshot
                    }
                    emitMerged()
                }
            listeners.add(listener)
        }
        awaitClose { listeners.forEach { it.remove() } }
    }

        /** Merge per-window UsageRollupDoc documents into the flat client model. */
    private fun mergeWindowDocs(docs: Map<String, DocumentSnapshot?>): UsageRollups {
        val allDocs = docs.mapNotNull { (key, snap) ->
            snap?.toRollups()?.let { key to it }
        }.toMap()
        if (allDocs.isEmpty()) return UsageRollups()

        // Pick the all_time doc for summaries, dailyPoints, etc.
        val allTimeDoc = allDocs["all_time"] ?: allDocs.values.first()
        fun UsageRollups.costUsd(): Double = totals["costUsd"] ?: 0.0
        fun UsageRollups.tokens(): Long = listOfNotNull(
            totals["tokens"],
            today.takeIf { it > 0 },
            sevenDays.takeIf { it > 0 },
            thirtyDays.takeIf { it > 0 },
            ninetyDays.takeIf { it > 0 },
            allTime.takeIf { it > 0 }
        ).firstOrNull()?.toLong() ?: 0L
        fun UsageRollups.requests(): Int = (totals["requests"] ?: 0.0).toInt()

        // Cloud Functions store the window-key fields as token totals. Cost
        // lives under totals.costUsd, so keep currency and token views separate.
        return UsageRollups(
            today = allDocs["today"]?.costUsd() ?: allTimeDoc.costUsd(),
            sevenDays = allDocs["7d"]?.costUsd() ?: allTimeDoc.costUsd(),
            thirtyDays = allDocs["30d"]?.costUsd() ?: allTimeDoc.costUsd(),
            ninetyDays = allDocs["90d"]?.costUsd() ?: allTimeDoc.costUsd(),
            allTime = allTimeDoc.costUsd(),
            todayTokens = allDocs["today"]?.tokens() ?: allTimeDoc.tokens(),
            sevenDayTokens = allDocs["7d"]?.tokens() ?: allTimeDoc.tokens(),
            thirtyDayTokens = allDocs["30d"]?.tokens() ?: allTimeDoc.tokens(),
            ninetyDayTokens = allDocs["90d"]?.tokens() ?: allTimeDoc.tokens(),
            allTimeTokens = allTimeDoc.tokens(),
            todayRequests = allDocs["today"]?.requests() ?: allTimeDoc.requests(),
            sevenDayRequests = allDocs["7d"]?.requests() ?: allTimeDoc.requests(),
            thirtyDayRequests = allDocs["30d"]?.requests() ?: allTimeDoc.requests(),
            ninetyDayRequests = allDocs["90d"]?.requests() ?: allTimeDoc.requests(),
            allTimeRequests = allTimeDoc.requests(),
            totals = allTimeDoc.totals,
            providerSummaries = allTimeDoc.providerSummaries,
            accountSummaries = allTimeDoc.accountSummaries,
            modelSummaries = allTimeDoc.modelSummaries,
            deviceSummaries = allTimeDoc.deviceSummaries,
            dailyPoints = allTimeDoc.dailyPoints,
            computedAt = allTimeDoc.computedAt,
            schemaVersion = allTimeDoc.schemaVersion
        )
    }

    suspend fun rebuildUsageRollups() {
        functions.getHttpsCallable("rebuildUsageRollups").call().await()
    }

    // ── Usage: users/<uid>/usage (paginated) ──
    suspend fun fetchUsagePage(
        pageSize: Int = 25,
        after: DocumentSnapshot? = null,
        provider: String? = null,
        model: String? = null,
        device: String? = null,
        startDate: Long? = null,
        endDate: Long? = null
    ): Pair<List<TokenUsage>, DocumentSnapshot?> {
        var query: Query = usageCollection
            .orderBy("startTime", Query.Direction.DESCENDING)

        provider?.let { query = query.whereEqualTo("provider", it) }
        model?.let { query = query.whereEqualTo("model", it) }
        device?.let { query = query.whereEqualTo("deviceId", it) }
        startDate?.let { query = query.whereGreaterThanOrEqualTo("startTime", Timestamp(Date(it))) }
        endDate?.let { query = query.whereLessThanOrEqualTo("startTime", Timestamp(Date(it))) }
        after?.let { query = query.startAfter(it) }

        val snapshot = query.limit(pageSize.toLong()).get().await()
        val list = snapshot.documents.mapNotNull { it.toTokenUsage() }
        val lastDoc = if (snapshot.size() < pageSize) null else snapshot.documents.lastOrNull()
        return list to lastDoc
    }

    fun listenToUsagePage(
        pageSize: Int = 25
    ): Flow<List<TokenUsage>> = callbackFlow {
        val listener = usageCollection
            .orderBy("startTime", Query.Direction.DESCENDING)
            .limit(pageSize.toLong())
            .addSnapshotListener { snapshot, error ->
                if (error != null) { close(error); return@addSnapshotListener }
                trySend(snapshot?.documents?.mapNotNull { it.toTokenUsage() } ?: emptyList())
            }
        awaitClose { listener.remove() }
    }

    // ── Quota Snapshots ──
    suspend fun fetchQuotaSnapshots(): List<ProviderQuotaSnapshot> {
        val snapshot = quotaCollection.get().await()
        return snapshot.documents
            .mapNotNull { it.toQuotaSnapshot() }
            .deduplicatedByProviderAccount()
    }

    fun listenToQuotaSnapshots(): Flow<List<ProviderQuotaSnapshot>> = callbackFlow {
        val listener = quotaCollection
            .addSnapshotListener { snapshot, error ->
                if (error != null) { close(error); return@addSnapshotListener }
                trySend(
                    snapshot?.documents
                        ?.mapNotNull { it.toQuotaSnapshot() }
                        ?.deduplicatedByProviderAccount()
                        ?: emptyList()
                )
            }
        awaitClose { listener.remove() }
    }

    // ── Provider Accounts ──
    suspend fun fetchProviderAccounts(): List<ProviderAccount> {
        val snapshot = providerAccountsCollection.get().await()
        return snapshot.documents.mapNotNull { it.toProviderAccount() }
    }

    // ── Provider Account Device Links ──
    //
    // Plan 2 — streams `users/{uid}/provider_account_device_links` so the
    // Android Providers screen can render a "On N devices" chip per account
    // in real time. Reads are owner-scoped; writes funnel through the
    // adoptProviderAccountForDevice / revokeProviderAccountDeviceLink
    // callables.

    private val providerAccountDeviceLinksCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("provider_account_device_links")

    fun listenProviderAccountDeviceLinks(): Flow<List<ProviderAccountDeviceLink>> = callbackFlow {
        val listener = providerAccountDeviceLinksCollection
            .addSnapshotListener { snapshot, error ->
                if (error != null) { close(error); return@addSnapshotListener }
                val docs = snapshot?.documents ?: emptyList()
                val projections = docs.mapNotNull { it.toProviderAccountDeviceLink() }
                trySend(projections)
            }
        awaitClose { listener.remove() }
    }

    // ── Projects ──
    suspend fun fetchProjects(): List<ProjectSummary> {
        val snapshot = projectsCollection
            .orderBy("total_cost", Query.Direction.DESCENDING)
            .limit(20)
            .get().await()
        return snapshot.documents.mapNotNull { it.toProjectSummary() }
    }
}

object FirestoreValueParsers {
    fun millis(raw: Any?): Long {
        return when (raw) {
            is Timestamp -> raw.seconds * 1000 + raw.nanoseconds / 1_000_000
            is Number -> raw.toLong()
            is Date -> raw.time
            is String -> parseIsoMillis(raw)
            else -> 0L
        }
    }

    fun string(data: Map<String, Any>, vararg keys: String): String? {
        for (key in keys) {
            val value = data[key] as? String
            if (!value.isNullOrBlank()) return value
        }
        return null
    }

    private fun parseIsoMillis(raw: String): Long {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return 0L
        return try {
            Instant.parse(trimmed).toEpochMilli()
        } catch (_: DateTimeParseException) {
            0L
        }
    }
}

private fun DocumentSnapshot.toModelBenchmarkSummary(): InsightDigest.ModelBenchmarkSummary? {
    val data = data ?: return null
    fun string(vararg keys: String): String? = FirestoreValueParsers.string(data, *keys)
    fun number(vararg keys: String): Double? {
        for (key in keys) {
            val raw = data[key]
            if (raw is Number) return raw.toDouble()
        }
        return null
    }
    fun int(vararg keys: String): Int? = number(*keys)?.toInt()
    val modelID = string("modelID", "modelId", "model") ?: return null
    val taskCategory = string("taskCategory", "task_category") ?: "unknown"
    return InsightDigest.ModelBenchmarkSummary(
        id = string("id") ?: id,
        source = string("source") ?: "unknown",
        sourceURL = string("sourceURL", "sourceUrl"),
        attribution = string("attribution"),
        fetchedAt = string("fetchedAt") ?: string("updatedAt") ?: "",
        modelID = modelID,
        providerID = string("providerID", "providerId"),
        taskCategory = taskCategory,
        score = number("score"),
        rank = int("rank"),
        costSignal = number("costSignal"),
        latencySignal = number("latencySignal"),
        contextWindowTokens = int("contextWindowTokens"),
        reliabilitySignal = number("reliabilitySignal"),
        confidence = number("confidence"),
        freshness = string("freshness") ?: "fresh",
        inputCostPerMtoken = number("inputCostPerMtoken"),
        outputCostPerMtoken = number("outputCostPerMtoken"),
        blendedCostPerMtoken = number("blendedCostPerMtoken")
    )
}

// ── Rollup data classes (flat shape matching UsageRollupDoc) ──

// ── Document parsers ──

private fun DocumentSnapshot.toRollups(): UsageRollups? {
    val data = data ?: return null
    return UsageRollups(
        today = (data["today"] as? Number)?.toDouble() ?: 0.0,
        sevenDays = (data["7d"] as? Number)?.toDouble() ?: 0.0,
        thirtyDays = (data["30d"] as? Number)?.toDouble() ?: 0.0,
        ninetyDays = (data["90d"] as? Number)?.toDouble() ?: 0.0,
        allTime = (data["all_time"] as? Number)?.toDouble() ?: 0.0,
        totals = (data["totals"] as? Map<String, Any>)?.mapValues { (it.value as? Number)?.toDouble() ?: 0.0 } ?: emptyMap(),
        providerSummaries = (data["providerSummaries"] as? List<*>)?.mapNotNull { (it as? Map<String, Any>)?.toRollupSummary() } ?: emptyList(),
        accountSummaries = (data["accountSummaries"] as? List<*>)?.mapNotNull { (it as? Map<String, Any>)?.toRollupSummary() } ?: emptyList(),
        modelSummaries = (data["modelSummaries"] as? List<*>)?.mapNotNull { (it as? Map<String, Any>)?.toRollupSummary() } ?: emptyList(),
        deviceSummaries = (data["deviceSummaries"] as? List<*>)?.mapNotNull { (it as? Map<String, Any>)?.toRollupSummary() } ?: emptyList(),
        dailyPoints = (data["dailyPoints"] as? Map<String, Any>)?.mapValues { (it.value as? Number)?.toDouble() ?: 0.0 } ?: emptyMap(),
        computedAt = data["computedAt"] as? String,
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 0
    )
}

private fun Map<String, Any>.toRollupSummary(): RollupSummary = RollupSummary(
    provider = (this["provider"] as? String) ?: (this["model"] as? String) ?: (this["deviceId"] as? String) ?: "",
    providerId = this["providerID"] as? String,
    accountId = this["accountID"] as? String,
    accountLabel = this["accountLabel"] as? String ?: "",
    storageScope = this["storageScope"] as? String,
    totalRequests = (this["totalRequests"] as? Number)?.toInt() ?: (this["requests"] as? Number)?.toInt() ?: 0,
    totalTokens = (this["totalTokens"] as? Number)?.toLong() ?: (this["tokens"] as? Number)?.toLong() ?: 0L,
    totalCost = (this["totalCost"] as? Number)?.toDouble() ?: (this["cost"] as? Number)?.toDouble() ?: 0.0
)

private fun DocumentSnapshot.toTokenUsage(): TokenUsage? {
    val data = data ?: return null
    val startMillis = FirestoreValueParsers.millis(data["startTime"])
    val endMillis = FirestoreValueParsers.millis(data["endTime"])
    val createdMillis = FirestoreValueParsers.millis(data["createdAt"])
    val updatedMillis = FirestoreValueParsers.millis(data["updatedAt"])
    val timestampMillis = FirestoreValueParsers.millis(data["timestamp"]).takeIf { it > 0L }
        ?: startMillis.takeIf { it > 0L }
        ?: updatedMillis
    return TokenUsage(
        id = id,
        provider = data["provider"] as? String ?: "",
        providerId = data["providerID"] as? String,
        providerAccountId = data["providerAccountID"] as? String,
        providerAccountLabel = data["providerAccountLabel"] as? String,
        providerAccountSource = data["providerAccountSource"] as? String,
        model = data["model"] as? String,
        sessionId = data["sessionId"] as? String,
        deviceId = data["deviceId"] as? String,
        sourceDeviceId = data["sourceDeviceId"] as? String,
        inputTokens = (data["inputTokens"] as? Number)?.toInt() ?: 0,
        outputTokens = (data["outputTokens"] as? Number)?.toInt() ?: 0,
        cacheCreationTokens = (data["cacheCreationTokens"] as? Number)?.toInt() ?: 0,
        cacheReadTokens = (data["cacheReadTokens"] as? Number)?.toInt() ?: 0,
        reasoningTokens = (data["reasoningTokens"] as? Number)?.toInt() ?: 0,
        totalTokens = (data["totalTokens"] as? Number)?.toInt() ?: 0,
        costUsd = (data["costUsd"] as? Number)?.toDouble() ?: 0.0,
        cost = (data["cost"] as? Number)?.toDouble() ?: 0.0,
        provenanceConfidence = data["provenanceConfidence"] as? String,
        provenanceMethod = data["provenanceMethod"] as? String,
        userDisplayId = data["user_display_id"] as? String,
        projectName = FirestoreValueParsers.string(data, "projectName", "project_name"),
        timestamp = timestampMillis,
        startTime = startMillis,
        endTime = endMillis,
        createdAt = createdMillis,
        updatedAt = updatedMillis,
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 0
    )
}

private fun DocumentSnapshot.toQuotaSnapshot(): ProviderQuotaSnapshot? {
    val data = data ?: return null
    val buckets = (data["buckets"] as? List<*>)?.mapNotNull { raw ->
        (raw as? Map<String, Any>)?.let {
            QuotaBucket(
                name = it["name"] as? String ?: "",
                used = (it["used"] as? Number)?.toDouble() ?: 0.0,
                limit = (it["limit"] as? Number)?.toDouble() ?: 0.0,
                remaining = (it["remaining"] as? Number)?.toDouble() ?: 0.0,
                window = it["window"] as? String,
                meta = it["meta"] as? Map<String, Any?>
            )
        }
    } ?: emptyList()

    return ProviderQuotaSnapshot(
        id = id,
        sourceKind = data["sourceKind"] as? String ?: "provider",
        sourceId = data["sourceId"] as? String ?: "",
        provider = data["provider"] as? String ?: "",
        providerId = data["providerID"] as? String,
        accountId = data["accountID"] as? String,
        accountLabel = data["accountLabel"] as? String,
        accountStorageScope = data["accountStorageScope"] as? String,
        fetchedAt = data["fetchedAt"] as? String,
        source = data["source"] as? String,
        confidence = data["confidence"] as? String ?: "low",
        managementUrl = data["managementURL"] as? String,
        statusMessage = data["statusMessage"] as? String,
        buckets = buckets,
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 0,
        updatedAt = data["updatedAt"] as? String
    )
}

private fun DocumentSnapshot.toProviderAccount(): ProviderAccount? {
    val data = data ?: return null
    return ProviderAccount(
        id = id,
        providerId = data["providerID"] as? String ?: data["provider"] as? String ?: "",
        label = data["label"] as? String ?: "",
        identityHint = data["identityHint"] as? String,
        status = data["status"] as? String,
        credentialKind = data["credentialKind"] as? String,
        storageScope = data["storageScope"] as? String,
        redactedLabel = data["redactedLabel"] as? String,
        sourceDeviceId = data["sourceDeviceID"] as? String,
        linkedSwitcherProfileId = data["linkedSwitcherProfileID"] as? String,
        isDefault = data["isDefault"] as? Boolean ?: false,
        sortKey = (data["sortKey"] as? Number)?.toDouble() ?: 0.0,
        lastValidatedAt = data["lastValidatedAt"] as? String,
        lastRefreshAt = data["lastRefreshAt"] as? String,
        lastErrorCode = data["lastErrorCode"] as? String,
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 0,
        createdAt = data["createdAt"] as? String,
        updatedAt = data["updatedAt"] as? String,
        usageLimit = (data["usage_limit"] as? Number)?.toLong() ?: 0L,
        usageUsed = (data["usage_used"] as? Number)?.toLong() ?: 0L,
        integration = data["integration"] as? String,
        latitude = (data["latitude"] as? Number)?.toDouble(),
        organizationId = data["organization_id"] as? String
    )
}

private fun DocumentSnapshot.toProviderAccountDeviceLink(): ProviderAccountDeviceLink? {
    val data = data ?: return null
    val accountID = data["accountID"] as? String ?: return null
    val deviceID = data["deviceID"] as? String ?: return null
    return ProviderAccountDeviceLink(
        id = id,
        accountId = accountID,
        deviceId = deviceID,
        deviceDisplayName = data["deviceDisplayName"] as? String ?: deviceID,
        capability = data["capability"] as? String ?: DeviceLinkCapability.USE.token,
        status = data["status"] as? String ?: DeviceLinkStatus.ACTIVE.token,
        lastObservedAtMillis = FirestoreValueParsers.millis(data["lastObservedAt"]),
        createdAtMillis = FirestoreValueParsers.millis(data["createdAt"]),
        updatedAtMillis = FirestoreValueParsers.millis(data["updatedAt"]),
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 1
    )
}

private fun DocumentSnapshot.toProjectSummary(): ProjectSummary? {
    val data = data ?: return null
    return ProjectSummary(
        id = id,
        name = data["name"] as? String ?: "",
        totalCost = (data["total_cost"] as? Number)?.toDouble() ?: 0.0,
        totalTokens = (data["total_tokens"] as? Number)?.toLong() ?: 0L,
        totalSessions = (data["total_sessions"] as? Number)?.toInt() ?: 0
    )
}
