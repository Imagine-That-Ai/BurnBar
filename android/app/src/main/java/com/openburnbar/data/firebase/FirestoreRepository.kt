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
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.tasks.await
import java.time.Instant
import java.time.format.DateTimeParseException
import java.util.Date

data class QuotaSnapshotUpdate(
    val snapshots: List<ProviderQuotaSnapshot>,
    val isFromCache: Boolean
)

class FirestoreRepository {
    private val db = Firebase.firestore
    private val functions = Firebase.functions

    /** Returns the currently-authenticated user's document ID for
     *  subcollection paths. Throws `NotSignedInException` when there is no
     *  Firebase auth user — the previous "mock-user" fallback silently
     *  produced `users/mock-user/...` queries that always returned
     *  `PERMISSION_DENIED: Missing or insufficient permissions` from the
     *  Firestore security rules, surfacing as a confusing failure in the
     *  dashboard / activity / insights tabs whenever an auth race or token
     *  expiry left `FirebaseAuth.currentUser` momentarily null. */
    fun currentUserId(): String {
        val uid = com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
        return uid ?: throw NotSignedInException()
    }

    /** Thrown by [currentUserId] when no Firebase auth user exists. Stores
     *  catch this and surface "Sign in required" instead of the cryptic
     *  Firestore permission error. */
    class NotSignedInException :
        IllegalStateException("Sign in required to load your dashboard.")

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

    private val budgetRulesCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("budgetRules")

    private val budgetEventsCollection: CollectionReference
        get() = db.collection("users").document(currentUserId()).collection("budgetEvents")

    // ── Budget Sync APIs ──
    suspend fun uploadBudgetRule(rule: BudgetRule) {
        budgetRulesCollection.document(rule.id).set(rule.toMap()).await()
    }

    suspend fun deleteBudgetRule(id: String) {
        budgetRulesCollection.document(id).delete().await()
    }

    suspend fun uploadBudgetRules(rules: List<BudgetRule>) {
        if (rules.isEmpty()) return
        val batch = db.batch()
        for (rule in rules) {
            batch.set(budgetRulesCollection.document(rule.id), rule.toMap())
        }
        batch.commit().await()
    }

    suspend fun uploadBudgetEvents(events: List<BudgetEvent>) {
        if (events.isEmpty()) return
        val batch = db.batch()
        for (event in events) {
            batch.set(budgetEventsCollection.document(event.id), event.toMap())
        }
        batch.commit().await()
    }

    suspend fun downloadAllBudgetRules(): List<BudgetRule> {
        val snapshot = budgetRulesCollection.get().await()
        return snapshot.documents.mapNotNull { it.toBudgetRule() }
    }

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

    fun listenToUsageSince(startDate: Long): Flow<List<TokenUsage>> = callbackFlow {
        // `endTime` is written as a Firestore `Timestamp` (see iOS
        // `UsageSyncService.swift`). Querying with an ISO-8601 string
        // cutoff crosses Firestore's type-order boundary and matches zero
        // documents, surfacing as empty Pulse live data for 1M / 1H / 1D.
        // End time is the live attribution field: some gateway/session rows
        // keep their start time fixed while token totals continue advancing.
        val listener = usageCollection
            .whereGreaterThanOrEqualTo("endTime", Timestamp(Date(startDate)))
            .orderBy("endTime", Query.Direction.DESCENDING)
            .addSnapshotListener { snapshot, error ->
                if (error != null) { close(error); return@addSnapshotListener }
                trySend(snapshot?.documents?.mapNotNull { it.toTokenUsage() } ?: emptyList())
            }
        awaitClose { listener.remove() }
    }

    // ── Quota Snapshots ──
    suspend fun fetchQuotaSnapshots(): List<ProviderQuotaSnapshot> {
        val snapshot = try {
            quotaCollection.get(Source.SERVER).await()
        } catch (_: Exception) {
            quotaCollection.get(Source.DEFAULT).await()
        }
        return snapshot.documents
            .mapNotNull { it.toQuotaSnapshot() }
            .deduplicatedByProviderAccount()
    }

    fun listenToQuotaSnapshots(): Flow<List<ProviderQuotaSnapshot>> =
        listenToQuotaSnapshotUpdates().map { it.snapshots }

    fun listenToQuotaSnapshotUpdates(): Flow<QuotaSnapshotUpdate> = callbackFlow {
        val listener = quotaCollection
            .addSnapshotListener(MetadataChanges.INCLUDE) { snapshot, error ->
                if (error != null) { close(error); return@addSnapshotListener }
                trySend(
                    QuotaSnapshotUpdate(
                        snapshots = snapshot?.documents
                            ?.mapNotNull { it.toQuotaSnapshot() }
                            ?.deduplicatedByProviderAccount()
                            ?: emptyList(),
                        isFromCache = snapshot?.metadata?.isFromCache ?: false
                    )
                )
            }
        awaitClose { listener.remove() }
    }

