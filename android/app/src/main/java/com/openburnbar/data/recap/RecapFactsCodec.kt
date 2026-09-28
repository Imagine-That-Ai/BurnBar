package com.openburnbar.data.recap

import org.json.JSONArray
import org.json.JSONObject

/**
 * JSON codec for the full [RecapFacts] shape kept in the Recap history file.
 *
 * Format 1 (the original) persisted only a scalar subset; format 2 persists
 * every field the rules read (model/provider/pairing shares, daily series,
 * session stats, highlights, token breakdown). Decoding stays tolerant of
 * format-1 files: absent fields fall back to the [RecapFacts] defaults.
 */
internal object RecapFactsCodec {
    const val FORMAT_KEY = "format"
    const val LEGACY_FORMAT = 1
    const val CURRENT_FORMAT = 2

    fun isCurrentFormat(obj: JSONObject): Boolean = obj.optInt(FORMAT_KEY, LEGACY_FORMAT) >= CURRENT_FORMAT

    fun encode(facts: RecapFacts): JSONObject = JSONObject().apply {
        put(FORMAT_KEY, CURRENT_FORMAT)
        put("schemaVersion", facts.schemaVersion)
        put("window", facts.window.key)
        put("builtAt", facts.builtAtEpochMillis)
        put("isPartial", facts.isPartial)
        put("hasSessionData", facts.hasSessionData)
        put("exactShare", finite(facts.exactShare))
        put("totalCostUSD", finite(facts.totalCostUSD))
        put("totalTokens", facts.totalTokens)
        put("inputTokens", facts.inputTokens)
        put("outputTokens", facts.outputTokens)
        put("reasoningTokens", facts.reasoningTokens)
        put("cacheReadTokens", facts.cacheReadTokens)
        put("cacheCreationTokens", facts.cacheCreationTokens)
        put("sessionCount", facts.sessionCount)
        put("activeDayCount", facts.activeDayCount)
        put("dayCount", facts.dayCount)
        put("dailyCost", doubles(facts.dailyCost))
        put("dailyTokens", JSONArray(facts.dailyTokens))
        put("dailySessions", JSONArray(facts.dailySessions))
        put("hourWeekdayCost", JSONArray(facts.hourWeekdayCost.map(::doubles)))
        put("hourCost", doubles(facts.hourCost))
        put("weekdayCost", doubles(facts.weekdayCost))
        put("weekdaySessions", JSONArray(facts.weekdaySessions))
        put("models", shares(facts.models))
        put("providers", shares(facts.providers))
        put("projects", shares(facts.projects))
        put("pairings", shares(facts.pairings))
        put("tools", JSONArray(facts.tools.map(::encodeCount)))
        put("sessionStats", encodeSessionStats(facts.sessionStats))
        facts.longestSession?.let { put("longestSession", encodeSession(it)) }
        facts.busiestDay?.let { put("busiestDay", encodeDay(it)) }
        facts.busiestWeek?.let { put("busiestWeek", encodeWeek(it)) }
        facts.peakHour?.let { put("peakHour", it) }
        facts.peakWeekday?.let { put("peakWeekday", it) }
        put("longestActiveStreak", facts.longestActiveStreak)
        put("cacheHitRate", finite(facts.cacheHitRate))
        put("modelConcentration", finite(facts.modelConcentration))
        put("weekendCostShare", finite(facts.weekendCostShare))
        put("lateNightCostShare", finite(facts.lateNightCostShare))
        put("morningCostShare", finite(facts.morningCostShare))
        put("eveningCostShare", finite(facts.eveningCostShare))
    }

