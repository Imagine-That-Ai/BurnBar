
package com.openburnbar.data.insights

import com.openburnbar.data.insights.services.InsightDigestBuildInput
import com.openburnbar.data.insights.services.InsightDigestBuilder
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioral coverage for [InsightDigestBuilder]: section caps and ordering,
 * the calendar-window intervals, the uniform hourly estimate, the progressive
 * byte-budget shrinking, the last-resort caps, and the content hash. Mirrors
 * the Swift InsightDigestBuilder guarantees (same 24 KB ceiling).
 */
class InsightDigestBuilderTest {
    @Test
    fun `build caps every section at its documented limit and orders snapshots by cost`() {
        val input =
            emptyInput().copy(
                providers = (1..15).map { provider(it, cost = it.toDouble()) },
                models = (1..20).map { model(it, cost = it.toDouble()) },
                quotaSnapshots = (1..20).map { quota(it) },
                modelBenchmarks = (1..40).map { benchmark("model-%02d".format(it), score = it / 100.0, rank = it) },
                daily = (1..100).map { dailyPoint(it) },
            )

        val digest = InsightDigestBuilder.build(input)

        assertEquals(12, digest.providers.size)
        assertEquals("provider-15", digest.providers.first().id)
        assertEquals("provider-04", digest.providers.last().id)
        assertEquals(16, digest.models.size)
        assertEquals("model-20", digest.models.first().id)
        assertEquals("model-05", digest.models.last().id)
        assertEquals(16, digest.quotaSnapshots.size)
        assertEquals("quota-01", digest.quotaSnapshots.first().id)
        assertEquals(36, digest.modelBenchmarks.size)
        assertEquals("model-40", digest.modelBenchmarks.first().modelID)
        assertEquals("model-05", digest.modelBenchmarks.last().modelID)
        assertEquals(90, digest.daily.size)
        assertEquals("day-011", digest.daily.first().day)
        assertEquals("day-100", digest.daily.last().day)
        assertTrue(digest.devices.isEmpty())
        assertTrue(digest.useCaseHistogram.isEmpty())
        assertTrue(digest.agentFocusSignals.isEmpty())
    }

    @Test
    fun `build orders benchmarks by score then rank then model id and drops signal-free rows`() {
        val input =
            emptyInput().copy(
                modelBenchmarks =
                listOf(
                    benchmark("zeta", score = 0.9, rank = 5),
                    benchmark("beta", score = 0.8, rank = 2),
                    benchmark("alpha", score = 0.9, rank = 1),
                    benchmark("alpha-twin", score = 0.8, rank = 2),
                    benchmark("rank-only", score = null, rank = 9, costSignal = 0.4),
                    benchmark("signal-free", score = null, rank = null),
                ),
            )

        val ids = InsightDigestBuilder.build(input).modelBenchmarks.map { it.modelID }

        assertEquals(listOf("alpha", "zeta", "alpha-twin", "beta", "rank-only"), ids)
    }

    @Test
    fun `build estimates hourly load as a uniform per-day session spread`() {
        val input =
            emptyInput().copy(
                daily =
                listOf(
                    dailyPoint(1, sessions = 48),
                    dailyPoint(2, sessions = 25),
                    dailyPoint(3, sessions = 23),
                ),
            )

        val digest = InsightDigestBuilder.build(input)

        // 48/24 + 25/24 + 23/24 = 2 + 1 + 0 sessions estimated for every hour bucket.
        assertEquals(24, digest.hourly.size)
        assertEquals(List(24) { 3 }, digest.hourly)
    }

    @Test
    fun `build window presets produce exact preset spans`() {
        assertEquals(Duration.ofDays(1), windowSpan(InsightTimeWindow.Today))
        assertEquals(Duration.ofHours(24), windowSpan(InsightTimeWindow.Last24h))
        assertEquals(Duration.ofDays(7), windowSpan(InsightTimeWindow.Last7d))
        assertEquals(Duration.ofDays(30), windowSpan(InsightTimeWindow.Last30d))
        assertEquals(Duration.ofDays(90), windowSpan(InsightTimeWindow.Last90d))
        assertEquals(Duration.ofDays(365), windowSpan(InsightTimeWindow.Last365d))
    }

