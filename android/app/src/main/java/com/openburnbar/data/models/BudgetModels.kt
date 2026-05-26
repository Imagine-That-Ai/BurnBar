package com.openburnbar.data.models

import com.google.firebase.firestore.IgnoreExtraProperties
import com.google.firebase.firestore.PropertyName
import java.util.Date

@IgnoreExtraProperties
data class BudgetRule(
    val id: String = "",
    val scope: String = "",          // credential, project, global, organization
    val identifier: String? = null,

    @get:PropertyName("providerID")
    @PropertyName("providerID")
    val providerID: String? = null,

    @get:PropertyName("accountID")
    @PropertyName("accountID")
    val accountID: String? = null,

    val projectName: String? = null,
    val label: String? = null,
    val amountUSD: Double = 0.0,
    val period: String = "",          // day, week, month, allTime
    val behavior: String = "",        // warnThenBlock, hardBlock, warnOnly, hardBlockWithFallback
    val fallbackCredentialIDsJSON: String? = null,
    val pausedUntil: Date? = null,
    val createdAt: Date? = null,
    val updatedAt: Date? = null,
    val syncedAt: Date? = null,
    val sourceDeviceID: String? = null,
    val isEnabled: Boolean = true
) {
    val displayLabel: String
        get() = when {
            !label.isNullOrBlank() -> label
            scope == "credential" -> "${providerID ?: "credential"} · ${accountID?.takeLast(6) ?: "default"}"
            scope == "project" -> projectName ?: "Unnamed project"
            scope == "global" -> "All per-usage credentials"
            scope == "organization" -> identifier ?: "Organization"
            else -> id
        }

    fun isPausedAt(reference: Date = Date()): Boolean =
        pausedUntil != null && pausedUntil.after(reference)
}

enum class BudgetRuleScope(val value: String) {
    CREDENTIAL("credential"),
    PROJECT("project"),
    GLOBAL("global"),
    ORGANIZATION("organization")
}

enum class BudgetPeriod(val value: String) {
    DAY("day"),
    WEEK("week"),
    MONTH("month"),
    ALL_TIME("allTime")
}

enum class BudgetBehavior(val value: String) {
    WARN_THEN_BLOCK("warnThenBlock"),
    HARD_BLOCK("hardBlock"),
    WARN_ONLY("warnOnly"),
    HARD_BLOCK_WITH_FALLBACK("hardBlockWithFallback")
}

enum class BudgetBillingMode(val value: String) {
    PER_USAGE("perUsage"),
    SUBSCRIPTION("subscription"),
    UNKNOWN("unknown");

    companion object {
        fun forSecretPrefix(prefix: String): BudgetBillingMode {
            val lower = prefix.lowercase()
            return when {
                lower.startsWith("sk-ant-oat") -> SUBSCRIPTION
                lower.startsWith("sk-ant-api") -> PER_USAGE
                lower.startsWith("sk-") -> PER_USAGE
                else -> UNKNOWN
            }
        }
    }
}

@IgnoreExtraProperties
data class BudgetEvent(
    val id: String = "",
    val ruleID: String = "",
    val kind: String = "",       // warning, block, override, pause, resume, ruleCreated, ruleUpdated, ruleDeleted
    val source: String? = null,
    val amountAtEvent: Double = 0.0,
    val limitAtEvent: Double = 0.0,
    val detailJSON: String? = null,
    val occurredAt: Date? = null,
    val syncedAt: Date? = null,
    val sourceDeviceID: String? = null
)

data class BudgetGateDecision(
    val kind: Kind,
    val rule: BudgetRule? = null,
    val usedPercent: Double = 0.0,
    val used: Double = 0.0,
    val limit: Double = 0.0,
    val fallback: BudgetCredentialIdentity? = null,
    val resumeAt: Date? = null
) {
    enum class Kind { ALLOW, WARN, BLOCK, PAUSED }
}

data class BudgetCredentialIdentity(
    val providerID: String,
    val slotID: String,
    val displayLabel: String,
    val billingMode: BudgetBillingMode
)

data class OrgRollupRow(
    val label: String,
    val totalCost: Double,
    val totalTokens: Long,
    val sessionCount: Int,
    val deviceCount: Int
)
