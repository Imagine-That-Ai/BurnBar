package com.openburnbar.data.models

import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName

/**
 * Mirrors the Firestore `UsageEventDoc` from Cloud Functions types.ts.
 * Collection: users/{uid}/usage/{docId}
 */
@IgnoreExtraProperties
data class TokenUsage(
    val id: String = "",

    @PropertyName("provider")
    val provider: String = "",

    @PropertyName("providerID")
    val providerId: String? = null,

    @PropertyName("providerAccountID")
    val providerAccountId: String? = null,

    @PropertyName("providerAccountLabel")
    val providerAccountLabel: String? = null,

    @PropertyName("providerAccountSource")
    val providerAccountSource: String? = null,

    @PropertyName("model")
    val model: String? = null,

    @PropertyName("sessionId")
    val sessionId: String? = null,

    @PropertyName("deviceId")
    val deviceId: String? = null,

    @PropertyName("sourceDeviceId")
    val sourceDeviceId: String? = null,

    @PropertyName("inputTokens")
    val inputTokens: Int = 0,

    @PropertyName("outputTokens")
    val outputTokens: Int = 0,

    @PropertyName("cacheCreationTokens")
    val cacheCreationTokens: Int = 0,

    @PropertyName("cacheReadTokens")
    val cacheReadTokens: Int = 0,

    @PropertyName("reasoningTokens")
    val reasoningTokens: Int = 0,

    @PropertyName("totalTokens")
    val totalTokens: Int = 0,

    /** Canonical cost field (Firestore "costUsd"). */
    @PropertyName("costUsd")
    val costUsd: Double = 0.0,

    /** Legacy cost field (Firestore "cost"), consumer falls back to costUsd. */
    @PropertyName("cost")
    val cost: Double = 0.0,

    @PropertyName("provenanceConfidence")
    val provenanceConfidence: String? = null,

    @PropertyName("provenanceMethod")
    val provenanceMethod: String? = null,

    @PropertyName("user_display_id")
    val userDisplayId: String? = null,

    @PropertyName("project_name")
    val projectName: String? = null,

    /** Millis since epoch — manually converted from Firestore Timestamp in repository. */
    @PropertyName("timestamp")
    val timestamp: Long = 0L,

    @PropertyName("startTime")
    val startTime: Long = 0L,

    @PropertyName("endTime")
    val endTime: Long = 0L,

    @PropertyName("createdAt")
    val createdAt: Long = 0L,

    @PropertyName("updatedAt")
    val updatedAt: Long = 0L,

    @PropertyName("schemaVersion")
    val schemaVersion: Int = 0
) {
    /** Effective cost — prefers costUsd, falls back to cost. */
    val effectiveCost: Double
        get() = if (costUsd > 0.0) costUsd else cost
}

/**
 * Mirrors the Firestore `ProviderAccountDoc` + extra fields observed in live data.
 * Collection: users/{uid}/provider_accounts/{accountId}
 */
@IgnoreExtraProperties
data class ProviderAccount(
    val id: String = "",

    /** Canonical provider key (matches UsageEventDoc.providerID). */
    @PropertyName("providerID")
    val providerId: String = "",

    /** User-visible label (Firestore "label"). */
    @PropertyName("label")
    val label: String = "",

    @PropertyName("identityHint")
    val identityHint: String? = null,

    @PropertyName("status")
    val status: String? = null,

    @PropertyName("credentialKind")
    val credentialKind: String? = null,

    @PropertyName("storageScope")
    val storageScope: String? = null,

    @PropertyName("redactedLabel")
    val redactedLabel: String? = null,

    @PropertyName("sourceDeviceID")
    val sourceDeviceId: String? = null,

    @PropertyName("linkedSwitcherProfileID")
    val linkedSwitcherProfileId: String? = null,

    @PropertyName("isDefault")
    val isDefault: Boolean = false,

    @PropertyName("sortKey")
    val sortKey: Double = 0.0,

    @PropertyName("lastValidatedAt")
    val lastValidatedAt: String? = null,

    @PropertyName("lastRefreshAt")
    val lastRefreshAt: String? = null,

    @PropertyName("lastErrorCode")
    val lastErrorCode: String? = null,

    @PropertyName("schemaVersion")
    val schemaVersion: Int = 0,

    @PropertyName("createdAt")
    val createdAt: String? = null,

    @PropertyName("updatedAt")
    val updatedAt: String? = null,

    // ── Live-data extra fields (not in TS types, observed in Firestore) ──

    @PropertyName("usage_limit")
    val usageLimit: Long = 0,

    @PropertyName("usage_used")
    val usageUsed: Long = 0,

    @PropertyName("integration")
    val integration: String? = null,

    @PropertyName("latitude")
    val latitude: Double? = null,

    @PropertyName("organization_id")
    val organizationId: String? = null
)

/**
 * Mirrors the Firestore `QuotaSnapshotDoc`.
 * Collection: users/{uid}/quota_snapshots/{provider}_{sourceId}
 */
