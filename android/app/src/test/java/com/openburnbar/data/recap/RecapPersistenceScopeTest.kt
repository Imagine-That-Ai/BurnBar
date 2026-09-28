package com.openburnbar.data.recap

import android.content.Context
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.openburnbar.data.models.TokenUsage
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import java.io.IOException
import java.nio.file.Files
import java.time.ZoneId
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * Review-fix coverage for the Recap data layer: cursor pagination and failure
 * semantics, full-fidelity persistence of facts and card visuals, the
 * preview/partial cache policy, and auth-scoped environments.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RecapPersistenceScopeTest {
    private val zone: ZoneId = ZoneId.systemDefault()
    private val august = RecapWindow(2026, 8)

    private val filesDir = Files.createTempDirectory("recap-scope-test").toFile()
    private val context = mockk<Context> {
        every { applicationContext } returns this
        every { filesDir } returns this@RecapPersistenceScopeTest.filesDir
    }

    private fun syncStore(accountID: String?) = RecapStore(context, accountID, ioDispatcher = Dispatchers.Unconfined)

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        filesDir.deleteRecursively()
    }

    private fun usage(window: RecapWindow, index: Int, model: String = "gpt-5", cost: Double = 1.0): TokenUsage {
        val start = window.startEpochMillis(zone) + (index % window.dayCount()) * RecapConstants.MILLIS_PER_DAY + 10 * RecapConstants.MILLIS_PER_HOUR
        return TokenUsage(
            id = "${window.key}-$index",
            provider = "openai",
            model = model,
            inputTokens = 5_000,
            outputTokens = 2_000,
            cacheReadTokens = 1_000,
            reasoningTokens = 500,
            totalTokens = 8_500,
            costUSD = cost,
            startTime = start,
            endTime = start + 20 * RecapConstants.MILLIS_PER_MINUTE,
            sessionId = "${window.key}-s$index",
        )
    }

    private fun month(window: RecapWindow, count: Int = 20) = (0 until count).map { usage(window, it, model = if (it % 3 == 0) "claude-opus-4" else "gpt-5") }

    // region Pagination (finding 1 + 2)

    private fun page(vararg ids: Int) = ids.map { usage(august, it) }

    @Test
    fun paginationFollowsCursorPastShortDecodedPages() = runBlocking {
        // Page 0 decoded short (malformed rows dropped) but the raw page was full,
        // so the repository still returned a cursor. Paging must continue.
        val pages = mapOf<Int?, Pair<List<TokenUsage>, Int?>>(
            null to (page(1) to 1),
            1 to (page(2, 3) to 2),
            2 to (page(4) to null),
        )
        val (usages, partial) = RecapPagination.collect<Int>(pageBudget = 10) { pages.getValue(it) }
        assertEquals(listOf(1, 2, 3, 4).map { "${august.key}-$it" }, usages.map { it.id })
        assertFalse(partial)
    }

    @Test
    fun paginationMarksPartialWhenBudgetRunsOut() = runBlocking {
        val (usages, partial) = RecapPagination.collect<Int>(pageBudget = 2) { cursor -> page((cursor ?: 0) + 1) to (cursor ?: 0) + 1 }
        assertEquals(2, usages.size)
        assertTrue(partial)
    }

    @Test
    fun paginationPropagatesFirstPageFailure() = runBlocking {
        try {
            RecapPagination.collect<Int>(pageBudget = 5) { throw IOException("offline") }
            fail("first-page failure must propagate")
        } catch (e: IOException) {
            assertEquals("offline", e.message)
        }
    }

    @Test
    fun paginationKeepsPartialResultOnLaterPageFailure() = runBlocking {
        val failures = listOf<Exception>(IOException("late"), IllegalStateException("late"), mockk<com.google.firebase.FirebaseException>())
        for (failure in failures) {
            val (usages, partial) =
                RecapPagination.collect<Int>(pageBudget = 5) { cursor -> if (cursor == null) page(1) to 1 else throw failure }
            assertEquals(1, usages.size)
            assertTrue(partial)
        }
    }

    @Test
    fun paginationRethrowsCancellationOnAnyPage() = runBlocking {
        for (failAt in listOf<Int?>(null, 1)) {
            try {
                RecapPagination.collect<Int>(pageBudget = 5) { cursor ->
                    if (cursor == failAt) throw CancellationException("cancelled")
                    page(1) to 1
                }
                fail("cancellation must propagate")
            } catch (e: CancellationException) {
                assertEquals("cancelled", e.message)
            }
        }
    }

    // endregion

    // region Session grouping (finding 7)

    @Test
    fun factsGroupUsageRowsBySession() {
        val base = august.startEpochMillis(zone) + 2 * RecapConstants.MILLIS_PER_DAY + 9 * RecapConstants.MILLIS_PER_HOUR
        val minute = RecapConstants.MILLIS_PER_MINUTE
        fun row(id: String, session: String?, model: String, startMin: Long, endMin: Long, cost: Double) = TokenUsage(
            id = id,
            provider = "openai",
            model = model,
            totalTokens = 1_000,
            costUSD = cost,
            startTime = base + startMin * minute,
            endTime = base + endMin * minute,
            sessionId = session,
        )
        val usages = listOf(
            // One 90-minute session split across three rows and two models.
            row("r1", "long", "gpt-5", 0, 10, 1.0),
            row("r2", "long", "gpt-5", 30, 40, 1.0),
            row("r3", "long", "o3", 80, 90, 2.0),
            // Two standalone rows without a session id, each its own session.
            row("r4", null, "gpt-5", 200, 205, 0.5),
            row("r5", "", "gpt-5", 300, 320, 0.5),
        )
        val facts = RecapFactsBuilder.build(window = august, usages = usages, zone = zone)

        assertEquals(3, facts.sessionCount)
        assertEquals(3, facts.sessionStats.count)
        assertEquals(3, facts.dailySessions.sum())
        assertEquals(3, facts.weekdaySessions.sum())
        val longest = requireNotNull(facts.longestSession)
        assertEquals("long", longest.sessionID)
        assertEquals(90 * 60.0, longest.durationSeconds, 1e-6)
        assertEquals(4.0, longest.costUSD, 1e-9)
        assertEquals(3_000L, longest.tokens)
        assertEquals(3, requireNotNull(facts.model("gpt-5")).sessions)
        assertEquals(1, requireNotNull(facts.model("o3")).sessions)
        assertEquals(3, requireNotNull(facts.provider("openai")).sessions)
        assertEquals(1.0, requireNotNull(facts.provider("openai")).sessionShare, 1e-9)
    }

    // endregion

    // region Persistence (finding 3 + 4)

    @Test
    fun factsRoundTripTheFullShape() {
        val facts = RecapFactsBuilder.build(window = august, usages = month(august, 40), isPartial = true, zone = zone)
        assertTrue(facts.models.isNotEmpty())
        assertTrue(facts.dailyCost.isNotEmpty())
        assertTrue(facts.sessionStats.count > 0)
        val withOptionals = facts.copy(tools = listOf(RecapCount("bash", 4, 0.5)), peakWeekday = 3, exactShare = Double.NaN)

        val encoded = RecapStoreCodec.serializeFacts(withOptionals)
        assertTrue(RecapFactsCodec.isCurrentFormat(encoded))
        val decoded = RecapStoreCodec.deserializeFacts(august, JSONObject(encoded.toString()))
        assertEquals(withOptionals.copy(exactShare = 0.0), decoded)
    }

    @Test
    fun legacyScalarFactsStillDecode() {
        val legacy = JSONObject()
            .put("window", august.key)
            .put("builtAt", 42L)
            .put("totalCostUSD", 12.5)
            .put("totalTokens", 9_000L)
            .put("sessionCount", 7)
            .put("activeDayCount", 5)
            .put("longestActiveStreak", 3)
            .put("cacheHitRate", 0.4)
            .put("modelConcentration", 0.9)
        assertFalse(RecapFactsCodec.isCurrentFormat(legacy))
        val decoded = requireNotNull(RecapStoreCodec.deserializeFacts(august, legacy))
        assertEquals(12.5, decoded.totalCostUSD, 0.0)
        assertEquals(7, decoded.sessionCount)
        assertEquals(august.dayCount(), decoded.dayCount)
        assertTrue(decoded.models.isEmpty())
        assertNull(decoded.longestSession)
        assertNull(decoded.peakHour)
        assertEquals(RecapSessionStats.EMPTY, decoded.sessionStats)
    }

    @Test
    fun reusableFactsRequireCurrentFormatAndASealedBuild() = runBlocking {
        val store = syncStore("reuse")
        assertNull(store.loadReusableFacts(august))

        val built = RecapFactsBuilder.build(window = august, usages = month(august), isPartial = false, zone = zone)
        store.saveFacts(built.copy(builtAtEpochMillis = august.endEpochMillis() - 1))
        assertNull("a mid-month snapshot is not final", store.loadReusableFacts(august))

        store.saveFacts(built.copy(builtAtEpochMillis = august.endEpochMillis() + 1))
        assertEquals(built.models, requireNotNull(store.loadReusableFacts(august)).models)

        // A legacy scalar-only entry is readable but never reused.
        val historyFile = filesDir.resolve("recap/${RecapStore.accountScope("reuse")}/history.json")
        val legacy = JSONObject().put("facts", JSONObject().put(august.key, JSONObject().put("builtAt", Long.MAX_VALUE).put("sessionCount", 3)))
        historyFile.writeText(legacy.toString())
        assertNotNull(store.loadFacts(august))
        assertNull(store.loadReusableFacts(august))
    }

    @Test
    fun cardsRoundTripEveryVisualDataVariant() {
        val variants = listOf(
            RecapVisualData.Series(listOf(1.0, 2.5, Double.NaN)),
            RecapVisualData.DualSeries(listOf(1.0, 2.0), listOf(0.5)),
            RecapVisualData.Ranked(listOf(RecapRankedEntry("a", "A", 3.0, 0.75, "seed"), RecapRankedEntry("b", "B", 1.0, 0.25))),
            RecapVisualData.Matrix(listOf(listOf(0.0, 1.0), listOf(2.0))),
            RecapVisualData.Rings(listOf(RecapRingValue("Cache", 0.6, "60%"))),
            RecapVisualData.Pair(before = 4.0, after = 9.5),
            RecapVisualData.Streak(listOf(true, false, true)),
        )
        variants.forEachIndexed { index, data ->
            val card = RecapCard(
                candidate = RecapCandidate(
                    id = "c$index",
                    ruleID = "rule",
                    family = "family",
                    kind = RecapInsightKind.TREND,
                    tone = RecapTone.CURIOUS,
                    headline = "h",
                    body = "b",
                    metrics = emptyList(),
                    visual = RecapVisual.SPARKLINE,
                    visualData = data,
                ),
                size = RecapCardSize.WIDE,
            )
            val decoded = requireNotNull(RecapStoreCodec.deserializeCard(JSONObject(RecapStoreCodec.serializeCard(card).toString()), index))
            val expected = if (data is RecapVisualData.Series) RecapVisualData.Series(listOf(1.0, 2.5, 0.0)) else data
            assertEquals(expected, decoded.visualData)
        }
        assertNull(RecapVisualDataCodec.decode(JSONObject().put("type", "hologram")))
        assertNull(RecapVisualDataCodec.decode(null))
    }

    // endregion

    // region Environment cache policy (finding 5) and account scope (finding 6)

    private class CountingSource(private val tag: String = "") : RecapSource {
        val windows = mutableListOf<RecapWindow>()

        override suspend fun loadUsages(window: RecapWindow): Pair<List<TokenUsage>, Boolean> {
            windows += window
            val model = if (tag.isEmpty()) "gpt-5" else "model-$tag"
            return (0 until 20).map { i ->
                val start = window.startEpochMillis() + (i % 3) * RecapConstants.MILLIS_PER_DAY + RecapConstants.MILLIS_PER_HOUR
                TokenUsage(
                    id = "$tag-${window.key}-$i",
                    provider = "openai",
                    model = model,
                    inputTokens = 4_000,
                    outputTokens = 1_000,
                    totalTokens = 5_000,
                    costUSD = 0.5,
                    startTime = start,
                    endTime = start + RecapConstants.MILLIS_PER_MINUTE,
                    sessionId = "$tag-s$i",
                )
            } to false
        }
    }

    private fun environment(
        sources: Map<String?, RecapSource>,
        initial: String?,
        accountIDs: Flow<String?> = flowOf(initial),
        requested: MutableList<String?> = mutableListOf(),
    ) = RecapEnvironment(
        sourceFactory = {
            requested += it
            sources.getValue(it)
        },
        storeFactory = ::syncStore,
        initialAccountID = initial,
        accountIDs = accountIDs,
    )

    private suspend fun RecapEnvironment.awaitReady(window: RecapWindow): MonthlyRecap =
        withTimeout(10_000) { phase.first { it is RecapPhase.Ready && it.recap.window == window } as RecapPhase.Ready }.recap

    private fun recap(window: RecapWindow, seal: RecapSealState, partial: Boolean = false) =
        MonthlyRecap(window = window, title = "cached ${window.key}", cards = emptyList(), closingSentence = "bye", isPartial = partial, sealState = seal)

    @Test
    fun previewAndPartialRecapsAreRebuiltWhileSealedOnesAreServedFromCache() = runBlocking {
        val current = RecapWindow.current()
        val completed = RecapWindow.mostRecentCompleted()
        val older = completed.previous
        val store = syncStore("cache")
        store.saveRecap(recap(current, RecapSealState.PREVIEW))
        store.saveRecap(recap(completed, RecapSealState.SEALED))
        store.saveRecap(recap(older, RecapSealState.SEALED, partial = true))

        val source = CountingSource()
        val env = environment(mapOf("cache" to source), "cache")
        assertEquals("cached ${completed.key}", env.awaitReady(completed).title)
        assertTrue("a sealed month is served without a read", source.windows.isEmpty())

        env.selectMonth(current)
        val rebuilt = env.awaitReady(current)
        assertEquals(RecapSealState.PREVIEW, rebuilt.sealState)
        assertTrue("the running month's preview is rebuilt", current in source.windows)
        assertTrue(rebuilt.title != "cached ${current.key}")

        env.selectMonth(older)
        assertTrue(env.awaitReady(older).title != "cached ${older.key}")
        assertTrue("a partial sealed month is re-read", older in source.windows)
    }

    @Test
    fun accountSwitchRescopesSourceAndStoreAndClearsTheShownRecap() = runBlocking {
        val completed = RecapWindow.mostRecentCompleted()
        syncStore("alice").saveRecap(recap(completed, RecapSealState.SEALED))
        val accounts = MutableStateFlow<String?>("alice")
        val requested = mutableListOf<String?>()
        val bobSource = CountingSource("bob")
        val sources = mapOf<String?, RecapSource>("alice" to CountingSource("alice"), "bob" to bobSource, null to CountingSource("local"))
        val env = environment(sources, "alice", accounts, requested)

        assertEquals("cached ${completed.key}", env.awaitReady(completed).title)
        assertTrue("alice's cached month needed no source", requested.isEmpty())

        accounts.value = "bob"
        val bobs = env.awaitReady(completed)
        assertTrue("bob never sees alice's cached recap", bobs.title != "cached ${completed.key}")
        assertEquals(listOf<String?>("bob"), requested)
        assertTrue(completed in bobSource.windows)
        assertNotNull(syncStore("bob").loadRecap(completed))
        assertEquals("cached ${completed.key}", requireNotNull(syncStore("alice").loadRecap(completed)).title)

        // Signing out drops to the local scope, which has nothing cached for alice or bob.
        accounts.value = null
        val local = env.awaitReady(completed)
        assertTrue(local.title != "cached ${completed.key}")
        assertEquals(listOf("bob", null), requested)
    }

    @Test
    fun firebaseAccountIDsFollowAuthStateAndUnregister() = runBlocking {
        val listener = slot<FirebaseAuth.AuthStateListener>()
        val auth = mockk<FirebaseAuth>(relaxed = true)
        every { auth.addAuthStateListener(capture(listener)) } returns Unit

        val received = mutableListOf<String?>()
        val job = launch(Dispatchers.Unconfined) { auth.accountIDs().take(2).toList(received) }
        val signedIn = mockk<FirebaseAuth> { every { currentUser } returns mockk<FirebaseUser> { every { uid } returns "uid-1" } }
        val signedOut = mockk<FirebaseAuth> { every { currentUser } returns null }
        listener.captured.onAuthStateChanged(signedIn)
        listener.captured.onAuthStateChanged(signedOut)
        job.join()

        assertEquals(listOf("uid-1", null), received)
        verify { auth.removeAuthStateListener(listener.captured) }
    }

    @Test
    fun contextConstructorScopesToTheSignedInUser() = runBlocking {
        val completed = RecapWindow.mostRecentCompleted()
        RecapStore(context, "ctor-uid").saveRecap(recap(completed, RecapSealState.SEALED))
        val auth = mockk<FirebaseAuth>(relaxed = true) {
            every { currentUser } returns mockk<FirebaseUser> { every { uid } returns "ctor-uid" }
        }
        val env = RecapEnvironment(context, auth)
        assertEquals("cached ${completed.key}", env.awaitReady(completed).title)
        verify { auth.addAuthStateListener(any()) }
    }

    // endregion
}
