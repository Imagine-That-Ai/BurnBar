package com.openburnbar.data.models

import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName
import kotlin.math.roundToInt

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
            return buckets
                .mapNotNull { it.displayRemainingPercent }
                .minOrNull()
                ?: 0.0
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
 * Display-safe remaining fraction for quota UI. Several providers expose
 * percentage quota via metadata, percentage buckets with a zero limit, or
 * unknown/unlimited caps with `limit == -1`; raw `remaining / limit` renders
 * those as false `0%` values.
 */
val QuotaBucket.displayRemainingFraction: Double?
    get() {
        metaNumber(
            "usedPercent",
            "used_percent",
            "used_percentage",
            "usagePercent",
            "usage_percent",
            "percentage"
        )?.let { usedPercent ->
            return ((100.0 - usedPercent) / 100.0).coerceIn(0.0, 1.0)
        }

        metaNumber(
            "remainingPercent",
            "remaining_percent",
            "remainingPercentage",
            "remaining_percentage",
            "percentRemaining",
            "percent_remaining"
        )?.let { remainingPercent ->
            return (remainingPercent / 100.0).coerceIn(0.0, 1.0)
        }

        val unit = metaString("unit")?.lowercase()
        val limitKind = metaString("limitKind")?.lowercase()
        if (unit == "unlimited" || limitKind == "unlimited") return 1.0

        if (!used.isFinite() || !limit.isFinite() || !remaining.isFinite()) return null

        if (limit > 0.0) {
            return (maxOf(0.0, remaining) / limit).coerceIn(0.0, 1.0)
        }

        if (unit == "percent" || unit == "%") {
            if (remaining >= 0.0) return (remaining / 100.0).coerceIn(0.0, 1.0)
            if (used >= 0.0) return ((100.0 - used) / 100.0).coerceIn(0.0, 1.0)
        }

        if (limit < 0.0 && remaining > 0.0) {
            // Balance-only or remaining-only signals have no known cap; they
            // should not be marked as exhausted.
            val syntheticLimit = remaining + maxOf(0.0, used)
            return if (syntheticLimit > 0.0) {
                (remaining / syntheticLimit).coerceIn(0.0, 1.0)
            } else {
                1.0
            }
        }

        return null
    }

val QuotaBucket.displayRemainingPercent: Double?
    get() = displayRemainingFraction?.times(100.0)

val QuotaBucket.key: String
    get() {
        val nameKey = name.trim().lowercase()
        val windowKey = window?.trim()?.lowercase().orEmpty()
        return if (windowKey.isEmpty()) nameKey else "$nameKey::$windowKey"
    }

val QuotaBucket.label: String
    get() = (meta?.get("label") as? String) ?: name

fun QuotaBucket.isDisplayableQuotaSignal(): Boolean {
    if (!used.isFinite() || !limit.isFinite() || !remaining.isFinite()) {
        return false
    }

    val marker = "${name} ${(meta?.get("label") as? String) ?: ""}".lowercase()
    if (listOf("cache", "hit rate", "local model", "cloud model", "installed", "task", "conversation", "line", "file").any { marker.contains(it) }) {
        return false
    }

    val unit = (meta?.get("unit") as? String)?.lowercase()
    if (unit != null) {
        if (listOf("sessions", "session", "lines", "files", "models").contains(unit)) {
            return false
        }
        if (unit == "count" && !(marker.contains("credit") || marker.contains("budget"))) {
            return false
        }
    }

    return displayRemainingFraction != null
}

fun ProviderQuotaSnapshot.customizedBuckets(
    hiddenBuckets: Set<String>,
    bucketOrders: Map<String, List<String>>
): List<QuotaBucket> {
    val displayable = buckets.filter { it.isDisplayableQuotaSignal() }
    val token = provider.lowercase()

    val filtered = displayable.filter { bucket ->
        val compositeKey = "$token:${bucket.key}"
        !hiddenBuckets.contains(compositeKey)
    }

    val customOrder = bucketOrders[token]
    if (customOrder != null) {
        return filtered.sortedWith { lhs, rhs ->
            val lhsIdx = customOrder.indexOf(lhs.key).takeIf { it >= 0 } ?: Int.MAX_VALUE
            val rhsIdx = customOrder.indexOf(rhs.key).takeIf { it >= 0 } ?: Int.MAX_VALUE
            if (lhsIdx != rhsIdx) {
                lhsIdx.compareTo(rhsIdx)
            } else {
                lhs.label.compareTo(rhs.label, ignoreCase = true)
            }
        }
    }

    return filtered
}

