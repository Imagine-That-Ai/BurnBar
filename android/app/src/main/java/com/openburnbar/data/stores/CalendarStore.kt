package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.openburnbar.data.firebase.FirestoreRepository
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

// MARK: - Calendar Month Snapshot
//
// Everything the month grid needs to draw: per-day cost (drives the heatmap
// fill) and the day's top providers (drives the dots). Days are keyed by
// local start-of-day — sessions spanning midnight are attributed to the day
// their `startTime` lands in, never split and never UTC-truncated. Mirrors the
// macOS `CalendarMonthSnapshot`.

data class CalendarMonthSnapshot(
    val month: YearMonth,
    /** Total cost per local day. Only days with usage appear; cells treat a
     *  missing key as zero. */
    val dayCosts: Map<LocalDate, Double> = emptyMap(),
    /** Up to three providers per day, ranked by that day's cost. */
    val dayProviders: Map<LocalDate, List<AgentProvider>> = emptyMap(),
    /** The visible month's busiest day cost — the denominator for heatmap
     *  intensity. */
    val peakDayCost: Double = 0.0,
    /** Spend on days inside the calendar month itself, for the header
     *  subtitle. */
    val monthTotalCost: Double = 0.0,
) {
    fun heat(day: LocalDate): Float {
        val cost = dayCosts[day] ?: return 0f
        if (peakDayCost <= 0.0) return 0f
        return (cost / peakDayCost).coerceIn(0.0, 1.0).toFloat()
    }
}

// MARK: - Calendar Selection Snapshot
//
// Every analytics card's prepared data for the current day selection. Built
// by [CalendarAggregation.buildSelection] from the already-loaded usage
// events; cards render with zero aggregation of their own. Mirrors the macOS
// `CalendarSelectionSnapshot`.

data class CalendarDayCost(val day: LocalDate, val cost: Double)

data class CalendarProviderShare(
    /** Resolved provider, or null when the key matches no known brand (the
     *  raw [key] still renders as the label). */
    val provider: AgentProvider?,
    val key: String,
    val displayName: String,
    val cost: Double,
)

data class CalendarModelCost(
    /** Raw model key (feeds `ModelLogo`). */
    val model: String,
    val cost: Double,
)

data class CalendarProjectCost(val name: String, val cost: Double)

data class CalendarSelectionSnapshot(
    /** Selected days, ascending. */
    val selectedDays: List<LocalDate> = emptyList(),
    /** True when no usage rows land on any selected day. */
    val isEmpty: Boolean = true,
    // KPI tiles
    val totalCost: Double = 0.0,
    val totalTokens: Long = 0,
    /** Distinct non-blank `sessionId` count across the selection. */
    val sessionCount: Int = 0,
    /** Selected days that carry at least one usage row. */
    val activeDays: Int = 0,
    /** Total cost averaged over every selected day (silent days included). */
    val averageCostPerDay: Double = 0.0,
    // burnOverSelection — per-day cost across the selection's span, gap-filled
    val dailyBurn: List<CalendarDayCost> = emptyList(),
    // providerMix / modelMix / projectFocus
    val providerShares: List<CalendarProviderShare> = emptyList(),
    val topModels: List<CalendarModelCost> = emptyList(),
    val projectShares: List<CalendarProjectCost> = emptyList(),
    // hourOfDayHeatmap — 7×24 cost matrix; row 0 = Sunday
    val hourWeekdayCost: List<List<Double>> = List(WEEKDAYS) { List(HOURS_PER_DAY) { 0.0 } },
    val peakWeekdayIndex: Int? = null,
    val peakHour: Int? = null,
    // cacheROI / reasoningShare
    val cacheHitRate: Double = 0.0,
    val cacheReadTokens: Long = 0,
    /** Cache reads billed at ~10% of the blended per-token rate — the same
     *  estimate the macOS Charts surface publishes. Labeled "(est.)" in UI. */
    val cacheSavingsEstimate: Double = 0.0,
    val reasoningShare: Double = 0.0,
    val reasoningTokens: Long = 0,
) {
    companion object {
        const val WEEKDAYS = 7
        const val HOURS_PER_DAY = 24
    }
}

// MARK: - Aggregation

/**
 * Pure builders behind [CalendarStore] — extracted so the bucketing math
 * (local-tz day attribution, gap fill, month boundaries) is unit-testable
 * without a ViewModel or Firestore. Mirrors the macOS `CalendarDataService`
 * `build` functions.
 */
object CalendarAggregation {

    /** Local calendar day for an epoch-millis instant in [zoneId]. */
    fun localDay(epochMillis: Long, zoneId: ZoneId): LocalDate = Instant.ofEpochMilli(epochMillis).atZone(zoneId).toLocalDate()