    @Test
    fun `build passes custom windows through verbatim and anchors all-time at epoch`() {
        val custom =
            InsightDigestBuilder.build(
                emptyInput(InsightTimeWindow.Custom(start = "2026-01-01T00:00:00Z", end = "2026-02-01T00:00:00Z")),
            )
        assertEquals("2026-01-01T00:00:00Z", custom.windowStart)
        assertEquals("2026-02-01T00:00:00Z", custom.windowEnd)

        val allTime = InsightDigestBuilder.build(emptyInput(InsightTimeWindow.AllTime))
        assertEquals(Instant.EPOCH.toString(), allTime.windowStart)
    }

    @Test
    fun `build keeps the newest daily points when shrinking to the byte ceiling`() {
        val input =
            emptyInput().copy(
                providers = (1..12).map { provider(it, cost = it.toDouble()) },
                models = (1..16).map { model(it, cost = it.toDouble()) },
                quotaSnapshots = (1..16).map { quota(it) },
                modelBenchmarks = (1..20).map { benchmark("model-%02d".format(it), score = it / 100.0, rank = it) },
                anomalies = (1..10).map { anomaly(it) },
                daily = (1..90).map { heavyDailyPoint(it) },
            )

        val digest = InsightDigestBuilder.build(input)

        assertTrue(encodedBytes(digest) <= InsightDigest.MAX_ENCODED_BYTES)
        assertTrue("daily should shrink below the 90-day cap (got ${digest.daily.size})", digest.daily.size <= 60)
        // takeLast: the trimmed history is always the most recent suffix.
        val firstKeptDay = 91 - digest.daily.size
        val expectedDays = (firstKeptDay..90).map { "2026-%03d".format(it) }
        assertEquals(expectedDays, digest.daily.map { it.day })
        assertTrue(digest.providers.size <= 10)
        assertTrue(digest.models.size <= 12)
        assertTrue(digest.quotaSnapshots.size <= 12)
        assertEquals(18, digest.modelBenchmarks.size)
        assertEquals(6, digest.anomalies.size)
        // hourly is recomputed from the trimmed history: 24 sessions/day -> 1 per bucket per kept day.
        assertEquals(List(24) { digest.daily.size }, digest.hourly)
    }

    @Test
    fun `build falls back to last-resort caps when shrinking cannot satisfy the ceiling`() {
        // Projects survive every progressive shrink candidate, so an oversized
        // projects list forces the last-resort branch that empties them.
        val input =
            emptyInput().copy(
                providers = (1..12).map { provider(it, cost = it.toDouble()) },
                models = (1..16).map { model(it, cost = it.toDouble()) },
                projects = (1..400).map { project(it) },
                quotaSnapshots = (1..8).map { quota(it) },
                modelBenchmarks = (1..10).map { benchmark("model-%02d".format(it), score = it / 100.0, rank = it) },
                anomalies = (1..4).map { anomaly(it) },
                daily = (1..30).map { dailyPoint(it, sessions = 24) },
            )

        val digest = InsightDigestBuilder.build(input)

        assertTrue(encodedBytes(digest) <= InsightDigest.MAX_ENCODED_BYTES)
        assertTrue(digest.projects.isEmpty())
        assertTrue(digest.quotaSnapshots.isEmpty())
        assertTrue(digest.anomalies.isEmpty())
        assertEquals(listOf("provider-12", "provider-11", "provider-10"), digest.providers.map { it.id })
        assertEquals(3, digest.models.size)
        assertEquals((24..30).map { "day-%03d".format(it) }, digest.daily.map { it.day })
        assertEquals(6, digest.modelBenchmarks.size)
        assertEquals(List(24) { 7 }, digest.hourly)
    }

