package com.openburnbar.data.budget

import com.openburnbar.data.db.BudgetDatabaseAccess
import com.openburnbar.data.db.BudgetRuleEntity
import com.openburnbar.data.models.BudgetBillingMode
import com.openburnbar.data.models.BudgetCredentialIdentity
import com.openburnbar.data.models.BudgetGateDecision
import com.openburnbar.data.models.BudgetRule
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class BudgetGateTest {
    @Test
    fun testBillingModeParsing() {
        assertEquals(BudgetBillingMode.SUBSCRIPTION, BudgetBillingMode.forSecretPrefix("sk-ant-oat-123"))
        assertEquals(BudgetBillingMode.PER_USAGE, BudgetBillingMode.forSecretPrefix("sk-ant-api-123"))
        assertEquals(BudgetBillingMode.PER_USAGE, BudgetBillingMode.forSecretPrefix("sk-123"))
        assertEquals(BudgetBillingMode.UNKNOWN, BudgetBillingMode.forSecretPrefix("other-prefix"))
    }

    @Test
    fun testRuleDisplayLabels() {
        val globalRule = BudgetRule(scope = "global")
        assertEquals("All per-usage credentials", globalRule.displayLabel)

        val projectRule = BudgetRule(scope = "project", projectName = "My Awesome Project")
        assertEquals("My Awesome Project", projectRule.displayLabel)

        val credentialRule = BudgetRule(scope = "credential", providerID = "anthropic", accountID = "acc_id_123456789")
        assertEquals("anthropic · 456789", credentialRule.displayLabel)
    }

    @Test
    fun testSubscriptionExemption() = runBlocking {
        val dao = mockk<BudgetDatabaseAccess>()
        val gate = BudgetGate(dao)

        val subCredential =
            BudgetCredentialIdentity(
                providerID = "anthropic",
                slotID = "slot-1",
                displayLabel = "Claude Pro",
                billingMode = BudgetBillingMode.SUBSCRIPTION,
            )

        val result =
            gate.evaluate(
                credential = subCredential,
                estimatedCost = 1.0,
            )

        assertEquals(BudgetGateDecision.Kind.ALLOW, result.decision)
    }

    @Test
    fun testEnforcementClassification() = runBlocking {
        val dao = mockk<BudgetDatabaseAccess>()
        val gate = BudgetGate(dao, warningThreshold = 0.8)

        val credential =
            BudgetCredentialIdentity(
                providerID = "openai",
                slotID = "key-1",
                displayLabel = "OpenAI Pay-as-you-go",
                billingMode = BudgetBillingMode.PER_USAGE,
            )

        val ruleEntity =
            BudgetRuleEntity(
                id = "rule-1",
                scope = "global",
                amountUSD = 10.0,
                period = "month",
                behavior = "warnThenBlock",
                createdAt = System.currentTimeMillis(),
                updatedAt = System.currentTimeMillis(),
                isEnabled = true,
            )

        every { dao.getCredentialRules(any(), any()) } returns emptyList()
        every { dao.getProjectRules(any()) } returns emptyList()
        every { dao.getGlobalRules() } returns listOf(ruleEntity)

        // Scenario 1: Spend is low -> ALLOW
        every { dao.getGlobalSpend(any(), any()) } returns 2.0
        val resultAllow = gate.evaluate(credential, estimatedCost = 1.0)
        assertEquals(BudgetGateDecision.Kind.ALLOW, resultAllow.decision)

        // Scenario 2: Spend reaches warning zone -> WARN
        every { dao.getGlobalSpend(any(), any()) } returns 7.5
        val resultWarn = gate.evaluate(credential, estimatedCost = 1.0)
        assertEquals(BudgetGateDecision.Kind.WARN, resultWarn.decision)

        // Scenario 3: Spend exceeds limit -> BLOCK
        every { dao.getGlobalSpend(any(), any()) } returns 9.5
        val resultBlock = gate.evaluate(credential, estimatedCost = 1.0)
        assertEquals(BudgetGateDecision.Kind.BLOCK, resultBlock.decision)
    }
}