enum class ProviderQuotaUnit(val shortLabel: String) {
    PERCENT("%"),
    REQUESTS("req"),
    TOKENS("tok"),
    SESSIONS("sessions"),
    LINES("lines"),
    FILES("files"),
    COUNT(""),
    CURRENCY("$");
}

val QuotaBucket.bucketUnit: ProviderQuotaUnit
    get() {
        val unitStr = (meta?.get("unit") as? String)?.lowercase() ?: ""
        return when {
            unitStr.contains("percent") || unitStr.contains("%") -> ProviderQuotaUnit.PERCENT
            unitStr.contains("request") || unitStr.contains("rpm") -> ProviderQuotaUnit.REQUESTS
            unitStr.contains("token") -> ProviderQuotaUnit.TOKENS
            unitStr.contains("session") -> ProviderQuotaUnit.SESSIONS
            unitStr.contains("line") -> ProviderQuotaUnit.LINES
            unitStr.contains("file") -> ProviderQuotaUnit.FILES
            unitStr.contains("currency") || unitStr.contains("usd") || unitStr.contains("$") -> ProviderQuotaUnit.CURRENCY
            else -> {
                val nameLower = name.lowercase()
                when {
                    nameLower.contains("percent") || nameLower.contains("%") -> ProviderQuotaUnit.PERCENT
                    nameLower.contains("request") -> ProviderQuotaUnit.REQUESTS
                    nameLower.contains("token") -> ProviderQuotaUnit.TOKENS
                    nameLower.contains("session") -> ProviderQuotaUnit.SESSIONS
                    nameLower.contains("line") -> ProviderQuotaUnit.LINES
                    nameLower.contains("file") -> ProviderQuotaUnit.FILES
                    nameLower.contains("credit") || nameLower.contains("budget") || nameLower.contains("balance") -> ProviderQuotaUnit.CURRENCY
                    else -> ProviderQuotaUnit.COUNT
                }
            }
        }
    }

val QuotaBucket.progressFraction: Double
    get() {
        val usedP = metaNumber("usedPercent", "used_percent", "used_percentage", "usagePercent", "usage_percent", "percentage")
        if (usedP != null) {
            return (usedP / 100.0).coerceIn(0.0, 1.0)
        }
        if (limit > 0.0) {
            return (used / limit).coerceIn(0.0, 1.0)
        }
        val remainingP = displayRemainingPercent
        if (remainingP != null) {
            return ((100.0 - remainingP) / 100.0).coerceIn(0.0, 1.0)
        }
        return 0.0
    }

fun QuotaBucket.formatValue(value: Double): String {
    val u = this.bucketUnit
    return when (u) {
        ProviderQuotaUnit.PERCENT -> {
            val clamped = value.coerceIn(0.0, 100.0)
            "${clamped.roundToInt()}%"
        }
        ProviderQuotaUnit.TOKENS -> {
            when {
                value >= 1_000_000_000 -> "%.2fB".format(value / 1_000_000_000.0)
                value >= 1_000_000 -> "%.1fM".format(value / 1_000_000.0)
                value >= 1_000 -> "%.1fK".format(value / 1_000.0)
                else -> "${value.roundToInt()}"
            }
        }
        ProviderQuotaUnit.REQUESTS, ProviderQuotaUnit.SESSIONS, ProviderQuotaUnit.LINES, ProviderQuotaUnit.FILES, ProviderQuotaUnit.COUNT -> {
            when {
                value >= 1_000 -> "%.1fK".format(value / 1_000.0)
                value.roundToInt().toDouble() == value -> "${value.roundToInt()}"
                else -> "%.1f".format(value)
            }
        }
        ProviderQuotaUnit.CURRENCY -> {
            "$%.2f".format(value)
        }
    }
}