    /** The attribution instant for a usage row: `startTime` is the canonical
     *  session-start field; legacy rows that only carry `timestamp` fall back
     *  to it. Cross-midnight sessions land on the day they STARTED. */
    fun effectiveStartMillis(usage: TokenUsage): Long = if (usage.startTime > 0L) usage.startTime else usage.timestamp

    /** Every day from [first] to [last] inclusive (ascending; [first] must
     *  not be after [last]). Silent days stay in the list so charts draw
     *  zero-height bars instead of collapsing. */
    fun gapFilledDays(first: LocalDate, last: LocalDate): List<LocalDate> {
        if (first.isAfter(last)) return emptyList()
        val days = mutableListOf<LocalDate>()
        var cursor = first
        while (!cursor.isAfter(last)) {
            days.add(cursor)
            cursor = cursor.plusDays(1)
        }
        return days
    }

    /**
     * Month heat, computed from the loaded events alone — cost, bucketed by
     * local start-of-day, exactly like the macOS oracle.
     *
     * Server `dailyPoints` deliberately does NOT seed this map. That series is
     * `[day, tokens]` keyed by a UTC date (`rollupCompute.buildWindowRollupDoc`
     * / `rollupCounters.toUtcDate`), so mixing it into a USD map both changes
     * units — token counts dwarf dollar costs, so any `max(server, computed)`
     * rule silently resolves to the token count — and reintroduces the UTC day
     * attribution this feature forbids. A month with no loaded events reads as
     * empty rather than wrong.
     */
    fun buildMonth(events: List<TokenUsage>, month: YearMonth, zoneId: ZoneId): CalendarMonthSnapshot {
        val dayCosts = mutableMapOf<LocalDate, Double>()
        val providerCosts = mutableMapOf<LocalDate, MutableMap<AgentProvider, Double>>()
        events.forEach { event ->
            val cost = event.effectiveCost
            if (cost > 0.0) {
                val day = localDay(effectiveStartMillis(event), zoneId)
                dayCosts[day] = (dayCosts[day] ?: 0.0) + cost
                AgentProvider.fromKey(event.providerId ?: event.provider)?.let { provider ->
                    providerCosts.getOrPut(day) { mutableMapOf() }
                        .merge(provider, cost) { a, b -> a + b }
                }
            }
        }

        val dayProviders =
            providerCosts.mapValues { (_, costs) ->
                costs.entries
                    .sortedWith(
                        compareByDescending<Map.Entry<AgentProvider, Double>> { it.value }
                            .thenBy { it.key.key },
                    )
                    .take(TOP_PROVIDERS_PER_DAY)
                    .map { it.key }
            }

        val inMonth = dayCosts.filterKeys { YearMonth.from(it) == month }
        return CalendarMonthSnapshot(
            month = month,
            dayCosts = dayCosts,
            dayProviders = dayProviders,
            // Peak spans the whole loaded grid — including leading/trailing
            // overflow cells, which paint too (CalendarDataService.swift:71).
            // The month total stays month-only.
            peakDayCost = dayCosts.values.maxOrNull() ?: 0.0,
            monthTotalCost = inMonth.values.sum(),
        )
    }

    /**
     * Selection aggregation. [events] = the loaded usage rows (any superset
     * of the selection window); only rows whose local start-of-day
     * `startTime` falls on a selected day contribute.
     */
    fun buildSelection(events: List<TokenUsage>, selectedDays: Set<LocalDate>, zoneId: ZoneId): CalendarSelectionSnapshot {
        val sortedDays = selectedDays.sorted()
        val selected = events.filter { localDay(effectiveStartMillis(it), zoneId) in selectedDays }

        val totalCost = selected.sumOf { it.effectiveCost }
        val totalTokens = selected.sumOf { it.totalTokens.toLong() }
        val (matrix, peak) = hourWeekdayMatrix(selected, zoneId)
        val cacheRead = selected.sumOf { it.cacheReadTokens.toLong() }
        val promptBasis = selected.sumOf { (it.inputTokens + it.cacheCreationTokens + it.cacheReadTokens).toLong() }
        val reasoningTokens = selected.sumOf { it.reasoningTokens.toLong() }

        return CalendarSelectionSnapshot(
            selectedDays = sortedDays,
            isEmpty = selected.isEmpty(),
            totalCost = totalCost,
            totalTokens = totalTokens,
            // Rows without a session id collapse into one synthetic bucket
            // rather than vanishing, matching the oracle's Set(map(\.sessionId)).
            sessionCount = selected.mapTo(mutableSetOf()) { it.sessionId ?: "" }.size,
            activeDays = selected.mapTo(mutableSetOf()) { localDay(effectiveStartMillis(it), zoneId) }.size,
            averageCostPerDay = totalCost / maxOf(sortedDays.size, 1).toDouble(),
            dailyBurn = dailyBurn(selected, sortedDays, zoneId),
            providerShares = providerShares(selected),
            topModels = costByKey(selected, { it.model }, TOP_MODELS_LIMIT) { (model, cost) ->
                CalendarModelCost(model = model, cost = cost)
            },
            projectShares = costByKey(
                selected,
                { it.projectName },
                TOP_PROJECTS_LIMIT,
                blankLabel = UNATTRIBUTED_PROJECT,
            ) { (name, cost) ->
                CalendarProjectCost(name = name, cost = cost)
            },
            hourWeekdayCost = matrix,
            peakWeekdayIndex = peak?.first,
            peakHour = peak?.second,
            cacheHitRate = if (promptBasis > 0) cacheRead.toDouble() / promptBasis.toDouble() else 0.0,
            cacheReadTokens = cacheRead,
            cacheSavingsEstimate = CACHE_BILLED_FRACTION_SAVED * cacheRead.toDouble() * blendedRate(totalCost, totalTokens),
            reasoningShare = if (totalTokens > 0) reasoningTokens.toDouble() / totalTokens.toDouble() else 0.0,
            reasoningTokens = reasoningTokens,
        )
    }

