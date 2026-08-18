package com.openburnbar.data.policy

import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.ui.pulse.PulseTimelineScope
import com.openburnbar.ui.pulse.livePulseUsageQueryStartMillis
import com.openburnbar.ui.pulse.pulseWindowMetrics
import java.io.File
import java.time.ZoneId
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shared product-surface vectors. Source oracle: iOS `PulseWindowMetricBuilder`.
 */
class MobileProductParityTest {
    @Test
    fun pulseMinuteHourDayWindows() {
        assertWindows(pulseVector("pulse.minute-hour-day-windows"))
    }

    @Test
    fun pulseWeekMonthRollupsIgnoreRaw() {
        assertWindows(pulseVector("pulse.week-month-rollups-ignore-raw"))
    }

    @Test
    fun pulseDayRolling24h() {
        assertWindows(pulseVector("pulse.day-rolling-24h"))
    }

    @Test
    fun pulseLiveQueryStartHourFloor() {
        val vector = pulseVector("pulse.live-query-start-hour-floor")
        val nowMs = vector.getLong("nowMs")
        val zone = vector.getString("timeZone")
        val start = MobilePulseWindowPolicy.liveQueryStartMs(nowMs, zone)
        assertEquals(vector.getJSONObject("expected").getLong("startMs"), start)
        assertEquals(start, livePulseUsageQueryStartMillis(nowMs, ZoneId.of(zone)))
        assertTrue(start <= nowMs - MobilePulseWindowPolicy.DAY_WINDOW_MS)
        assertTrue(start > nowMs - 25L * 60L * 60L * 1_000L)
    }

    @Test
    fun pulseNegativeCostTokensClamped() {
        assertWindows(pulseVector("pulse.negative-cost-tokens-clamped"))
    }

    @Test
    fun pulseEmptyWindow() {
        assertWindows(pulseVector("pulse.empty-window"))
    }

    @Test
    fun pulseEndTimeAdvancesRow() {
        assertWindows(pulseVector("pulse.end-time-advances-row"))
    }

    @Test
    fun pulseUpdatedAtIsNotLive() {
        assertWindows(pulseVector("pulse.updated-at-is-not-live"))
    }

    @Test
    fun pulseFailedLoadNotLiveZero() {
        assertLoad(pulseVector("pulse.failed-load-not-live-zero"))
    }

    @Test
    fun pulseEmptyLoadNotFailed() {
        assertLoad(pulseVector("pulse.empty-load-not-failed"))
    }

    @Test
    fun pulseStaleRefreshKeepsCache() {
        assertLoad(pulseVector("pulse.stale-refresh-keeps-cache"))
    }

    @Test
    fun pulseLiveZeroAfterEmptySuccess() {
        assertLoad(pulseVector("pulse.live-zero-after-empty-success"))
    }

    @Test
    fun pulseCurrencyVsTokens() {
        val vector = pulseVector("pulse.currency-vs-tokens")
        val expected = vector.getJSONObject("expected")
        assertEquals(expected.getString("currencyHero"), MobilePulseWindowPolicy.currencyHero(vector.getDouble("costUsd")))
        assertEquals(expected.getString("tokensHero"), MobilePulseWindowPolicy.tokensHero(vector.getLong("tokens")))
    }

    @Test
    fun burnQuotaGroupSort() {
        val vector = pulseVector("burn.quota-group-sort")
        val snapshots = vector.getJSONArray("snapshots")
        val keys = (0 until snapshots.length()).map { index ->
            val row = snapshots.getJSONObject(index)
            MobilePulseWindowPolicy.quotaDedupKey(
                row.getString("provider"),
                row.optString("accountId").takeIf { it.isNotEmpty() },
                row.optString("accountLabel").takeIf { it.isNotEmpty() },
            )
        }.toSet().toList()
        assertEquals(
            expectedStringList(vector.getJSONObject("expected").getJSONArray("keys")),
            MobilePulseWindowPolicy.sortQuotaKeys(keys),
        )
    }

