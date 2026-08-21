package com.openburnbar.data.recap

import com.openburnbar.data.models.TokenUsage
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.max

private const val LATE_NIGHT_END_HOUR = 5
private const val MORNING_START_HOUR = 6
private const val MORNING_END_HOUR = 11
private const val EVENING_START_HOUR = 18
private const val EVENING_END_HOUR = 23
private const val PERCENT_90 = 0.90
private const val MILLIS_PER_SECOND = 1000.0

object RecapFactsBuilder {

    const val PAIRING_SEPARATOR = " ⨯ "

    fun build(
        window: RecapWindow,
        usages: List<TokenUsage>,
        builtAtEpochMillis: Long = System.currentTimeMillis(),
        isPartial: Boolean = false,
        zone: ZoneId = ZoneId.systemDefault(),
    ): RecapFacts {
        val daysInMonth = window.dayCount()
        val dailyCost = DoubleArray(daysInMonth)
        val dailyTokens = LongArray(daysInMonth)
        val dailySessions = IntArray(daysInMonth)
        val hourCost = DoubleArray(RecapConstants.HOURS_PER_DAY)
        val hourTokens = LongArray(RecapConstants.HOURS_PER_DAY)
        val weekdayCost = DoubleArray(RecapConstants.DAYS_PER_WEEK)
        val weekdaySessions = IntArray(RecapConstants.DAYS_PER_WEEK)
        val matrix = Array(RecapConstants.DAYS_PER_WEEK) { DoubleArray(RecapConstants.HOURS_PER_DAY) }

        var totalCost = 0.0
        var totalTokens = 0L
        var inputTokens = 0L
        var outputTokens = 0L
        var cacheReadTokens = 0L
        var reasoningTokens = 0L

        val modelStats = mutableMapOf<String, ModelAccumulator>()
        val providerStats = mutableMapOf<String, ProviderAccumulator>()
        val pairingStats = mutableMapOf<String, PairingAccumulator>()
        val sessionList = mutableListOf<RecapSessionInfo>()

        for (u in usages) {
            val cost = u.costUSD.coerceAtLeast(0.0)
            val tokens = u.totalTokens.coerceAtLeast(0).toLong()
            totalCost += cost
            totalTokens += tokens
            inputTokens += u.inputTokens.coerceAtLeast(0).toLong()
            outputTokens += u.outputTokens.coerceAtLeast(0).toLong()
            cacheReadTokens += u.cacheReadTokens.coerceAtLeast(0).toLong()
            reasoningTokens += u.reasoningTokens.coerceAtLeast(0).toLong()

            accumulateTimeStats(u, zone, daysInMonth, dailyCost, dailyTokens, dailySessions, hourCost, hourTokens, weekdayCost, weekdaySessions, matrix)
            accumulateModelAndProvider(u, modelStats, providerStats, pairingStats)
            accumulateSession(u, sessionList)
        }

        val totalSessionsCount = max(usages.size, sessionList.map { it.id }.distinct().size)

        return assembleFacts(
            window, builtAtEpochMillis, isPartial, zone,
            totalCost, totalTokens, inputTokens, outputTokens, cacheReadTokens, reasoningTokens,
            totalSessionsCount,
            dailyCost, dailyTokens, dailySessions, hourCost, weekdayCost, weekdaySessions, matrix,
            modelStats, providerStats, pairingStats, sessionList,
        )
    }

    private fun accumulateTimeStats(
        u: TokenUsage,
        zone: ZoneId,
        daysInMonth: Int,
        dailyCost: DoubleArray,
        dailyTokens: LongArray,
        dailySessions: IntArray,
        hourCost: DoubleArray,
        hourTokens: LongArray,
        weekdayCost: DoubleArray,
        weekdaySessions: IntArray,
        matrix: Array<DoubleArray>,
    ) {
        val startMillis = u.startTime
        val zdt = if (startMillis > 0L) {
            Instant.ofEpochMilli(startMillis).atZone(zone)
        } else {
            ZonedDateTime.now(zone)
        }

        val dayIdx = (zdt.dayOfMonth - 1).coerceIn(0, daysInMonth - 1)
        val hourIdx = zdt.hour.coerceIn(0, RecapConstants.HOURS_PER_DAY - 1)
        val weekdayIdx = (zdt.dayOfWeek.value % RecapConstants.DAYS_PER_WEEK) // 0=Sunday, 6=Saturday

        val cost = u.costUSD.coerceAtLeast(0.0)
        val tokens = u.totalTokens.coerceAtLeast(0).toLong()

        dailyCost[dayIdx] += cost
        dailyTokens[dayIdx] += tokens
        dailySessions[dayIdx]++
        hourCost[hourIdx] += cost
        hourTokens[hourIdx] += tokens
        weekdayCost[weekdayIdx] += cost
        weekdaySessions[weekdayIdx]++
        matrix[weekdayIdx][hourIdx] += cost
    }