fun QuotaBucket.getRemainingText(displayMode: String): String {
    val remainingPercent = displayRemainingPercent
    return when (displayMode) {
        "remainingPercent" -> {
            if (remainingPercent != null) {
                val clamped = remainingPercent.coerceIn(0.0, 100.0)
                "${clamped.roundToInt()}% left"
            } else {
                "${formatValue(remaining)} left"
            }
        }
        "usedPercent" -> {
            val usedP = if (remainingPercent != null) {
                (100.0 - remainingPercent).coerceIn(0.0, 100.0)
            } else {
                progressFraction * 100.0
            }
            "${usedP.roundToInt()}% used"
        }
        "fractional" -> {
            val frac = if (remainingPercent != null) {
                remainingPercent / 100.0
            } else if (limit > 0.0) {
                remaining / limit
            } else {
                1.0 - progressFraction
            }
            "%.2f left".format(frac.coerceIn(0.0, 1.0))
        }
        "absoluteValues" -> {
            if (limit > 0.0) {
                "${formatValue(remaining)} / ${formatValue(limit)} left"
            } else {
                "${formatValue(remaining)} left"
            }
        }
        else -> {
            if (remainingPercent != null) {
                val clamped = remainingPercent.coerceIn(0.0, 100.0)
                "${clamped.roundToInt()}% left"
            } else {
                "${formatValue(remaining)} left"
            }
        }
    }
}

private fun QuotaBucket.metaNumber(vararg keys: String): Double? {
    val meta = meta ?: return null
    for (key in keys) {
        meta[key].asDoubleOrNull()?.let { return it }
    }
    return null
}

private fun QuotaBucket.metaString(key: String): String? {
    return meta?.get(key)?.asStringOrNull()
}

private fun Any?.asDoubleOrNull(): Double? = when (this) {
    is Number -> toDouble()
    is String -> trim().removeSuffix("%").toDoubleOrNull()
    else -> null
}

private fun Any?.asStringOrNull(): String? = when (this) {
    is String -> takeIf { it.isNotBlank() }
    is Number, is Boolean -> toString()
    else -> null
}

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

val QuotaBucket.effectiveWindowLabel: String
    get() = listOfNotNull(name, window).joinToString(" ")

val ProviderQuotaSnapshot.isExplicitlyStale: Boolean
    get() = confidence.equals("stale", ignoreCase = true) ||
        confidence.equals("unavailable", ignoreCase = true) ||
        statusMessage?.contains("stale", ignoreCase = true) == true

fun ProviderQuotaSnapshot.isStale(now: java.time.Instant = java.time.Instant.now()): Boolean {
    if (isExplicitlyStale) {
        android.util.Log.d(
            "QuotaStale",
            "provider=$provider account=${accountLabel ?: accountId} " +
                "isExplicitlyStale=true confidence=$confidence statusMsg=$statusMessage"
        )
        return true
    }
    val fetchedAtStr = fetchedAt?.takeIf { it.isNotBlank() }
    val updatedAtStr = updatedAt?.takeIf { it.isNotBlank() }
    val fetched = listOfNotNull(fetchedAtStr, updatedAtStr)
        .firstNotNullOfOrNull { runCatching { java.time.Instant.parse(it) }.getOrNull() }
    if (fetched == null) {
        android.util.Log.d(
            "QuotaStale",
            "provider=$provider account=${accountLabel ?: accountId} " +
                "fetchedAt=$fetchedAtStr updatedAt=$updatedAtStr -> no parseable timestamp -> stale"
        )
        return true
    }
    val age = java.time.Duration.between(fetched, now)
    val stale = age > java.time.Duration.ofHours(12)
    if (stale) {
        android.util.Log.d(
            "QuotaStale",
            "provider=$provider account=${accountLabel ?: accountId} " +
                "timestamp=${fetched} age=${age.toHours()}h -> stale (>12h)"
        )
    }
    return stale
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
    val todayRequests: Int = 0,
    val sevenDayRequests: Int = 0,
    val thirtyDayRequests: Int = 0,
    val ninetyDayRequests: Int = 0,
    val allTimeRequests: Int = 0,
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

    fun isEmpty(): Boolean =
        today == 0.0 &&
            sevenDays == 0.0 &&
            thirtyDays == 0.0 &&
            ninetyDays == 0.0 &&
            allTime == 0.0 &&
            todayTokens == 0L &&
            sevenDayTokens == 0L &&
            thirtyDayTokens == 0L &&
            ninetyDayTokens == 0L &&
            allTimeTokens == 0L &&
            totals.isEmpty()
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