    @Test
    fun streamsPaginationBoundary() {
        streamsVector("streams.pagination-boundary")
        val afterFirst = MobileStreamsListPolicy.pageOutcome(25, 25, 25, lastCursorPresent = true, failed = false)
        assertTrue(afterFirst.hasMore)
        val afterSecond = MobileStreamsListPolicy.pageOutcome(25, 0, 25, lastCursorPresent = false, failed = false)
        assertEquals(25, afterSecond.rowCount)
        assertFalse(afterSecond.hasMore)
        assertFalse(afterSecond.canLoadNext)
    }

    @Test
    fun streamsEmptyResults() {
        assertList(streamsVector("streams.empty-results"))
    }

    @Test
    fun streamsLoadError() {
        assertList(streamsVector("streams.load-error"))
    }

    @Test
    fun streamsEntitlementLock() {
        assertList(streamsVector("streams.entitlement-lock"))
    }

    @Test
    fun streamsSearchErrorNotEmpty() {
        assertList(streamsVector("streams.search-error-not-empty"))
    }

    @Test
    fun streamsRetryAfterError() {
        streamsVector("streams.retry-after-error")
        assertEquals(
            MobileStreamsListPresentation.FAILED,
            MobileStreamsListPolicy.pageOutcome(0, 0, 25, lastCursorPresent = false, failed = true).presentation,
        )
        val recovered = MobileStreamsListPolicy.pageOutcome(3, 3, 25, lastCursorPresent = false, failed = false)
        assertEquals(MobileStreamsListPresentation.READY, recovered.presentation)
        assertEquals(3, recovered.rowCount)
    }

    @Test
    fun inboxColdFocusHold() {
        val vector = streamsVector("inbox.cold-focus-hold")
        var state = MobileInboxSelectionState(
            selectedID = vector.optString("selectedId"),
            pendingFocusID = vector.optNullable("pendingFocusId"),
            filter = vector.getString("filter"),
            searchQuery = vector.getString("searchQuery"),
        )
        state = MobileInboxSelectionPolicy.focus(
            state,
            vector.getString("focusItemId"),
            expectedStringList(vector.getJSONArray("recordIds")),
        )
        val afterFocus = vector.getJSONObject("expectedAfterFocus")
        assertEquals(afterFocus.getString("selectedId"), state.selectedID)
        assertEquals(afterFocus.getString("pendingFocusId"), state.pendingFocusID)
        assertEquals(afterFocus.getString("filter"), state.filter)
        assertEquals(afterFocus.getString("searchQuery"), state.searchQuery)
        assertEquals(afterFocus.getInt("focusTokenDelta"), state.focusRequestToken)

        state = MobileInboxSelectionPolicy.reconcile(
            state,
            expectedStringList(vector.getJSONArray("interveningVisibleIds")),
            expectedStringList(vector.getJSONArray("interveningRecordIds")),
        )
        val afterIntervening = vector.getJSONObject("expectedAfterIntervening")
        assertEquals(afterIntervening.getString("selectedId"), state.selectedID)
        assertEquals(afterIntervening.getString("pendingFocusId"), state.pendingFocusID)

        state = MobileInboxSelectionPolicy.reconcile(
            state,
            expectedStringList(vector.getJSONArray("landedVisibleIds")),
            expectedStringList(vector.getJSONArray("landedRecordIds")),
        )
        val afterLanded = vector.getJSONObject("expectedAfterLanded")
        assertEquals(afterLanded.getString("selectedId"), state.selectedID)
        assertNull(state.pendingFocusID)
    }

    @Test
    fun inboxWarmFocusRepeat() {
        val vector = streamsVector("inbox.warm-focus-repeat")
        var state = MobileInboxSelectionState(filter = vector.getString("filter"))
        val itemId = vector.getString("focusItemId")
        val records = expectedStringList(vector.getJSONArray("recordIds"))
        state = MobileInboxSelectionPolicy.focus(state, itemId, records)
        state = MobileInboxSelectionPolicy.focus(state, itemId, records)
        val expected = vector.getJSONObject("expectedAfterFocus")
        assertEquals(expected.getString("selectedId"), state.selectedID)
        assertNull(state.pendingFocusID)
        assertEquals(expected.getInt("focusTokenDelta"), state.focusRequestToken)
    }