    private fun accumulateModelAndProvider(
        u: TokenUsage,
        modelStats: MutableMap<String, ModelAccumulator>,
        providerStats: MutableMap<String, ProviderAccumulator>,
        pairingStats: MutableMap<String, PairingAccumulator>,
    ) {
        val modelKey = (u.model?.ifEmpty { "unknown-model" }) ?: "unknown-model"
        val providerKey = u.provider.ifEmpty { "unknown-provider" }
        val pairingKey = "$providerKey$PAIRING_SEPARATOR$modelKey"

        val cost = u.costUSD.coerceAtLeast(0.0)
        val tokens = u.totalTokens.coerceAtLeast(0).toLong()

        val mAcc = modelStats.getOrPut(modelKey) { ModelAccumulator(modelKey) }
        mAcc.cost += cost
        mAcc.tokens += tokens
        mAcc.events++

        val pAcc = providerStats.getOrPut(providerKey) { ProviderAccumulator(providerKey) }
        pAcc.cost += cost
        pAcc.tokens += tokens
        pAcc.events++

        val pairAcc = pairingStats.getOrPut(pairingKey) { PairingAccumulator(providerKey, modelKey) }
        pairAcc.cost += cost
        pairAcc.tokens += tokens
        pairAcc.events++
    }

    private fun accumulateSession(u: TokenUsage, sessionList: MutableList<RecapSessionInfo>) {
        val durationSecs = if (u.endTime > u.startTime && u.startTime > 0L) {
            (u.endTime - u.startTime) / MILLIS_PER_SECOND
        } else {
            0.0
        }
        val sId = u.sessionId ?: u.id
        val modelKey = (u.model?.ifEmpty { "unknown-model" }) ?: "unknown-model"
        sessionList.add(
            RecapSessionInfo(
                id = sId,
                model = modelKey,
                providerKey = u.provider,
                startTimeEpochMillis = u.startTime,
                cost = u.costUSD.coerceAtLeast(0.0),
                tokens = u.totalTokens.coerceAtLeast(0).toLong(),
                durationSeconds = durationSecs,
            ),
        )
    }

    private fun assembleFacts(
        window: RecapWindow,
        builtAtEpochMillis: Long,
        isPartial: Boolean,
        zone: ZoneId,
        totalCost: Double,
        totalTokens: Long,
        inputTokens: Long,
        outputTokens: Long,
        cacheReadTokens: Long,
        reasoningTokens: Long,
        totalSessionsCount: Int,
        dailyCost: DoubleArray,
        dailyTokens: LongArray,
        dailySessions: IntArray,
        hourCost: DoubleArray,
        weekdayCost: DoubleArray,
        weekdaySessions: IntArray,
        matrix: Array<DoubleArray>,
        modelStats: Map<String, ModelAccumulator>,
        providerStats: Map<String, ProviderAccumulator>,
        pairingStats: Map<String, PairingAccumulator>,
        sessionList: List<RecapSessionInfo>,
    ): RecapFacts {
        val (activeDays, streak) = computeStreakAndActiveDays(dailyCost, dailyTokens)
        val modelShares = computeModelShares(modelStats, totalCost, totalSessionsCount)
        val providerShares = computeProviderShares(providerStats, totalCost, totalSessionsCount)
        val pairingShares = computePairingShares(pairingStats, totalCost, totalSessionsCount)
        val sessionStats = computeSessionStats(sessionList)
        val busiestDay = computeBusiestDay(window, dailyCost, dailyTokens, dailySessions, zone)
        val busiestWeek = computeBusiestWeek(window, dailyCost, dailySessions, zone)

        val totalPromptTokens = inputTokens + cacheReadTokens
        val cacheHitRate = if (totalPromptTokens > 0L) cacheReadTokens.toDouble() / totalPromptTokens else 0.0
        val maxHourIdx = hourCost.indices.maxByOrNull { hourCost[it] }
        val maxWeekdayIdx = weekdayCost.indices.maxByOrNull { weekdayCost[it] }
        val timeShares = computeTimeShares(hourCost, weekdayCost, totalCost)
        val modelConcentration = modelShares.sumOf { it.costShare * it.costShare }

        return RecapFacts(
            window = window,
            builtAtEpochMillis = builtAtEpochMillis,
            isPartial = isPartial,
            hasSessionData = sessionList.isNotEmpty(),
            exactShare = 1.0,
            totalCostUSD = totalCost,
            totalTokens = totalTokens,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            reasoningTokens = reasoningTokens,
            cacheReadTokens = cacheReadTokens,
            cacheCreationTokens = 0L,
            sessionCount = totalSessionsCount,
            activeDayCount = activeDays,
            dayCount = window.dayCount(),
            dailyCost = dailyCost.toList(),
            dailyTokens = dailyTokens.toList(),
            dailySessions = dailySessions.toList(),
            hourWeekdayCost = matrix.map { it.toList() },
            hourCost = hourCost.toList(),
            weekdayCost = weekdayCost.toList(),
            weekdaySessions = weekdaySessions.toList(),
            models = modelShares,
            providers = providerShares,
            projects = emptyList(),
            pairings = pairingShares,
            tools = emptyList(),
            sessionStats = sessionStats,
            longestSession = computeLongestSession(sessionList),
            busiestDay = busiestDay,
            busiestWeek = busiestWeek,
            peakHour = maxHourIdx,
            peakWeekday = maxWeekdayIdx,
            longestActiveStreak = streak,
            cacheHitRate = cacheHitRate,
            modelConcentration = modelConcentration,
            weekendCostShare = timeShares.weekend,
            lateNightCostShare = timeShares.lateNight,
            morningCostShare = timeShares.morning,
            eveningCostShare = timeShares.evening,
        )
    }

