package com.openburnbar.data.models

import com.google.firebase.firestore.PropertyName

data class TokenUsage(
    val id: String = "",
    val provider: String = "",
    val model: String = "",
    @PropertyName("input_tokens")
    val inputTokens: Int = 0,
    @PropertyName("output_tokens")
    val outputTokens: Int = 0,
    @PropertyName("cache_creation_tokens")
    val cacheCreationTokens: Int = 0,
    @PropertyName("cache_read_tokens")
    val cacheReadTokens: Int = 0,
    @PropertyName("total_tokens")
    val totalTokens: Int = 0,
    val cost: Double = 0.0,
    val timestamp: Long = 0L,
    @PropertyName("session_id")
    val sessionId: String = "",
    @PropertyName("project_name")
    val projectName: String? = null,
    val device: String? = null,
    @PropertyName("provenance_confidence")
    val provenanceConfidence: String? = null,
    @PropertyName("provenance_method")
    val provenanceMethod: String? = null,
    @PropertyName("user_display_id")
    val userDisplayId: String? = null
)

data class ProviderSummary(
    val provider: String,
    @PropertyName("total_cost")
    val totalCost: Double = 0.0,
    @PropertyName("total_tokens")
    val totalTokens: Int = 0,
    @PropertyName("total_input_tokens")
    val totalInputTokens: Int = 0,
    @PropertyName("total_output_tokens")
    val totalOutputTokens: Int = 0,
    @PropertyName("session_count")
    val sessionCount: Int = 0
)

data class ModelSummary(
    val model: String,
    @PropertyName("display_name")
    val displayName: String = "",
    @PropertyName("total_cost")
    val totalCost: Double = 0.0,
    @PropertyName("total_tokens")
    val totalTokens: Int = 0,
    @PropertyName("total_input_tokens")
    val totalInputTokens: Int = 0,
    @PropertyName("total_output_tokens")
    val totalOutputTokens: Int = 0,
    @PropertyName("session_count")
    val sessionCount: Int = 0
)

data class DeviceSummary(
    val device: String,
    @PropertyName("total_cost")
    val totalCost: Double = 0.0,
    @PropertyName("total_tokens")
    val totalTokens: Int = 0,
    @PropertyName("session_count")
    val sessionCount: Int = 0
)

data class DailyPoint(
    val date: String = "",
    @PropertyName("total_cost")
    val totalCost: Double = 0.0,
    @PropertyName("total_tokens")
    val totalTokens: Int = 0,
    @PropertyName("breakdown")
    val breakdown: Map<String, Double>? = null
)

data class ProviderQuotaSnapshot(
    val provider: String = "",
    @PropertyName("quota_limit")
    val quotaLimit: Long = 0,
    @PropertyName("quota_used")
    val quotaUsed: Long = 0,
    @PropertyName("quota_remaining")
    val quotaRemaining: Long = 0,
    @PropertyName("percentage_remaining")
    val percentageRemaining: Double = 100.0,
    @PropertyName("account_count")
    val accountCount: Int = 0,
    @PropertyName("is_unlimited")
    val isUnlimited: Boolean = false,
    @PropertyName("last_synced")
    val lastSynced: Long = 0L
)

data class ProviderAccount(
    val id: String = "",
    val provider: String = "",
    @PropertyName("account_label")
    val accountLabel: String = "",
    @PropertyName("quota_limit")
    val quotaLimit: Long = 0,
    @PropertyName("quota_used")
    val quotaUsed: Long = 0,
    @PropertyName("routing_policy")
    val routingPolicy: String? = null
)

data class ProjectSummary(
    val id: String = "",
    val name: String = "",
    @PropertyName("total_cost")
    val totalCost: Double = 0.0,
    @PropertyName("total_tokens")
    val totalTokens: Int = 0,
    @PropertyName("total_sessions")
    val totalSessions: Int = 0
)

enum class UsageDisplayMode(val key: String, val label: String) {
    CURRENCY("currency", "USD"),
    TOKENS("tokens", "Tokens");
}

enum class TimelineScope(val rollupKey: String, val trailingKey: String, val label: String) {
    DAY("today", "yesterday", "Day"),
    WEEK("seven_days", "last_seven_days", "Week"),
    MONTH("thirty_days", "last_thirty_days", "Month");
}