    @Test
    fun `build stamps a verifiable sha-256 content hash`() {
        val input =
            emptyInput().copy(
                totals = InsightDigest.Totals(costUSD = 5.0, sessionCount = 9),
                providers = listOf(provider(1, cost = 5.0)),
            )

        val digest = InsightDigestBuilder.build(input)

        assertEquals(9, digest.rowCount)
        assertTrue(digest.contentHash.matches(Regex("[0-9a-f]{64}")))
        val payload = Json.encodeToString(InsightDigest.serializer(), digest.copy(contentHash = ""))
        val expected =
            MessageDigest.getInstance("SHA-256")
                .digest(payload.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
        assertEquals(expected, digest.contentHash)
    }

    @Test
    fun `build of empty rollups yields a well-formed empty digest`() {
        val digest = InsightDigestBuilder.build(emptyInput())

        assertEquals(0, digest.rowCount)
        assertTrue(digest.providers.isEmpty())
        assertTrue(digest.models.isEmpty())
        assertTrue(digest.daily.isEmpty())
        assertEquals(List(24) { 0 }, digest.hourly)
        assertEquals(InsightTaxonomy.DEFAULT, digest.glossary)
        assertTrue(encodedBytes(digest) <= InsightDigest.MAX_ENCODED_BYTES)
    }

    private fun windowSpan(window: InsightTimeWindow): Duration {
        val digest = InsightDigestBuilder.build(emptyInput(window))
        return Duration.between(Instant.parse(digest.windowStart), Instant.parse(digest.windowEnd))
    }

    private fun encodedBytes(digest: InsightDigest): Int = Json.encodeToString(InsightDigest.serializer(), digest).toByteArray(Charsets.UTF_8).size

    private fun emptyInput(window: InsightTimeWindow = InsightTimeWindow.Last7d): InsightDigestBuildInput = InsightDigestBuildInput(
        filter = InsightFilter(window = window),
        totals = InsightDigest.Totals(),
        providers = emptyList(),
        models = emptyList(),
        projects = emptyList(),
        daily = emptyList(),
        quotaSnapshots = emptyList(),
    )

    private fun provider(index: Int, cost: Double): InsightDigest.ProviderSnapshot = InsightDigest.ProviderSnapshot(
        id = "provider-%02d".format(index),
        displayName = "Provider $index",
        costUSD = cost,
        totalTokens = 1_000L * index,
        sessionCount = index,
    )

    private fun model(index: Int, cost: Double): InsightDigest.ModelSnapshot = InsightDigest.ModelSnapshot(
        id = "model-%02d".format(index),
        providerID = "provider-01",
        costUSD = cost,
        totalTokens = 1_000L * index,
        sessionCount = index,
    )

    private fun project(index: Int): InsightDigest.ProjectSnapshot = InsightDigest.ProjectSnapshot(
        id = "project-%03d".format(index),
        displayName = "Project %03d with stable padding".format(index),
        costUSD = 1.0 + index,
        totalTokens = 10L * index,
        sessionCount = 1,
    )

    private fun dailyPoint(index: Int, sessions: Int = 0): InsightDigest.DailyPoint = InsightDigest.DailyPoint(
        day = "day-%03d".format(index),
        costUSD = index.toDouble(),
        totalTokens = 100L * index,
        sessionCount = sessions,
    )

    private fun heavyDailyPoint(index: Int): InsightDigest.DailyPoint = InsightDigest.DailyPoint(
        day = "2026-%03d".format(index),
        costUSD = 12.5 + index,
        totalTokens = 50_000L + index,
        sessionCount = 24,
        perProvider = (0 until 4).associate { "provider-%02d-padding-padding".format(it) to 100.0 + index + it },
    )

    private fun quota(index: Int): InsightDigest.QuotaSnapshotSummary = InsightDigest.QuotaSnapshotSummary(
        id = "quota-%02d".format(index),
        providerID = "provider-01",
        bucketName = "five-hour",
        used = index.toDouble(),
        limit = 100.0,
    )

    private fun benchmark(modelID: String, score: Double?, rank: Int?, costSignal: Double? = null): InsightDigest.ModelBenchmarkSummary =
        InsightDigest.ModelBenchmarkSummary(
            id = "bench-$modelID",
            source = "artificial_analysis",
            fetchedAt = "2026-06-01T00:00:00Z",
            modelID = modelID,
            taskCategory = "coding",
            score = score,
            rank = rank,
            costSignal = costSignal,
            freshness = "fresh",
        )

    private fun anomaly(index: Int): InsightDigest.PrecomputedAnomaly = InsightDigest.PrecomputedAnomaly(
        id = "anomaly-%02d".format(index),
        occurredAt = "2026-06-%02dT00:00:00Z".format(index % 28 + 1),
        label = "Spike $index",
        score = 0.5 + index / 100.0,
        detail = "Detail $index",
    )
}