    private fun computeTimeShares(hourCost: DoubleArray, weekdayCost: DoubleArray, totalCost: Double): TimeShares {
        val lateNightCost = (0..LATE_NIGHT_END_HOUR).sumOf { hourCost[it] }
        val morningCost = (MORNING_START_HOUR..MORNING_END_HOUR).sumOf { hourCost[it] }
        val eveningCost = (EVENING_START_HOUR..EVENING_END_HOUR).sumOf { hourCost[it] }
        val saturdayIdx = RecapConstants.DAYS_PER_WEEK - 1
        val weekendCost = weekdayCost[0] + weekdayCost[saturdayIdx]

        return TimeShares(
            lateNight = if (totalCost > 0.0) lateNightCost / totalCost else 0.0,
            morning = if (totalCost > 0.0) morningCost / totalCost else 0.0,
            evening = if (totalCost > 0.0) eveningCost / totalCost else 0.0,
            weekend = if (totalCost > 0.0) weekendCost / totalCost else 0.0,
        )
    }

    private data class TimeShares(
        val lateNight: Double,
        val morning: Double,
        val evening: Double,
        val weekend: Double,
    )

    private fun computeStreakAndActiveDays(dailyCost: DoubleArray, dailyTokens: LongArray): Pair<Int, Int> {
        var activeDays = 0
        var currentStreak = 0
        var maxStreak = 0

        for (i in dailyCost.indices) {
            val isActive = dailyCost[i] > 0.0 || dailyTokens[i] > 0L
            if (isActive) {
                activeDays++
                currentStreak++
                if (currentStreak > maxStreak) maxStreak = currentStreak
            } else {
                currentStreak = 0
            }
        }
        return activeDays to maxStreak
    }

    private fun computeModelShares(modelStats: Map<String, ModelAccumulator>, totalCost: Double, totalSessions: Int): List<RecapShare> {
        return modelStats.values.map {
            val costShare = if (totalCost > 0.0) it.cost / totalCost else 0.0
            val sessionShare = if (totalSessions > 0) it.events.toDouble() / totalSessions else 0.0
            RecapShare(
                key = it.key,
                label = it.key,
                costUSD = it.cost,
                tokens = it.tokens,
                sessions = it.events,
                costShare = costShare,
                sessionShare = sessionShare,
            )
        }.sortedByDescending { it.costUSD }
    }

    private fun computeProviderShares(providerStats: Map<String, ProviderAccumulator>, totalCost: Double, totalSessions: Int): List<RecapShare> {
        return providerStats.values.map {
            val costShare = if (totalCost > 0.0) it.cost / totalCost else 0.0
            val sessionShare = if (totalSessions > 0) it.events.toDouble() / totalSessions else 0.0
            RecapShare(
                key = it.key,
                label = it.key,
                costUSD = it.cost,
                tokens = it.tokens,
                sessions = it.events,
                costShare = costShare,
                sessionShare = sessionShare,
            )
        }.sortedByDescending { it.costUSD }
    }

    private fun computePairingShares(pairingStats: Map<String, PairingAccumulator>, totalCost: Double, totalSessions: Int): List<RecapShare> {
        return pairingStats.values.map {
            val costShare = if (totalCost > 0.0) it.cost / totalCost else 0.0
            val sessionShare = if (totalSessions > 0) it.events.toDouble() / totalSessions else 0.0
            RecapShare(
                key = "${it.provider}$PAIRING_SEPARATOR${it.model}",
                label = "${it.provider} • ${it.model}",
                costUSD = it.cost,
                tokens = it.tokens,
                sessions = it.events,
                costShare = costShare,
                sessionShare = sessionShare,
            )
        }.sortedByDescending { it.costUSD }
    }