    // ── Provider Accounts ──
    suspend fun fetchProviderAccounts(): List<ProviderAccount> {
        val snapshot = try {
            providerAccountsCollection.get(Source.SERVER).await()
        } catch (_: Exception) {
            providerAccountsCollection.get(Source.DEFAULT).await()
        }
        return snapshot.documents.mapNotNull { it.toProviderAccount() }
    }

    suspend fun markProviderAccountDeleted(accountId: String) {
        providerAccountsCollection.document(accountId)
            .update(mapOf("status" to "deleted", "updatedAt" to FieldValue.serverTimestamp()))
            .await()
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
        (raw as? Map<*, *>)?.toQuotaBucket()
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
        fetchedAt = parseTimestampOrString(data["fetchedAt"]),
        source = data["source"] as? String,
        confidence = data["confidence"] as? String ?: "low",
        managementUrl = data["managementURL"] as? String,
        statusMessage = data["statusMessage"] as? String,
        buckets = buckets,
        schemaVersion = (data["schemaVersion"] as? Number)?.toInt() ?: 0,
        updatedAt = parseTimestampOrString(data["updatedAt"])
    )
}

private fun Map<*, *>.toQuotaBucket(): QuotaBucket? {
    val meta = normalizedQuotaBucketMeta(this["meta"]).toMutableMap()
    val rawUnit = stringValue(this["unit"]) ?: stringValue(meta["unit"])
    if (rawUnit != null && meta["unit"] == null) {
        meta["unit"] = rawUnit
    }

    val name = stringValue(this["name"])
        ?: stringValue(this["key"])
        ?: stringValue(this["label"])
        ?: return null
    if (name.isBlank()) return null

    if (meta["label"] == null) {
        stringValue(this["label"])?.let { meta["label"] = it }
    }
    if (meta["isEstimated"] == null && this["isEstimated"] != null) {
        meta["isEstimated"] = stringValue(this["isEstimated"]) ?: this["isEstimated"].toString()
    }
    if (meta["usedPercent"] == null) {
        numberValue(this["usedPercent"])?.let { meta["usedPercent"] = it }
    }
    if (meta["resetsAt"] == null) {
        stringValue(this["resetsAt"])?.let { meta["resetsAt"] = it }
    }

    val unit = rawUnit?.lowercase()
    var used = numberValue(this["used"]) ?: numberValue(this["usedValue"])
    var limit = numberValue(this["limit"]) ?: numberValue(this["limitValue"])
    var remaining = numberValue(this["remaining"]) ?: numberValue(this["remainingValue"])
    val usedPercent = numberValue(this["usedPercent"]) ?: numberValue(meta["usedPercent"])

    if (limit != null && limit < 0.0) {
        if (remaining != null && remaining > 0.0) {
            used = maxOf(0.0, used ?: 0.0)
            limit = remaining + maxOf(0.0, used)
            meta.putIfAbsent("limitKind", "remainingOnly")
        } else {
            used = 0.0
            limit = 100.0
            remaining = 100.0
            meta.putIfAbsent("unit", "unlimited")
            meta.putIfAbsent("limitKind", "unlimited")
        }
    }

    if (unit == "percent" && (limit == null || limit == 0.0) && (usedPercent != null || remaining != null)) {
        limit = 100.0
    }
    if (used == null && usedPercent != null) {
        used = usedPercent
    }
    if (remaining == null && unit == "percent" && used != null && (limit ?: 0.0) > 0.0) {
        remaining = maxOf(0.0, (limit ?: 100.0) - used)
    }
    if (used == null && unit == "percent" && remaining != null && (limit ?: 0.0) > 0.0) {
        used = maxOf(0.0, (limit ?: 100.0) - remaining)
    }

    return QuotaBucket(
        name = name,
        used = used ?: 0.0,
        limit = limit ?: 0.0,
        remaining = remaining ?: 0.0,
        window = stringValue(this["window"]) ?: stringValue(this["windowKind"]),
        resetsAt = this["resetsAt"] as? Timestamp,
        meta = meta.takeIf { it.isNotEmpty() }
    )
}

private fun normalizedQuotaBucketMeta(raw: Any?): Map<String, Any?> {
    val map = raw as? Map<*, *> ?: return emptyMap()
    return map.entries
        .mapNotNull { (key, value) ->
            val stringKey = key as? String ?: return@mapNotNull null
            stringKey to value
        }
        .toMap()
}