    @Test
    fun surfaceCardActionsRealOrRemoved() {
        val vector = streamsVector("surface.card-actions-real-or-removed")
        val actions = vector.getJSONArray("actions")
        for (index in 0 until actions.length()) {
            val row = actions.getJSONObject(index)
            val catalog = if (row.has("catalogPresent")) row.getBoolean("catalogPresent") else true
            val actual = MobileProductSurfacePolicy.disposition(row.getString("id"), catalogPresent = catalog)
            assertEquals(row.getString("id"), row.getString("expected"), actual.wire)
        }
    }

    @Test
    fun surfaceBudgetEntitlementGate() {
        val vector = streamsVector("surface.budget-entitlement-gate")
        val state = classify(vector)
        assertEquals(vector.getJSONObject("expected").getString("state"), state.wire)
        assertTrue(MobileProductSurfacePolicy.mayEnforceBudget(state))
    }

    @Test
    fun surfaceBudgetExpiredBlocks() {
        val vector = streamsVector("surface.budget-expired-blocks")
        val state = classify(vector)
        assertEquals(MobileStoreEntitlementState.EXPIRED, state)
        assertFalse(MobileProductSurfacePolicy.mayEnforceBudget(state))
    }

    private fun classify(vector: JSONObject): MobileStoreEntitlementState = MobileStoreEntitlementPolicy.classify(
        catalogPresent = vector.getBoolean("catalogPresent"),
        restoring = vector.getBoolean("restoring"),
        revoked = vector.getBoolean("revoked"),
        refunded = vector.getBoolean("refunded"),
        expired = vector.getBoolean("expired"),
        active = vector.getBoolean("active"),
    )

    private fun assertWindows(vector: JSONObject) {
        val nowMs = vector.getLong("nowMs")
        val usages = parseUsages(vector.optJSONArray("usages") ?: JSONArray())
        val rollups = parseRollups(vector.optJSONObject("rollups") ?: JSONObject())
        val expected = vector.getJSONObject("expected")
        val keys = expected.keys()
        while (keys.hasNext()) {
            val scopeName = keys.next()
            val want = expected.getJSONObject(scopeName)
            val policy = MobilePulseWindowPolicy.metrics(scopeName.toScope(), rollups.toPolicyMap(), usages, nowMs)
            assertEquals(scopeName, want.getInt("requests"), policy.total.requests)
            assertEquals(scopeName, want.getLong("tokens"), policy.total.tokens)
            assertEquals(want.getDouble("costUsd"), policy.total.costUsd, 0.001)
            val android = pulseWindowMetrics(scopeName.toTimeline(), rollups, usages.toTokenUsages(), nowMs)
            assertEquals(want.getDouble("costUsd"), android.value, 0.001)
            assertEquals(want.getInt("tokens").toLong(), android.tokenValue)
            assertEquals(want.getInt("requests"), android.requestValue)
        }
    }

    private fun assertLoad(vector: JSONObject) {
        val got = MobilePulseWindowPolicy.loadPresentation(
            isLoading = vector.getBoolean("isLoading"),
            failed = vector.getBoolean("failed"),
            hasCachedData = vector.getBoolean("hasCachedData"),
        )
        val expected = vector.getJSONObject("expected")
        assertEquals(expected.getString("presentation"), got.wire)
        assertEquals(expected.getBoolean("looksLikeLiveZero"), got.looksLikeLiveZero)
    }

    private fun assertList(vector: JSONObject) {
        val got = MobileStreamsListPolicy.presentation(
            isLoading = vector.getBoolean("isLoading"),
            failed = vector.getBoolean("failed"),
            isEmpty = vector.getBoolean("isEmpty"),
            entitled = vector.getBoolean("entitled"),
            hasMore = vector.getBoolean("hasMore"),
            isPaginating = vector.getBoolean("isPaginating"),
            searchFailed = vector.getBoolean("searchFailed"),
        )
        assertEquals(vector.getJSONObject("expected").getString("presentation"), got.wire)
    }

