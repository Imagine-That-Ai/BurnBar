package com.openburnbar.analytics

/**
 * Anti-fingerprinting bucketing. Raw counts/durations/amounts are never sent;
 * they map to coarse, canonical buckets identical on every platform. Boundaries
 * are ported verbatim from AgentLens/Services/Analytics/AnalyticsBuckets.swift
 * (and website/src/lib/analytics/buckets.ts) and mirrored in
 * docs/analytics/event-taxonomy.md — keep all of them in sync.
 */
object AnalyticsBuckets {

    private const val HUNDRED_MS = 100
    private const val HALF_SECOND_MS = 500
    private const val ONE_SECOND_MS = 1_000
    private const val THREE_SECONDS_MS = 3_000
    private const val TEN_SECONDS_MS = 10_000
    private const val THIRTY_SECONDS_MS = 30_000

    private const val COUNT_SMALL_MAX = 5
    private const val COUNT_MEDIUM_MAX = 20
    private const val COUNT_LARGE_MAX = 100
    private const val COUNT_HUGE_MAX = 500

    private const val ONE_USD = 1.0
    private const val TEN_USD = 10.0
    private const val FIFTY_USD = 50.0
    private const val HUNDRED_USD = 100.0
    private const val FIVE_HUNDRED_USD = 500.0

    private const val PERCENT_10 = 10.0
    private const val PERCENT_25 = 25.0
    private const val PERCENT_50 = 50.0
    private const val PERCENT_75 = 75.0
    private const val PERCENT_90 = 90.0

    private const val ONE_KB = 1_000
    private const val HUNDRED_KB = 100_000
    private const val ONE_MB = 1_000_000
    private const val TEN_MB = 10_000_000
    private const val HUNDRED_MB = 100_000_000

    private const val FIVE_SECONDS = 5.0
    private const val THIRTY_SECONDS = 30.0
    private const val TWO_MINUTES_SECONDS = 120.0
    private const val TEN_MINUTES_SECONDS = 600.0
    private const val ONE_HOUR_SECONDS = 3_600.0

    fun durationMs(ms: Int): String = when {
        ms < HUNDRED_MS -> "<100ms"
        ms < HALF_SECOND_MS -> "100-500ms"
        ms < ONE_SECOND_MS -> "500ms-1s"
        ms < THREE_SECONDS_MS -> "1-3s"
        ms < TEN_SECONDS_MS -> "3-10s"
        ms < THIRTY_SECONDS_MS -> "10-30s"
        else -> ">30s"
    }

    fun durationMs(ms: Double): String = durationMs(Math.round(ms).toInt())

    fun count(n: Int): String = when {
        n < 1 -> "0" // 0 and negatives clamp to "0"
        n == 1 -> "1"
        n <= COUNT_SMALL_MAX -> "2-5"
        n <= COUNT_MEDIUM_MAX -> "6-20"
        n <= COUNT_LARGE_MAX -> "21-100"
        n <= COUNT_HUGE_MAX -> "101-500"
        else -> ">500"
    }

    fun amountUSD(usd: Double): String = when {
        usd <= 0.0 -> "0"
        usd < ONE_USD -> "<1"
        usd < TEN_USD -> "1-10"
        usd < FIFTY_USD -> "10-50"
        usd < HUNDRED_USD -> "50-100"
        usd < FIVE_HUNDRED_USD -> "100-500"
        else -> ">500"
    }

    fun percent(p: Double): String = when {
        p < PERCENT_10 -> "0-10"
        p < PERCENT_25 -> "10-25"
        p < PERCENT_50 -> "25-50"
        p < PERCENT_75 -> "50-75"
        p < PERCENT_90 -> "75-90"
        else -> "90-100"
    }

    fun sizeBytes(b: Int): String = when {
        b < ONE_KB -> "<1KB"
        b < HUNDRED_KB -> "1-100KB"
        b < ONE_MB -> "100KB-1MB"
        b < TEN_MB -> "1-10MB"
        b < HUNDRED_MB -> "10-100MB"
        else -> ">100MB"
    }

    fun durationSeconds(s: Double): String = when {
        s < FIVE_SECONDS -> "<5s"
        s < THIRTY_SECONDS -> "5-30s"
        s < TWO_MINUTES_SECONDS -> "30s-2m"
        s < TEN_MINUTES_SECONDS -> "2-10m"
        s < ONE_HOUR_SECONDS -> "10-60m"
        else -> ">60m"
    }
}