    fun decode(window: RecapWindow, obj: JSONObject): RecapFacts = RecapFacts(
        schemaVersion = obj.optInt("schemaVersion", 1),
        window = window,
        builtAtEpochMillis = obj.optLong("builtAt", System.currentTimeMillis()),
        isPartial = obj.optBoolean("isPartial", false),
        hasSessionData = obj.optBoolean("hasSessionData", false),
        exactShare = obj.optDouble("exactShare", 1.0),
        totalCostUSD = obj.optDouble("totalCostUSD", 0.0),
        totalTokens = obj.optLong("totalTokens", 0L),
        inputTokens = obj.optLong("inputTokens", 0L),
        outputTokens = obj.optLong("outputTokens", 0L),
        reasoningTokens = obj.optLong("reasoningTokens", 0L),
        cacheReadTokens = obj.optLong("cacheReadTokens", 0L),
        cacheCreationTokens = obj.optLong("cacheCreationTokens", 0L),
        sessionCount = obj.optInt("sessionCount", 0),
        activeDayCount = obj.optInt("activeDayCount", 0),
        dayCount = obj.optInt("dayCount", window.dayCount()),
        dailyCost = decodeDoubles(obj.optJSONArray("dailyCost")),
        dailyTokens = decodeList(obj.optJSONArray("dailyTokens")) { a, i -> a.optLong(i) },
        dailySessions = decodeList(obj.optJSONArray("dailySessions")) { a, i -> a.optInt(i) },
        hourWeekdayCost = decodeList(obj.optJSONArray("hourWeekdayCost")) { a, i -> decodeDoubles(a.optJSONArray(i)) },
        hourCost = decodeDoubles(obj.optJSONArray("hourCost")),
        weekdayCost = decodeDoubles(obj.optJSONArray("weekdayCost")),
        weekdaySessions = decodeList(obj.optJSONArray("weekdaySessions")) { a, i -> a.optInt(i) },
        models = decodeShares(obj.optJSONArray("models")),
        providers = decodeShares(obj.optJSONArray("providers")),
        projects = decodeShares(obj.optJSONArray("projects")),
        pairings = decodeShares(obj.optJSONArray("pairings")),
        tools = decodeObjects(obj.optJSONArray("tools"), ::decodeCount),
        sessionStats = obj.optJSONObject("sessionStats")?.let(::decodeSessionStats) ?: RecapSessionStats.EMPTY,
        longestSession = obj.optJSONObject("longestSession")?.let(::decodeSession),
        busiestDay = obj.optJSONObject("busiestDay")?.let(::decodeDay),
        busiestWeek = obj.optJSONObject("busiestWeek")?.let(::decodeWeek),
        peakHour = optNullableInt(obj, "peakHour"),
        peakWeekday = optNullableInt(obj, "peakWeekday"),
        longestActiveStreak = obj.optInt("longestActiveStreak", 0),
        cacheHitRate = obj.optDouble("cacheHitRate", 0.0),
        modelConcentration = obj.optDouble("modelConcentration", 0.0),
        weekendCostShare = obj.optDouble("weekendCostShare", 0.0),
        lateNightCostShare = obj.optDouble("lateNightCostShare", 0.0),
        morningCostShare = obj.optDouble("morningCostShare", 0.0),
        eveningCostShare = obj.optDouble("eveningCostShare", 0.0),
    )

    private fun shares(list: List<RecapShare>) = JSONArray(
        list.map {
            JSONObject()
                .put("key", it.key)
                .put("label", it.label)
                .put("costUSD", finite(it.costUSD))
                .put("tokens", it.tokens)
                .put("sessions", it.sessions)
                .put("costShare", finite(it.costShare))
                .put("sessionShare", finite(it.sessionShare))
        },
    )

    private fun decodeShares(arr: JSONArray?): List<RecapShare> = decodeObjects(arr) {
        RecapShare(
            key = it.optString("key"),
            label = it.optString("label"),
            costUSD = it.optDouble("costUSD", 0.0),
            tokens = it.optLong("tokens", 0L),
            sessions = it.optInt("sessions", 0),
            costShare = it.optDouble("costShare", 0.0),
            sessionShare = it.optDouble("sessionShare", 0.0),
        )
    }

