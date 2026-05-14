package com.openburnbar.ui.insights

import com.openburnbar.data.insights.InsightAnalysisPlatform
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-function coverage for `IntelligenceBriefFormatting`. These labels
 * show up on the Brief surface AND on the audit log, so test that they
 * stay byte-identical between the two read sites.
 */
class IntelligenceBriefFormattingTest {

    @Test
    fun `windowLabel covers every fixed window`() {
        assertEquals("Today", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.Today))
        assertEquals("Last 24 hours", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.Last24h))
        assertEquals("Last 7 days", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.Last7d))
        assertEquals("Last 30 days", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.Last30d))
        assertEquals("Last 90 days", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.Last90d))
        assertEquals("Last 365 days", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.Last365d))
        assertEquals("All time", IntelligenceBriefFormatting.windowLabel(InsightTimeWindow.AllTime))
    }

    @Test
    fun `windowLabel formats a custom window with an en dash`() {
        val custom = InsightTimeWindow.Custom(start = "2026-04-01", end = "2026-05-13")
        // Note: an EN DASH ("–", U+2013) — not a regular hyphen — so spend
        // ranges read editorially on the surface.
        assertEquals("2026-04-01 – 2026-05-13", IntelligenceBriefFormatting.windowLabel(custom))
    }

    @Test
    fun `budgetLabel rounds KB down with a floor of 1 and notes trimming`() {
        val tiny = InsightContextBudgetReport(
            encodedBytes = 200,
            estimatedPromptTokens = 50,
            includedDataSources = listOf("usage_rollups"),
        )
        assertEquals("~1 KB · ~50 tokens", IntelligenceBriefFormatting.budgetLabel(tiny))

        val normal = InsightContextBudgetReport(
            encodedBytes = 18 * 1024,
            estimatedPromptTokens = 4_200,
            includedDataSources = listOf("usage_rollups", "quota_snapshots"),
        )
        assertEquals("~18 KB · ~4200 tokens", IntelligenceBriefFormatting.budgetLabel(normal))

        val trimmed = InsightContextBudgetReport(
            encodedBytes = 32 * 1024,
            estimatedPromptTokens = 8_400,
            includedDataSources = listOf("usage_rollups"),
            truncatedDataSources = listOf("agent_sessions", "skill_docs"),
        )
        assertEquals(
            "~32 KB · ~8400 tokens · trimmed",
            IntelligenceBriefFormatting.budgetLabel(trimmed),
        )
    }

    @Test
    fun `tokenUsageLabel omits cost when null`() {
        val usage = InsightTokenUsage(
            providerKey = "anthropic",
            modelID = "claude-sonnet-4-6",
            inputTokens = 1_500,
            outputTokens = 500,
        )
        assertEquals("2000 tokens", IntelligenceBriefFormatting.tokenUsageLabel(usage, cost = null))
        assertEquals("2000 tokens · \$0.0184", IntelligenceBriefFormatting.tokenUsageLabel(usage, cost = 0.0184))
    }

    @Test
    fun `auditFooter trims hashes to 8 chars and degrades to a local label`() {
        val result = sampleResult(auditID = "abcdef0123456789", resultHash = "9f8e7d6c5b4a3210")
        assertEquals(
            "Audit abcdef01 · result 9f8e7d6c · Your API key",
            IntelligenceBriefFormatting.auditFooter(result),
        )

        val local = sampleResult(auditID = null, resultHash = "9f8e7d6c5b4a3210")
        assertTrue(IntelligenceBriefFormatting.auditFooter(local).startsWith("Local run · result"))
    }

    private fun sampleResult(auditID: String?, resultHash: String) = InsightAnalysisResult(
        requestID = "test",
        platform = InsightAnalysisPlatform.ANDROID,
        timeWindow = InsightTimeWindow.Last7d,
        executiveSummary = "summary",
        modelTag = InsightModelTag(
            providerKey = "anthropic",
            modelID = "claude-sonnet-4-6",
            displayName = "Claude Sonnet 4.6",
            egressTier = InsightEgressTier.USER_KEY,
        ),
        contextBudget = InsightContextBudgetReport(
            encodedBytes = 4_096,
            estimatedPromptTokens = 800,
            includedDataSources = listOf("usage_rollups"),
        ),
        findings = emptyList(),
        anomalies = emptyList(),
        recommendations = emptyList(),
        generatedWidgets = emptyList(),
        followUpQuestions = emptyList(),
        tokenUsage = null,
        estimatedCostUSD = null,
        auditID = auditID,
        resultHash = resultHash,
    )
}
