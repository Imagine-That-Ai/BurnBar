package com.openburnbar.data.insights.verdict

import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Android-side smoke tests for the Kotlin rule engine port.
 *
 * Phase B will replace these with a generated-schema round-trip suite
 * (`GeneratedInsightsModelsRoundTripTest`) that deserializes a Swift-
 * authored fixture and asserts byte-for-byte parity. For Phase A we
 * just verify the engine produces the same canonical shape Swift does.
 */
class RuleBasedVerdictEngineTest {

    private val engine = RuleBasedVerdictEngine()

    private fun isoDate(daysAgo: Int): String {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.add(Calendar.DAY_OF_YEAR, -daysAgo)
        val f = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        f.timeZone = TimeZone.getTimeZone("UTC")
        return f.format(cal.time)
    }

    private fun makeDigest(
        costUSD: Double = 4.12,
        sessionCount: Int = 3,
        cacheReadTokens: Long = 9100,
        inputTokens: Long = 900,
        dailyCount: Int = 30,
        anomalyZ: Double? = null
    ): InsightDigest {
        val daily = (0 until dailyCount).map { i ->
            InsightDigest.DailyPoint(
                day = isoDate(i),
                costUSD = 4.0,
                totalTokens = 8000,
                sessionCount = 2,
                perProvider = mapOf("anthropic" to 3.5)
            )
        }
        val anomalies = anomalyZ?.let {
            listOf(
                InsightDigest.PrecomputedAnomaly(
                    id = "anom-1",
                    occurredAt = isoDate(0),
                    label = "Cache drop on agentlens-mobile",
                    score = it,
                    detail = "Cache hit dropped 27 points"
                )
            )
        } ?: emptyList()
        return InsightDigest(
            contentHash = "h",
            generatedAt = isoDate(0),
            windowStart = isoDate(1),
            windowEnd = isoDate(0),
            rowCount = sessionCount,
            totals = InsightDigest.Totals(
                costUSD = costUSD,
                totalTokens = cacheReadTokens + inputTokens,
                inputTokens = inputTokens,
                outputTokens = 0, reasoningTokens = 0,
                cacheReadTokens = cacheReadTokens, cacheCreationTokens = 0,
                sessionCount = sessionCount
            ),
            providers = listOf(
                InsightDigest.ProviderSnapshot(
                    id = "anthropic",
                    displayName = "Claude Code",
                    costUSD = 3.5,
                    totalTokens = 8000,
                    sessionCount = 2,
                    topModels = listOf("claude-sonnet-4-6"),
                    topInferredTaskTitles = emptyList(),
                    topKeyTools = emptyList()
                )
            ),
            models = listOf(
                InsightDigest.ModelSnapshot(
                    id = "claude-sonnet-4-6",
                    providerID = "anthropic",
                    costUSD = 3.5,
                    totalTokens = 8000,
                    sessionCount = 2,
                    avgCostPerSession = 1.75,
                    cacheHitRate = 0.91,
                    topInferredTaskTitles = emptyList(),
                    topProjects = emptyList()
                )
            ),
            projects = emptyList(),
            devices = emptyList(),
            daily = daily,
            hourly = List(24) { 0 },
            useCaseHistogram = listOf(
                InsightDigest.UseCaseBin(id = "refactor", count = 5, costUSD = 1.5)
            ),
            agentFocusSignals = emptyList(),
            modelFocusSignals = emptyList(),
            quotaSnapshots = emptyList(),
            operatingActions = emptyList(),
            summaryRunsLog = emptyList(),
            anomalies = anomalies
        )
    }

    @Test
    fun producesExactlyThreeRingsInCanonicalOrder() {
        val v = engine.produce(digest = makeDigest(), window = VerdictWindow.today)
        assertEquals(3, v.rings.size)
        assertEquals(
            listOf(VerdictRing.Identity.spend, VerdictRing.Identity.cache, VerdictRing.Identity.sessions),
            v.rings.map { it.identity }
        )
    }

    @Test
    fun anomalyAtOrAboveZThresholdIsSurfaced() {
        val v = engine.produce(digest = makeDigest(anomalyZ = 2.5), window = VerdictWindow.today)
        assertNotNull(v.anomaly)
        assertEquals(2.5, v.anomaly!!.zScore, 0.0001)
        assertEquals(VerdictAcceptAction.Intent.investigate, v.anomaly!!.acceptAction?.intent)
    }

    @Test
    fun anomalyBelowZThresholdIsNotSurfaced() {
        val v = engine.produce(digest = makeDigest(anomalyZ = 1.5), window = VerdictWindow.today)
        assertNull(v.anomaly)
    }

    @Test
    fun bulletsAllHaveCitations() {
        val v = engine.produce(digest = makeDigest(), window = VerdictWindow.today)
        for (bullet in v.bullets) {
            assertFalse("uncited bullet: ${bullet.claim}", bullet.citations.isEmpty())
        }
    }

    @Test
    fun provenanceIsLocalRules() {
        val v = engine.produce(digest = makeDigest(), window = VerdictWindow.today)
        assertEquals("local-rules", v.provenance.providerKey)
        assertTrue(v.isRuleBased)
    }

    @Test
    fun headlineIncludesNumericTokenAndSpend() {
        val v = engine.produce(digest = makeDigest(costUSD = 12.34), window = VerdictWindow.today)
        assertTrue(v.headline.contains("12.34"))
    }

    @Test
    fun ringsAreIdenticalForSameDigest() {
        val d = makeDigest()
        val now = Date()
        val a = engine.produce(digest = d, window = VerdictWindow.today, now = now)
        val b = engine.produce(digest = d, window = VerdictWindow.today, now = now)
        assertEquals(a.rings, b.rings)
        assertEquals(a.keyNumbers, b.keyNumbers)
        assertEquals(a.headline, b.headline)
        // Note: contentHash compares semantic content with canonicalized
        // IDs; future Phase B test will assert byte-for-byte parity with
        // a Swift-authored fixture.
    }

    @Test
    fun isRenderableWhenAllInvariantsHold() {
        val v = engine.produce(digest = makeDigest(), window = VerdictWindow.today)
        assertTrue(v.isRenderable)
    }
}