    private fun encodeCount(count: RecapCount) = JSONObject().put("name", count.name).put("count", count.count).put("share", finite(count.share))

    private fun decodeCount(obj: JSONObject) = RecapCount(name = obj.optString("name"), count = obj.optInt("count", 0), share = obj.optDouble("share", 0.0))

    private fun encodeSessionStats(stats: RecapSessionStats) = JSONObject()
        .put("count", stats.count)
        .put("medianSeconds", finite(stats.medianSeconds))
        .put("p90Seconds", finite(stats.p90Seconds))
        .put("meanSeconds", finite(stats.meanSeconds))
        .put("totalSeconds", finite(stats.totalSeconds))
        .put("medianCostUSD", finite(stats.medianCostUSD))

    private fun decodeSessionStats(obj: JSONObject) = RecapSessionStats(
        count = obj.optInt("count", 0),
        medianSeconds = obj.optDouble("medianSeconds", 0.0),
        p90Seconds = obj.optDouble("p90Seconds", 0.0),
        meanSeconds = obj.optDouble("meanSeconds", 0.0),
        totalSeconds = obj.optDouble("totalSeconds", 0.0),
        medianCostUSD = obj.optDouble("medianCostUSD", 0.0),
    )

    private fun encodeSession(session: RecapSessionHighlight) = JSONObject().apply {
        put("sessionID", session.sessionID)
        session.projectName?.let { put("projectName", it) }
        put("model", session.model)
        put("providerKey", session.providerKey)
        put("startTime", session.startTimeEpochMillis)
        put("durationSeconds", finite(session.durationSeconds))
        put("costUSD", finite(session.costUSD))
        put("tokens", session.tokens)
    }

    private fun decodeSession(obj: JSONObject) = RecapSessionHighlight(
        sessionID = obj.optString("sessionID"),
        projectName = if (obj.has("projectName")) obj.optString("projectName") else null,
        model = obj.optString("model"),
        providerKey = obj.optString("providerKey"),
        startTimeEpochMillis = obj.optLong("startTime", 0L),
        durationSeconds = obj.optDouble("durationSeconds", 0.0),
        costUSD = obj.optDouble("costUSD", 0.0),
        tokens = obj.optLong("tokens", 0L),
    )

    private fun encodeDay(day: RecapDayHighlight) = JSONObject()
        .put("dayIndex", day.dayIndex)
        .put("epochMillis", day.epochMillis)
        .put("costUSD", finite(day.costUSD))
        .put("tokens", day.tokens)
        .put("sessions", day.sessions)

    private fun decodeDay(obj: JSONObject) = RecapDayHighlight(
        dayIndex = obj.optInt("dayIndex", 0),
        epochMillis = obj.optLong("epochMillis", 0L),
        costUSD = obj.optDouble("costUSD", 0.0),
        tokens = obj.optLong("tokens", 0L),
        sessions = obj.optInt("sessions", 0),
    )

    private fun encodeWeek(week: RecapWeekHighlight) = JSONObject()
        .put("startDayIndex", week.startDayIndex)
        .put("endDayIndex", week.endDayIndex)
        .put("startEpochMillis", week.startEpochMillis)
        .put("endEpochMillis", week.endEpochMillis)
        .put("costUSD", finite(week.costUSD))
        .put("sessions", week.sessions)

    private fun decodeWeek(obj: JSONObject) = RecapWeekHighlight(
        startDayIndex = obj.optInt("startDayIndex", 0),
        endDayIndex = obj.optInt("endDayIndex", 0),
        startEpochMillis = obj.optLong("startEpochMillis", 0L),
        endEpochMillis = obj.optLong("endEpochMillis", 0L),
        costUSD = obj.optDouble("costUSD", 0.0),
        sessions = obj.optInt("sessions", 0),
    )

    private fun optNullableInt(obj: JSONObject, key: String): Int? = if (obj.has(key)) obj.optInt(key) else null
}