    private fun computeSessionStats(sessionList: List<RecapSessionInfo>): RecapSessionStats {
        if (sessionList.isEmpty()) {
            return RecapSessionStats.EMPTY
        }
        val durations = sessionList.map { it.durationSeconds }.sorted()
        val costs = sessionList.map { it.cost }.sorted()

        val medianDur = durations[durations.size / 2]
        val p90Idx = (durations.size * PERCENT_90).toInt().coerceIn(0, durations.size - 1)
        val p90Dur = durations[p90Idx]
        val meanDur = durations.sum() / durations.size
        val totalSecs = durations.sum()
        val medianCost = costs[costs.size / 2]

        return RecapSessionStats(
            count = sessionList.size,
            medianSeconds = medianDur,
            p90Seconds = p90Dur,
            meanSeconds = meanDur,
            totalSeconds = totalSecs,
            medianCostUSD = medianCost,
        )
    }

    private fun computeBusiestDay(
        window: RecapWindow,
        dailyCost: DoubleArray,
        dailyTokens: LongArray,
        dailySessions: IntArray,
        zone: ZoneId,
    ): RecapDayHighlight? {
        val maxIdx = dailyCost.indices.maxByOrNull { dailyCost[it] } ?: return null
        if (dailyCost[maxIdx] <= 0.0 && dailyTokens[maxIdx] <= 0L) return null

        val epochMillis = window.startEpochMillis(zone) + maxIdx * RecapConstants.MILLIS_PER_DAY
        return RecapDayHighlight(
            dayIndex = maxIdx,
            epochMillis = epochMillis,
            costUSD = dailyCost[maxIdx],
            tokens = dailyTokens[maxIdx],
            sessions = dailySessions[maxIdx],
        )
    }

    private fun computeBusiestWeek(window: RecapWindow, dailyCost: DoubleArray, dailySessions: IntArray, zone: ZoneId): RecapWeekHighlight? {
        if (dailyCost.size < RecapConstants.DAYS_PER_WEEK) return null
        var maxCost = 0.0
        var bestStartIdx = 0

        for (startIdx in 0..(dailyCost.size - RecapConstants.DAYS_PER_WEEK)) {
            var sum = 0.0
            for (offset in 0 until RecapConstants.DAYS_PER_WEEK) {
                sum += dailyCost[startIdx + offset]
            }
            if (sum > maxCost) {
                maxCost = sum
                bestStartIdx = startIdx
            }
        }
        if (maxCost <= 0.0) return null

        val startMillis = window.startEpochMillis(zone) + bestStartIdx * RecapConstants.MILLIS_PER_DAY
        val endMillis = startMillis + (RecapConstants.DAYS_PER_WEEK * RecapConstants.MILLIS_PER_DAY)
        val weekSessions = (0 until RecapConstants.DAYS_PER_WEEK).sumOf { dailySessions[bestStartIdx + it] }

        return RecapWeekHighlight(
            startDayIndex = bestStartIdx,
            endDayIndex = bestStartIdx + RecapConstants.DAYS_PER_WEEK - 1,
            startEpochMillis = startMillis,
            endEpochMillis = endMillis,
            costUSD = maxCost,
            sessions = weekSessions,
        )
    }

    private fun computeLongestSession(sessionList: List<RecapSessionInfo>): RecapSessionHighlight? {
        val best = sessionList.maxByOrNull { it.durationSeconds } ?: return null
        if (best.durationSeconds <= 0.0) return null
        return RecapSessionHighlight(
            sessionID = best.id,
            projectName = null,
            model = best.model,
            providerKey = best.providerKey,
            startTimeEpochMillis = best.startTimeEpochMillis,
            durationSeconds = best.durationSeconds,
            costUSD = best.cost,
            tokens = best.tokens,
        )
    }

    private class ModelAccumulator(val key: String, var cost: Double = 0.0, var tokens: Long = 0L, var events: Int = 0)
    private class ProviderAccumulator(val key: String, var cost: Double = 0.0, var tokens: Long = 0L, var events: Int = 0)
    private class PairingAccumulator(val provider: String, val model: String, var cost: Double = 0.0, var tokens: Long = 0L, var events: Int = 0)
    private class RecapSessionInfo(
        val id: String,
        val model: String,
        val providerKey: String,
        val startTimeEpochMillis: Long,
        val cost: Double,
        val tokens: Long,
        val durationSeconds: Double,
    )
}