    /** Per-day burn across the selection's span — gap-filled so silent days
     *  draw as zero bars instead of collapsing. */
    private fun dailyBurn(selected: List<TokenUsage>, sortedDays: List<LocalDate>, zoneId: ZoneId): List<CalendarDayCost> {
        if (sortedDays.isEmpty()) return emptyList()
        val perDay =
            selected
                .groupingBy { localDay(effectiveStartMillis(it), zoneId) }
                .fold(0.0) { acc, e -> acc + e.effectiveCost }
        return gapFilledDays(sortedDays.first(), sortedDays.last())
            .map { CalendarDayCost(it, perDay[it] ?: 0.0) }
    }

    private fun providerShares(selected: List<TokenUsage>): List<CalendarProviderShare> = selected
        .groupingBy { (it.providerId ?: it.provider).ifBlank { "unknown" } }
        .fold(0.0) { acc, e -> acc + e.effectiveCost }
        .entries
        .sortedByDescending { it.value }
        .map { (key, cost) ->
            val provider = AgentProvider.fromKey(key)
            CalendarProviderShare(
                provider = provider,
                key = key,
                displayName = provider?.displayName ?: key,
                cost = cost,
            )
        }

    /**
     * Per-key (model / project) cost leaderboard. Blank keys are skipped when
     * [blankLabel] is null, or folded into that label when supplied — project
     * focus keeps unattributed spend visible instead of silently dropping it
     * (`UsageStore+Summaries.swift:256`).
     */
    private fun <T> costByKey(
        selected: List<TokenUsage>,
        key: (TokenUsage) -> String?,
        limit: Int,
        blankLabel: String? = null,
        build: (Map.Entry<String, Double>) -> T,
    ): List<T> = selected
        .filter { blankLabel != null || !key(it).isNullOrBlank() }
        .groupingBy { key(it)?.takeIf(String::isNotBlank) ?: blankLabel!! }
        .fold(0.0) { acc, e -> acc + e.effectiveCost }
        .entries
        .sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
        .take(limit)
        .map(build)

    /** 7×24 cost matrix plus its peak cell; row 0 = Sunday
     *  (DayOfWeek.value: Mon=1…Sun=7 → %7). */
    private fun hourWeekdayMatrix(selected: List<TokenUsage>, zoneId: ZoneId): Pair<List<List<Double>>, Pair<Int, Int>?> {
        val matrix = List(CalendarSelectionSnapshot.WEEKDAYS) { MutableList(CalendarSelectionSnapshot.HOURS_PER_DAY) { 0.0 } }
        selected.forEach { event ->
            val zoned = Instant.ofEpochMilli(effectiveStartMillis(event)).atZone(zoneId)
            matrix[zoned.dayOfWeek.value % WEEKDAY_COUNT][zoned.hour] += event.effectiveCost
        }
        var peak: Pair<Int, Int>? = null
        var peakValue = 0.0
        matrix.forEachIndexed { weekday, hours ->
            hours.forEachIndexed { hour, value ->
                if (value > peakValue) {
                    peakValue = value
                    peak = weekday to hour
                }
            }
        }
        return matrix.map { it.toList() } to peak
    }

    private fun blendedRate(totalCost: Double, totalTokens: Long): Double = if (totalTokens > 0) totalCost / totalTokens.toDouble() else 0.0

    private const val TOP_PROVIDERS_PER_DAY = 3
    private const val TOP_MODELS_LIMIT = 6
    private const val TOP_PROJECTS_LIMIT = 5

/** Bucket label for spend with no project name (`UsageStore+Summaries.swift:256`). */
private const val UNATTRIBUTED_PROJECT = "Unattributed"
    private const val WEEKDAY_COUNT = 7