/** JSON codec for every [RecapVisualData] variant, tagged by `type`. */
internal object RecapVisualDataCodec {
    fun encode(data: RecapVisualData): JSONObject = when (data) {
        is RecapVisualData.Series -> tagged("series").put("values", doubles(data.values))
        is RecapVisualData.DualSeries ->
            tagged("dualSeries").put("current", doubles(data.current)).put("reference", doubles(data.reference))
        is RecapVisualData.Ranked ->
            tagged("ranked").put(
                "entries",
                JSONArray(
                    data.entries.map { e ->
                        JSONObject().apply {
                            put("key", e.key)
                            put("label", e.label)
                            put("value", finite(e.value))
                            put("fraction", finite(e.fraction))
                            e.colorSeed?.let { put("colorSeed", it) }
                        }
                    },
                ),
            )
        is RecapVisualData.Matrix -> tagged("matrix").put("matrix", JSONArray(data.matrix.map(::doubles)))
        is RecapVisualData.Rings ->
            tagged("rings").put(
                "values",
                JSONArray(
                    data.values.map {
                        JSONObject().put("label", it.label).put("progress", finite(it.progress)).put("caption", it.caption)
                    },
                ),
            )
        is RecapVisualData.Pair -> tagged("pair").put("before", finite(data.before)).put("after", finite(data.after))
        is RecapVisualData.Streak -> tagged("streak").put("flags", JSONArray(data.flags))
    }

    fun decode(obj: JSONObject?): RecapVisualData? = when (obj?.optString("type")) {
        "series" -> RecapVisualData.Series(decodeDoubles(obj.optJSONArray("values")))
        "dualSeries" ->
            RecapVisualData.DualSeries(decodeDoubles(obj.optJSONArray("current")), decodeDoubles(obj.optJSONArray("reference")))
        "ranked" ->
            RecapVisualData.Ranked(
                decodeObjects(obj.optJSONArray("entries")) {
                    RecapRankedEntry(
                        key = it.optString("key"),
                        label = it.optString("label"),
                        value = it.optDouble("value", 0.0),
                        fraction = it.optDouble("fraction", 0.0),
                        colorSeed = if (it.has("colorSeed")) it.optString("colorSeed") else null,
                    )
                },
            )
        "matrix" -> RecapVisualData.Matrix(decodeList(obj.optJSONArray("matrix")) { a, i -> decodeDoubles(a.optJSONArray(i)) })
        "rings" ->
            RecapVisualData.Rings(
                decodeObjects(obj.optJSONArray("values")) {
                    RecapRingValue(label = it.optString("label"), progress = it.optDouble("progress", 0.0), caption = it.optString("caption"))
                },
            )
        "pair" -> RecapVisualData.Pair(obj.optDouble("before", 0.0), obj.optDouble("after", 0.0))
        "streak" -> RecapVisualData.Streak(decodeList(obj.optJSONArray("flags")) { a, i -> a.optBoolean(i) })
        else -> null
    }

    private fun tagged(type: String) = JSONObject().put("type", type)
}

/** JSON rejects NaN and infinities; persist those as zero. */
private fun finite(value: Double): Double = if (value.isFinite()) value else 0.0

private fun doubles(values: List<Double>) = JSONArray(values.map(::finite))

private fun decodeDoubles(arr: JSONArray?): List<Double> = decodeList(arr) { a, i -> a.optDouble(i, 0.0) }

private inline fun <T> decodeList(arr: JSONArray?, element: (JSONArray, Int) -> T): List<T> =
    if (arr == null) emptyList() else List(arr.length()) { element(arr, it) }

private inline fun <T> decodeObjects(arr: JSONArray?, element: (JSONObject) -> T): List<T> =
    if (arr == null) emptyList() else (0 until arr.length()).mapNotNull { i -> arr.optJSONObject(i)?.let(element) }