    private fun parseUsages(rows: JSONArray): List<MobilePulseUsageEvent> = (0 until rows.length()).map { index ->
        val row = rows.getJSONObject(index)
        MobilePulseUsageEvent(
            startMs = row.getLong("startMs"),
            endMs = row.getLong("endMs"),
            tokens = row.getLong("tokens"),
            costUsd = row.getDouble("costUsd"),
        )
    }

    private fun parseRollups(raw: JSONObject): UsageRollups {
        fun totals(key: String): Triple<Int, Long, Double> {
            if (!raw.has(key)) return Triple(0, 0L, 0.0)
            val item = raw.getJSONObject(key)
            return Triple(item.optInt("requests"), item.optLong("tokens"), item.optDouble("costUsd"))
        }
        val today = totals("today")
        val week = totals("7d")
        val month = totals("30d")
        val ninety = totals("90d")
        return UsageRollups(
            today = today.third,
            sevenDays = week.third,
            thirtyDays = month.third,
            ninetyDays = ninety.third,
            todayTokens = today.second,
            sevenDayTokens = week.second,
            thirtyDayTokens = month.second,
            ninetyDayTokens = ninety.second,
            todayRequests = today.first,
            sevenDayRequests = week.first,
            thirtyDayRequests = month.first,
            ninetyDayRequests = ninety.first,
        )
    }

    private fun UsageRollups.toPolicyMap(): Map<String, MobilePulseRollupTotals> = mapOf(
        "today" to MobilePulseRollupTotals(todayRequests, todayTokens, today),
        "7d" to MobilePulseRollupTotals(sevenDayRequests, sevenDayTokens, sevenDays),
        "30d" to MobilePulseRollupTotals(thirtyDayRequests, thirtyDayTokens, thirtyDays),
        "90d" to MobilePulseRollupTotals(ninetyDayRequests, ninetyDayTokens, ninetyDays),
    )

    private fun List<MobilePulseUsageEvent>.toTokenUsages(): List<TokenUsage> = mapIndexed { index, event ->
        TokenUsage(
            id = "row-$index",
            costUsd = event.costUsd,
            totalTokens = event.tokens.toInt(),
            startTime = event.startMs,
            endTime = event.endMs,
        )
    }

    private fun String.toScope(): MobilePulseTimelineScope = when (this) {
        "minute" -> MobilePulseTimelineScope.MINUTE
        "hour" -> MobilePulseTimelineScope.HOUR
        "day" -> MobilePulseTimelineScope.DAY
        "week" -> MobilePulseTimelineScope.WEEK
        "month" -> MobilePulseTimelineScope.MONTH
        else -> error("unknown scope $this")
    }

    private fun String.toTimeline(): PulseTimelineScope = when (this) {
        "minute" -> PulseTimelineScope.MINUTE
        "hour" -> PulseTimelineScope.HOUR
        "day" -> PulseTimelineScope.DAY
        "week" -> PulseTimelineScope.WEEK
        "month" -> PulseTimelineScope.MONTH
        else -> error("unknown scope $this")
    }

    private fun pulseVector(id: String): JSONObject = vector(id, "docs/mobile-parity/fixtures/product/pulse-burn-vectors.json")

    private fun streamsVector(id: String): JSONObject = vector(id, "docs/mobile-parity/fixtures/product/streams-inbox-vectors.json")

    private fun vector(id: String, relative: String): JSONObject {
        val fixture = JSONObject(locate(relative).readText())
        val vectors = fixture.getJSONArray("vectors")
        for (index in 0 until vectors.length()) {
            val candidate = vectors.getJSONObject(index)
            if (candidate.getString("id") == id) return candidate
        }
        error("missing vector $id")
    }

    private fun locate(relative: String): File {
        val cwd = System.getProperty("user.dir").orEmpty().ifBlank { "." }
        val anchors = listOf(
            File(cwd),
            File(cwd, "../.."),
            File(cwd, ".."),
        )
        for (anchor in anchors) {
            var dir: File? = anchor.absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        error("could not locate $relative")
    }

    private fun expectedStringList(array: JSONArray): List<String> = (0 until array.length()).map { array.getString(it) }

    private fun JSONObject.optNullable(key: String): String? {
        if (!has(key) || isNull(key)) return null
        val value = optString(key, "")
        return value.ifBlank { null }
    }
}