    /** Cache reads are billed at ~10% of the blended per-token rate, so the
     *  savings estimate is the remaining 90% of what those tokens would have
     *  cost. Mirrors `ChartsSnapshot.cacheSavingsEstimate` on macOS. */
    private const val CACHE_BILLED_FRACTION_SAVED = 0.9
}

// MARK: - Store

/**
 * ViewModel backing the Calendar tab. Month heat and selection breakdowns both
 * aggregate the live usage events client-side in the device timezone, so
 * tapping around the grid never hits the network. Follows the
 * `DashboardStore`/`ActivityStore` listener pattern (catch-and-surface, never
 * crash the host activity on PERMISSION_DENIED).
 */
class CalendarStore(
    private val repo: FirestoreRepository = FirestoreRepository(),
    private val zoneId: ZoneId = ZoneId.systemDefault(),
    private val clock: () -> Long = System::currentTimeMillis,
) : ViewModel() {

    private val _rollups = MutableStateFlow<UsageRollups?>(null)
    val rollups = _rollups.asStateFlow()

    private val usageEvents = MutableStateFlow<List<TokenUsage>>(emptyList())

    private val _visibleMonth = MutableStateFlow(currentYearMonth())
    val visibleMonth = _visibleMonth.asStateFlow()

    private val _selectedDays = MutableStateFlow<Set<LocalDate>>(emptySet())
    val selectedDays = _selectedDays.asStateFlow()

    private val _monthSnapshot = MutableStateFlow(CalendarMonthSnapshot(month = currentYearMonth()))
    val monthSnapshot = _monthSnapshot.asStateFlow()

    private val _selectionSnapshot = MutableStateFlow(CalendarSelectionSnapshot())
    val selectionSnapshot = _selectionSnapshot.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error = _error.asStateFlow()

    private var rollupsJob: Job? = null
    private var usageJob: Job? = null

    fun today(): LocalDate = CalendarAggregation.localDay(clock(), zoneId)

    fun startListening() {
        if (rollupsJob != null) return
        _isLoading.value = true
        rollupsJob =
            viewModelScope.launch {
                repo.listenToRollups()
                    .catch { e -> _error.value = e.message ?: e::class.simpleName }
                    .collect { rollups ->
                        _rollups.value = rollups
                        _isLoading.value = false
                        recomputeMonth()
                    }
            }
        restartUsageListener()
    }

    fun stopListening() {
        rollupsJob?.cancel()
        rollupsJob = null
        usageJob?.cancel()
        usageJob = null
    }

    fun setVisibleMonth(month: YearMonth) {
        if (month == _visibleMonth.value) return
        _visibleMonth.value = month
        recomputeMonth()
        // The live event window follows the visible month so old months still
        // get provider dots / selection breakdowns when events exist there.
        restartUsageListener()
    }

    fun shiftMonth(delta: Long) = setVisibleMonth(_visibleMonth.value.plusMonths(delta))

    fun setSelection(days: Set<LocalDate>) {
        if (days == _selectedDays.value) return
        _selectedDays.value = days
        recomputeSelection()
    }

    /**
     * The live usage window: start of the visible month, padded one week so
     * grid overflow days from the previous month still resolve. The query
     * itself caps at the newest 2000 docs (see `listenToUsageSince`), which
     * comfortably covers recent months. Months older than that window read as
     * empty — an honest gap, since the server rollup series is UTC-keyed tokens
     * and cannot stand in for local-day cost (see `buildMonth`).
     */
    private fun restartUsageListener() {
        usageJob?.cancel()
        val windowStart =
            _visibleMonth.value
                .atDay(1)
                .minusDays(GRID_OVERFLOW_PAD_DAYS)
                .atStartOfDay(zoneId)
                .toInstant()
                .toEpochMilli()
        usageJob =
            viewModelScope.launch {
                repo.listenToUsageSince(windowStart)
                    .catch { e -> _error.value = e.message ?: e::class.simpleName }
                    .collect { events ->
                        usageEvents.value = events
                        recomputeMonth()
                        recomputeSelection()
                    }
            }
    }

    private fun recomputeMonth() {
        _monthSnapshot.value =
            CalendarAggregation.buildMonth(
                events = usageEvents.value,
                month = _visibleMonth.value,
                zoneId = zoneId,
            )
    }

    private fun recomputeSelection() {
        _selectionSnapshot.value =
            CalendarAggregation.buildSelection(
                events = usageEvents.value,
                selectedDays = _selectedDays.value,
                zoneId = zoneId,
            )
    }

    private fun currentYearMonth(): YearMonth = YearMonth.from(CalendarAggregation.localDay(clock(), zoneId))

    override fun onCleared() {
        stopListening()
        super.onCleared()
    }

    private companion object {
        const val GRID_OVERFLOW_PAD_DAYS = 7L
    }
}
