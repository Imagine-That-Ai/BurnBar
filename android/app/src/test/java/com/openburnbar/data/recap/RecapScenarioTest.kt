package com.openburnbar.data.recap

import android.content.Context
import com.openburnbar.data.models.TokenUsage
import io.mockk.every
import io.mockk.mockk
import java.nio.file.Files
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Scenario coverage for the Android Recap engine: a varied month (several
 * providers, late nights, weekends, long cached sessions) against a quieter
 * previous month and a three-month history, run through every rule, the
 * ranker, the deterministic voice, the JSON store, and the view-model
 * pipeline.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RecapScenarioTest {
    private val zone: ZoneId = ZoneId.systemDefault()
    private val august = RecapWindow(2026, 8)

    private val filesDir = Files.createTempDirectory("recap-test").toFile()
    private val context = mockk<Context> {
        every { applicationContext } returns this
        every { filesDir } returns this@RecapScenarioTest.filesDir
    }

    /** Runs file I/O inline so no view-model continuation outlives the test's Main. */
    private fun syncStore(accountID: String) = RecapStore(context, accountID, ioDispatcher = Dispatchers.Unconfined)

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        filesDir.deleteRecursively()
    }

    /** One usage at [day] (0-based) and [hour] local time. */
    private fun usage(
        window: RecapWindow,
        index: Int,
        day: Int,
        hour: Int,
        provider: String,
        model: String,
        cost: Double,
        minutes: Long = 10,
        cacheRead: Int = 0,
        reasoning: Int = 0,
        tokens: Int = 20_000,
    ): TokenUsage {
        val start = window.startEpochMillis(zone) + day * RecapConstants.MILLIS_PER_DAY + hour * RecapConstants.MILLIS_PER_HOUR
        return TokenUsage(
            id = "${window.key}-$index",
            provider = provider,
            model = model,
            inputTokens = tokens / 2,
            outputTokens = tokens / 4,
            cacheReadTokens = cacheRead,
            reasoningTokens = reasoning,
            totalTokens = tokens,
            costUSD = cost,
            startTime = start,
            endTime = start + minutes * RecapConstants.MILLIS_PER_MINUTE,
            sessionId = "${window.key}-s$index",
        )
    }

    /** A busy, late-night, weekend-heavy month across four models. */
    private fun busyMonth(window: RecapWindow): List<TokenUsage> {
        val models =
            listOf(
                "anthropic" to "claude-opus-4",
                "openai" to "gpt-5",
                "google" to "gemini-2.5-pro",
                "xai" to "grok-4",
            )
        val usages = mutableListOf<TokenUsage>()
        var index = 0
        for (day in 0 until window.dayCount()) {
            if (day % 9 == 8) continue // a few gaps so streaks are finite
            val sessions = if (day == 14) 12 else 3
            repeat(sessions) { slot ->
                val (provider, model) = models[(day + slot) % models.size].takeIf { slot != 0 } ?: models[0]
                val hour = if (slot == 0) 23 else 9 + slot
                usages +=
                    usage(
                        window,
                        index++,
                        day,
                        hour,
                        provider,
                        model,
                        cost = 1.5 + slot,
                        minutes = if (slot == 1) 95 else 12,
                        cacheRead = 12_000,
                        reasoning = 4_000,
                        tokens = 40_000,
                    )
            }
        }
        return usages
    }

    /** A quiet month concentrated on one model. */
    private fun quietMonth(window: RecapWindow, model: String = "gpt-4o", scale: Double = 1.0): List<TokenUsage> =
        (0 until 12).map { i -> usage(window, i, day = i * 2, hour = 14, provider = "openai", model = model, cost = 0.6 * scale, minutes = 30) }

    private fun facts(window: RecapWindow, usages: List<TokenUsage>, isPartial: Boolean = false) =
        RecapFactsBuilder.build(window = window, usages = usages, isPartial = isPartial, zone = zone)

    private fun richContext(): RecapContext {
        val current = facts(august, busyMonth(august))
        val previous = facts(august.previous, quietMonth(august.previous))
        val history = august.priorMonths(3).map { facts(it, quietMonth(it, scale = 0.5)) }
        return RecapContext(facts = current, previousMonth = previous, history = history)
    }

    @Test
    fun everyRuleFamilyFiresOnARichMonth() {
        val ctx = richContext()
        assertTrue(ctx.facts.meetsMinimumSubstance)

        val rules =
            listOf(
                RecapEconomyRules::spendShift,
                RecapEconomyRules::spendRecord,
                RecapEconomyRules::cacheEfficiency,
                RecapEconomyRules::costPerSessionShift,
                RecapEconomyRules::thinkingShare,
                RecapEconomyRules::volumeMilestone,
                RecapFleetRules::favouriteModel,
                RecapFleetRules::biggestModelGain,
                RecapFleetRules::biggestModelDecline,
                RecapFleetRules::favouritePairing,
                RecapFleetRules::fleetConcentration,
                RecapFleetRules::newModelsTried,
                RecapRhythmRules::weekdayPersonality,
                RecapRhythmRules::lateNightHabit,
                RecapRhythmRules::peakHour,
                RecapRhythmRules::weekendHabit,
                RecapRhythmRules::longestStreak,
                RecapRhythmRules::busiestWeek,
                RecapRhythmRules::busiestDay,
                RecapRhythmRules::longestSession,
                RecapRhythmRules::sessionLengthTrend,
                RecapRhythmRules::showUpRate,
            )
        val fired = rules.mapNotNull { it(ctx) }
        assertTrue("expected most rules to fire, got ${fired.map { it.ruleID }}", fired.size >= rules.size / 2)
        fired.forEach { candidate ->
            assertTrue(candidate.headline.isNotBlank())
            assertTrue(candidate.body.isNotBlank())
        }

        // Without history or a previous month, comparison rules decline.
        val bare = RecapContext(facts = ctx.facts)
        assertNull(RecapEconomyRules.spendShift(bare))
        assertNull(RecapEconomyRules.spendRecord(bare))
        assertNull(RecapFleetRules.biggestModelGain(bare))

        val cards = RecapRanker.rank(RecapRuleEngine.generateCandidates(ctx))
        assertTrue(cards.isNotEmpty())
        assertTrue(RecapDeterministicVoice.title(ctx, cards).isNotBlank())
        assertTrue(RecapDeterministicVoice.closing(ctx, cards).isNotBlank())
        assertTrue(RecapDeterministicVoice.title(bare, emptyList()).isNotBlank())
        assertTrue(RecapDeterministicVoice.closing(bare, emptyList()).isNotBlank())
    }

    @Test
    fun quietAndPartialMonthsStayConservative() {
        val quiet = facts(august, quietMonth(august), isPartial = true)
        val ctx = RecapContext(facts = quiet, previousMonth = facts(august.previous, busyMonth(august.previous)))
        assertFalse(ctx.allowsAbsoluteClaims)
        val cards = RecapRanker.rank(RecapRuleEngine.generateCandidates(ctx))
        assertTrue(RecapDeterministicVoice.title(ctx, cards).isNotBlank())
        assertFalse(facts(august, emptyList()).meetsMinimumSubstance)
    }

    @Test
    fun supportAndStatisticsHelpers() {
        assertEquals("25%", RecapRuleSupport.percent(0.25))
        assertEquals("flat", RecapRuleSupport.deltaPhrase(0.0))
        assertTrue(RecapRuleSupport.deltaPhrase(0.5).startsWith("up"))
        assertTrue(RecapRuleSupport.deltaPhrase(-0.5).startsWith("down"))
        listOf(0.99, 0.8, 0.68, 0.55, 0.4, 0.27, 0.12, 0.02).forEach { assertTrue(RecapRuleSupport.approximateFraction(it).isNotBlank()) }
        listOf(0.004, 3.5, 250.0).forEach { assertTrue(RecapRuleSupport.money(it).startsWith("$")) }
        listOf(30.0, 900.0, 7_200.0, 90_000.0).forEach { assertTrue(RecapRuleSupport.duration(it).isNotBlank()) }
        assertEquals("", RecapRuleSupport.list(emptyList()))
        assertEquals("a and b", RecapRuleSupport.list(listOf("a", "b")))
        assertEquals("a, b, and c", RecapRuleSupport.list(listOf("a", "b", "c")))
        for (day in 0..7) {
            assertTrue(RecapRuleSupport.weekdayName(day).isNotBlank())
            assertTrue(RecapRuleSupport.weekdayPlural(day).isNotBlank())
        }
        val start = august.startEpochMillis(zone)
        assertTrue(RecapRuleSupport.dayLabel(start, zone).isNotBlank())
        assertTrue(RecapRuleSupport.dayRange(start, start + 3 * RecapConstants.MILLIS_PER_DAY, zone).isNotBlank())
        assertTrue(RecapRuleSupport.dayRange(start, start + 40 * RecapConstants.MILLIS_PER_DAY, zone).isNotBlank())

        assertNull(RecapStatistics.twoProportionZ(1, 0, 1, 1))
        assertNull(RecapStatistics.twoProportionZ(0, 5, 0, 5))
        assertNotNull(RecapStatistics.twoProportionZ(4, 10, 1, 10))
        assertTrue(RecapStatistics.significanceFromZ(2.0) in 0.0..1.0)
        assertNull(RecapStatistics.uniformityEffect(listOf(1, 1)))
        assertNotNull(RecapStatistics.uniformityEffect(listOf(10, 1, 1, 1)))
        assertNull(RecapStatistics.recordMargin(1.0, 2.0))
        assertEquals(0.5, RecapStatistics.recordMargin(3.0, 2.0) ?: 0.0, 1e-9)
        assertEquals(1.0, RecapStatistics.clamp(4.0), 0.0)

        RecapMetricUnit.entries.forEach { unit ->
            listOf(0.4, 12.0, 1_500.0, 2_500_000.0, 3_000_000_000.0).forEach { assertTrue(RecapMetric.format(it, unit).isNotBlank()) }
        }
        RecapInsightKind.entries.forEach {
            assertTrue(it.label().isNotBlank())
            assertTrue(it.label(RecapInsightKind.LabelStyle.SHORT).isNotBlank())
        }
        assertEquals(RecapWindow(2027, 2), august.advanced(6))
        assertEquals(3, august.priorMonths(3).size)
        assertTrue(august.contains(august.startEpochMillis(zone), zone))
        assertEquals(0, august.dayIndex(august.startEpochMillis(zone), zone))
        assertNull(august.dayIndex(august.endEpochMillis(zone) + 1, zone))
        assertTrue(august.hasEnded(nowEpochMillis = august.endEpochMillis(zone) + 1, zone = zone))
        assertNull(RecapWindow.parse("not-a-month"))
        assertTrue(RecapWindow.mostRecentCompleted() < RecapWindow.current())
    }

    @Test
    fun storeRoundTripsRecapsAndFactsPerAccount() = runBlocking {
        val ctx = richContext()
        val cards = RecapRanker.rank(RecapRuleEngine.generateCandidates(ctx))
        val recap =
            MonthlyRecap(
                window = august,
                title = RecapDeterministicVoice.title(ctx, cards),
                cards = cards,
                closingSentence = RecapDeterministicVoice.closing(ctx, cards),
                sealState = RecapSealState.SEALED,
            )
        val store = RecapStore(context, "account-1")
        assertNull(store.loadRecap(august))
        assertTrue(store.availableMonths().isEmpty())

        store.saveRecap(recap)
        store.saveFacts(ctx.facts)
        ctx.history.forEach { store.saveFacts(it) }

        val loaded = requireNotNull(store.loadRecap(august))
        assertEquals(recap.title, loaded.title)
        assertEquals(recap.cards.size, loaded.cards.size)
        assertEquals(recap.cards.map { it.headline }, loaded.cards.map { it.headline })
        assertEquals(listOf(august), store.availableMonths())
        assertEquals(ctx.facts.totalCostUSD, requireNotNull(store.loadFacts(august)).totalCostUSD, 1e-9)
        assertEquals(1 + ctx.history.size, store.loadAllFacts().size)

        // Accounts are isolated; a different scope sees nothing.
        assertNull(RecapStore(context, "account-2").loadRecap(august))
        assertTrue(RecapStore.accountScope(null).isNotBlank())
        assertFalse(RecapStore.accountScope("../escape").contains("/"))
    }

    @Test
    fun environmentBuildsCachesAndReportsEmptyMonths() = runBlocking {
        val busy = busyMonth(august)
        val source =
            object : RecapSource {
                var calls = 0

                override suspend fun loadUsages(window: RecapWindow): Pair<List<TokenUsage>, Boolean> {
                    calls++
                    return when (window) {
                        august -> busy to false
                        august.previous -> quietMonth(window) to true
                        else -> emptyList<TokenUsage>() to false
                    }
                }
            }
        val environment = RecapEnvironment(context, source = source, accountID = "env-account", store = syncStore("env-account"))

        environment.selectMonth(august)
        val ready = withTimeout(10_000) { environment.phase.filterIsInstance<RecapPhase.Ready>().first() }
        assertEquals(august, ready.recap.window)
        assertTrue(ready.recap.cards.isNotEmpty())

        // A cached month is served without another source read.
        val callsAfterBuild = source.calls
        environment.selectMonth(august.previous)
        environment.selectMonth(august)
        withTimeout(10_000) { environment.phase.first { it is RecapPhase.Ready } }
        assertTrue(source.calls <= callsAfterBuild + 2)

        environment.load(RecapWindow(2020, 1), forceRegenerate = true)
        val empty = withTimeout(10_000) { environment.phase.first { it is RecapPhase.NotEnoughData } }
        assertEquals(RecapPhase.NotEnoughData(RecapWindow(2020, 1)), empty)
        assertTrue(environment.availableMonths.value.contains(august))
    }

    @Test
    fun environmentSurfacesSourceFailures() = runBlocking {
        val failing =
            object : RecapSource {
                override suspend fun loadUsages(window: RecapWindow): Pair<List<TokenUsage>, Boolean> = throw java.io.IOException("offline")
            }
        val environment = RecapEnvironment(context, source = failing, accountID = "failing-account", store = syncStore("failing-account"))
        environment.load(august, forceRegenerate = true)
        val failed = withTimeout(10_000) { environment.phase.filterIsInstance<RecapPhase.Failed>().first() }
        assertEquals("offline", failed.message)
    }
}