private fun stringValue(value: Any?): String? {
    return when (value) {
        is String -> value.takeIf { it.isNotBlank() }
        is Number, is Boolean -> value.toString()
        else -> null
    }
}

private fun numberValue(value: Any?): Double? {
    return when (value) {
        is Number -> value.toDouble()
        is String -> value.trim().removeSuffix("%").toDoubleOrNull()
        else -> null
    }
}

private fun parseTimestampOrString(raw: Any?): String? {
    return when (raw) {
        is Timestamp -> raw.toDate().toInstant().toString()
        is String -> raw.takeIf { it.isNotBlank() }
        else -> null
    }
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

fun BudgetRule.toMap(): Map<String, Any?> {
    return mapOf(
        "id" to id,
        "scope" to scope,
        "identifier" to identifier,
        "providerID" to providerID,
        "accountID" to accountID,
        "projectName" to projectName,
        "label" to label,
        "amountUSD" to amountUSD,
        "period" to period,
        "behavior" to behavior,
        "fallbackCredentialIDsJSON" to fallbackCredentialIDsJSON,
        "pausedUntil" to pausedUntil?.let { com.google.firebase.Timestamp(it) },
        "createdAt" to (createdAt?.let { com.google.firebase.Timestamp(it) } ?: com.google.firebase.firestore.FieldValue.serverTimestamp()),
        "updatedAt" to com.google.firebase.firestore.FieldValue.serverTimestamp(),
        "sourceDeviceID" to sourceDeviceID,
        "isEnabled" to isEnabled
    )
}

fun DocumentSnapshot.toBudgetRule(): BudgetRule? {
    val data = data ?: return null
    val pausedUntilTimestamp = data["pausedUntil"] as? com.google.firebase.Timestamp
    val createdAtTimestamp = data["createdAt"] as? com.google.firebase.Timestamp
    val updatedAtTimestamp = data["updatedAt"] as? com.google.firebase.Timestamp
    val syncedAtTimestamp = data["syncedAt"] as? com.google.firebase.Timestamp

    return BudgetRule(
        id = id,
        scope = data["scope"] as? String ?: "",
        identifier = data["identifier"] as? String,
        providerID = data["providerID"] as? String,
        accountID = data["accountID"] as? String,
        projectName = data["projectName"] as? String,
        label = data["label"] as? String,
        amountUSD = (data["amountUSD"] as? Number)?.toDouble() ?: 0.0,
        period = data["period"] as? String ?: "",
        behavior = data["behavior"] as? String ?: "",
        fallbackCredentialIDsJSON = data["fallbackCredentialIDsJSON"] as? String,
        pausedUntil = pausedUntilTimestamp?.toDate(),
        createdAt = createdAtTimestamp?.toDate(),
        updatedAt = updatedAtTimestamp?.toDate(),
        syncedAt = syncedAtTimestamp?.toDate(),
        sourceDeviceID = data["sourceDeviceID"] as? String,
        isEnabled = data["isEnabled"] as? Boolean ?: true
    )
}

fun BudgetEvent.toMap(): Map<String, Any?> {
    return mapOf(
        "id" to id,
        "ruleID" to ruleID,
        "kind" to kind,
        "source" to source,
        "amountAtEvent" to amountAtEvent,
        "limitAtEvent" to limitAtEvent,
        "detailJSON" to detailJSON,
        "occurredAt" to (occurredAt?.let { com.google.firebase.Timestamp(it) } ?: com.google.firebase.firestore.FieldValue.serverTimestamp()),
        "syncedAt" to com.google.firebase.firestore.FieldValue.serverTimestamp(),
        "sourceDeviceID" to sourceDeviceID
    )
}

fun DocumentSnapshot.toBudgetEvent(): BudgetEvent? {
    val data = data ?: return null
    val occurredAtTimestamp = data["occurredAt"] as? com.google.firebase.Timestamp
    val syncedAtTimestamp = data["syncedAt"] as? com.google.firebase.Timestamp

    return BudgetEvent(
        id = id,
        ruleID = data["ruleID"] as? String ?: "",
        kind = data["kind"] as? String ?: "",
        source = data["source"] as? String,
        amountAtEvent = (data["amountAtEvent"] as? Number)?.toDouble() ?: 0.0,
        limitAtEvent = (data["limitAtEvent"] as? Number)?.toDouble() ?: 0.0,
        detailJSON = data["detailJSON"] as? String,
        occurredAt = occurredAtTimestamp?.toDate(),
        syncedAt = syncedAtTimestamp?.toDate(),
        sourceDeviceID = data["sourceDeviceID"] as? String
    )
}
