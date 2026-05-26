package com.openburnbar.data.budget

import com.openburnbar.data.db.BudgetDao
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.data.models.*
import java.util.*
import kotlin.math.max

class BudgetGate(
    private val dao: BudgetDao,
    private val warningThreshold: Double = 0.8
) {
    data class EvaluateResult(
        val decision: BudgetGateDecision.Kind,
        val rule: BudgetRule? = null,
        val used: Double = 0.0,
        val limit: Double = 0.0,
        val usedPercent: Double = 0.0,
        val fallback: BudgetCredentialIdentity? = null,
        val resumeAt: Date? = null
    )

    suspend fun evaluate(
        credential: BudgetCredentialIdentity,
        projectName: String? = null,
        estimatedCost: Double,
        reference: Date = Date()
    ): EvaluateResult {
        if (credential.billingMode == BudgetBillingMode.SUBSCRIPTION) {
            return EvaluateResult(BudgetGateDecision.Kind.ALLOW)
        }

        val candidates = mutableListOf<BudgetRuleEntity>()
        candidates.addAll(dao.getCredentialRules(credential.providerID, credential.slotID))
        if (!projectName.isNullOrBlank()) {
            candidates.addAll(dao.getProjectRules(projectName))
        }
        candidates.addAll(dao.getGlobalRules())

        val activeRules = candidates.filter { it.isEnabled && it.amountUSD > 0 }
        if (activeRules.isEmpty()) {
            return EvaluateResult(BudgetGateDecision.Kind.ALLOW)
        }

        var worst = EvaluateResult(BudgetGateDecision.Kind.ALLOW)
        for (ruleEntity in activeRules) {
            val rule = ruleEntity.toModel()
            if (rule.isPausedAt(reference)) {
                val paused = EvaluateResult(
                    decision = BudgetGateDecision.Kind.PAUSED,
                    rule = rule,
                    resumeAt = rule.pausedUntil
                )
                worst = if (priority(paused.decision) > priority(worst.decision)) paused else worst
                continue
            }

            val used = currentSpendForRule(ruleEntity, reference)
            val projected = used + max(0.0, estimatedCost)
            val decision = classify(rule, used, projected)
            worst = if (priority(decision.decision) > priority(worst.decision)) decision else worst
        }
        return worst
    }

    fun currentSpendForRule(rule: BudgetRuleEntity, reference: Date): Double {
        val windowStartMs = getWindowStartMs(rule.period, reference)
        val referenceMs = reference.time

        return when (rule.scope) {
            "credential" -> {
                dao.getCredentialSpend(
                    windowStart = windowStartMs,
                    reference = referenceMs,
                    providerID = rule.providerID ?: "",
                    accountID = rule.accountID ?: ""
                )
            }
            "project" -> {
                dao.getProjectSpend(
                    windowStart = windowStartMs,
                    reference = referenceMs,
                    projectName = rule.projectName ?: ""
                )
            }
            "organization" -> {
                dao.getOrganizationSpend(
                    windowStart = windowStartMs,
                    reference = referenceMs,
                    identifier = rule.identifier ?: ""
                )
            }
            "global" -> {
                dao.getGlobalSpend(
                    windowStart = windowStartMs,
                    reference = referenceMs
                )
            }
            else -> 0.0
        }
    }

    private fun getWindowStartMs(periodStr: String, reference: Date): Long {
        val calendar = Calendar.getInstance()
        calendar.time = reference

        return when (periodStr) {
            "day" -> {
                calendar.set(Calendar.HOUR_OF_DAY, 0)
                calendar.set(Calendar.MINUTE, 0)
                calendar.set(Calendar.SECOND, 0)
                calendar.set(Calendar.MILLISECOND, 0)
                calendar.timeInMillis
            }
            "week" -> {
                calendar.set(Calendar.HOUR_OF_DAY, 0)
                calendar.set(Calendar.MINUTE, 0)
                calendar.set(Calendar.SECOND, 0)
                calendar.set(Calendar.MILLISECOND, 0)
                calendar.set(Calendar.DAY_OF_WEEK, calendar.firstDayOfWeek)
                calendar.timeInMillis
            }
            "month" -> {
                calendar.set(Calendar.HOUR_OF_DAY, 0)
                calendar.set(Calendar.MINUTE, 0)
                calendar.set(Calendar.SECOND, 0)
                calendar.set(Calendar.MILLISECOND, 0)
                calendar.set(Calendar.DAY_OF_MONTH, 1)
                calendar.timeInMillis
            }
            "allTime" -> 0L
            else -> 0L
        }
    }

    private fun classify(rule: BudgetRule, used: Double, projected: Double): EvaluateResult {
        val limit = rule.amountUSD
        val projectedPercent = if (limit > 0) projected / limit else 0.0
        val usedPercent = if (limit > 0) used / limit else 0.0

        val behavior = BudgetBehavior.values().firstOrNull { it.value == rule.behavior }
            ?: BudgetBehavior.WARN_THEN_BLOCK

        return when (behavior) {
            BudgetBehavior.WARN_ONLY -> {
                if (projectedPercent >= 1.0 || projectedPercent >= warningThreshold) {
                    EvaluateResult(BudgetGateDecision.Kind.WARN, rule, used, limit, usedPercent)
                } else {
                    EvaluateResult(BudgetGateDecision.Kind.ALLOW, rule, used, limit, usedPercent)
                }
            }
            BudgetBehavior.WARN_THEN_BLOCK -> {
                if (projectedPercent >= 1.0) {
                    EvaluateResult(BudgetGateDecision.Kind.BLOCK, rule, used, limit, usedPercent)
                } else if (projectedPercent >= warningThreshold) {
                    EvaluateResult(BudgetGateDecision.Kind.WARN, rule, used, limit, usedPercent)
                } else {
                    EvaluateResult(BudgetGateDecision.Kind.ALLOW, rule, used, limit, usedPercent)
                }
            }
            BudgetBehavior.HARD_BLOCK -> {
                if (projectedPercent >= 1.0) {
                    EvaluateResult(BudgetGateDecision.Kind.BLOCK, rule, used, limit, usedPercent)
                } else {
                    EvaluateResult(BudgetGateDecision.Kind.ALLOW, rule, used, limit, usedPercent)
                }
            }
            BudgetBehavior.HARD_BLOCK_WITH_FALLBACK -> {
                if (projectedPercent >= 1.0) {
                    // Fallback logic not fully wired in v1, return BLOCK
                    EvaluateResult(BudgetGateDecision.Kind.BLOCK, rule, used, limit, usedPercent)
                } else if (projectedPercent >= warningThreshold) {
                    EvaluateResult(BudgetGateDecision.Kind.WARN, rule, used, limit, usedPercent)
                } else {
                    EvaluateResult(BudgetGateDecision.Kind.ALLOW, rule, used, limit, usedPercent)
                }
            }
        }
    }

    private fun priority(kind: BudgetGateDecision.Kind): Int {
        return when (kind) {
            BudgetGateDecision.Kind.ALLOW -> 0
            BudgetGateDecision.Kind.PAUSED -> 1
            BudgetGateDecision.Kind.WARN -> 2
            BudgetGateDecision.Kind.BLOCK -> 3
        }
    }
}