@IgnoreExtraProperties
data class ProviderQuotaSnapshot(
    val id: String = "",

    @PropertyName("sourceKind")
    val sourceKind: String = "provider",

    @PropertyName("sourceId")
    val sourceId: String = "",

    @PropertyName("provider")
    val provider: String = "",

    @PropertyName("providerID")
    val providerId: String? = null,

    @PropertyName("accountID")
    val accountId: String? = null,

    @PropertyName("accountLabel")
    val accountLabel: String? = null,

    @PropertyName("accountStorageScope")
    val accountStorageScope: String? = null,

    @PropertyName("fetchedAt")
    val fetchedAt: String? = null,

    @PropertyName("source")
    val source: String? = null,

    @PropertyName("confidence")
    val confidence: String = "low",

    @PropertyName("managementURL")
    val managementUrl: String? = null,

    @PropertyName("statusMessage")
    val statusMessage: String? = null,

    @PropertyName("buckets")
    val buckets: List<QuotaBucket> = emptyList(),

    @PropertyName("schemaVersion")
    val schemaVersion: Int = 0,

    @PropertyName("updatedAt")
    val updatedAt: String? = null
) {
    /** Total remaining computed from buckets. Returns -1 if unlimited. */
    val quotaRemaining: Double
        get() = buckets.sumOf { it.remaining }

    /** Total limit computed from buckets. Returns -1 if any bucket is unlimited. */
    val quotaLimit: Double
        get() {
            if (buckets.isEmpty()) return 0.0
            if (buckets.any { it.limit < 0 }) return -1.0
            return buckets.sumOf { it.limit }
        }

    /** Computed percentage remaining from buckets. */
    val percentageRemaining: Double
        get() {
            val limit = quotaLimit
            if (limit <= 0) return 0.0
            val remaining = quotaRemaining
            return (remaining / limit * 100).coerceIn(0.0, 100.0)
        }

    /** @deprecated Use accountId + accountLabel instead. */
    val accountCount: Int
        get() = if (accountId != null) 1 else 0

    /** @deprecated Use confidence check. */
    val isUnlimited: Boolean
        get() = buckets.any { it.limit < 0 }
}

/** One bucket in a QuotaSnapshotDoc. */
@IgnoreExtraProperties
data class QuotaBucket(
    @PropertyName("name")
    val name: String = "",

    @PropertyName("used")
    val used: Double = 0.0,

    @PropertyName("limit")
    val limit: Double = 0.0,

    @PropertyName("remaining")
    val remaining: Double = 0.0,

    @PropertyName("window")
    val window: String? = null,

    /**
     * First-class refill moment. Mac writes a Firestore `Timestamp` on the
     * bucket directly; older docs may instead carry an ISO 8601 string at
     * `meta["resetsAt"]`. Use [effectiveResetsAt] to read either form.
     */
    @PropertyName("resetsAt")
    val resetsAt: com.google.firebase.Timestamp? = null,

    @PropertyName("meta")
    val meta: Map<String, Any?>? = null
)

/**
 * Resolves a bucket's reset moment from either the new top-level
 * `resetsAt` field or the legacy ISO 8601 string at `meta["resetsAt"]`.
 * Returns `null` when neither is present so callers can omit the reset
 * row instead of showing a placeholder.
 */
val QuotaBucket.effectiveResetsAt: java.time.Instant?
    get() {
        resetsAt?.let { return it.toDate().toInstant() }
        val legacy = meta?.get("resetsAt") as? String ?: return null
        return runCatching { java.time.Instant.parse(legacy) }.getOrNull()
    }

/**
 * Mirrors the Firestore `ProjectSummary` (derived from usages collection).
 * Collection: users/{uid}/projects/{projectName}
 */
@IgnoreExtraProperties
data class ProjectSummary(
    val id: String = "",
    val name: String = "",
    @PropertyName("total_cost")
    val totalCost: Double = 0.0,
    @PropertyName("total_tokens")
    val totalTokens: Long = 0,
    @PropertyName("total_sessions")
    val totalSessions: Int = 0
)


/**
 * Mirrors a summary entry in the `UsageRollupDoc` (providerSummaries, modelSummaries, etc.)
 */
data class RollupSummary(
    val provider: String = "",
    val providerId: String? = null,
    val accountId: String? = null,
    val accountLabel: String = "",
    val storageScope: String? = null,
    val totalRequests: Int = 0,
    val totalTokens: Long = 0,
    val totalCost: Double = 0.0
)

/**
 * Mirrors the Firestore `UsageRollupDoc` flat shape.
 * Collection: users/{uid}/usage_rollups/usage_rollups
 */
data class UsageRollups(
    val today: Double = 0.0,
    val sevenDays: Double = 0.0,
    val thirtyDays: Double = 0.0,
    val ninetyDays: Double = 0.0,
    val allTime: Double = 0.0,
    val todayTokens: Long = 0,
    val sevenDayTokens: Long = 0,
    val thirtyDayTokens: Long = 0,
    val ninetyDayTokens: Long = 0,
    val allTimeTokens: Long = 0,
    val totals: Map<String, Double> = emptyMap(),
    val providerSummaries: List<RollupSummary> = emptyList(),
    val accountSummaries: List<RollupSummary> = emptyList(),
    val modelSummaries: List<RollupSummary> = emptyList(),
    val deviceSummaries: List<RollupSummary> = emptyList(),
    val dailyPoints: Map<String, Double> = emptyMap(),
    val computedAt: String? = null,
    val schemaVersion: Int = 0
) {
    val topProviders: List<RollupSummary>
        get() = providerSummaries.sortedByDescending { it.totalCost }.take(5)
}

enum class UsageDisplayMode(val key: String, val label: String) {
    CURRENCY("currency", "USD"),
    TOKENS("tokens", "Tokens");
}

enum class TimelineScope(val rollupKey: String, val trailingKey: String, val label: String) {
    DAY("today", "today", "Day"),
    WEEK("7d", "7d", "Week"),
    MONTH("30d", "last_30d", "Month");
}
