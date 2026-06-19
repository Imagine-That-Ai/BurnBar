package com.openburnbar.analytics

/**
 * Anti-fingerprinting bucketing. Raw counts/durations/amounts are never sent;
 * they map to coarse, canonical buckets identical on every platform. Boundaries
 * are ported verbatim from AgentLens/Services/Analytics/AnalyticsBuckets.swift
 * (and website/src/lib/analytics/buckets.ts) and mirrored in
 * docs/analytics/event-taxonomy.md — keep all of them in sync.
 */
object AnalyticsBuckets {

    fun durationMs(ms: Int): String = when {
        ms < 100 -> "<100ms"
        ms < 500 -> "100-500ms"
        ms < 1_000 -> "500ms-1s"
        ms < 3_000 -> "1-3s"
        ms < 10_000 -> "3-10s"
        ms < 30_000 -> "10-30s"
        else -> ">30s"
    }

    fun durationMs(ms: Double): String = durationMs(Math.round(ms).toInt())

    fun count(n: Int): String = when {
        n < 1 -> "0" // 0 and negatives clamp to "0"
        n == 1 -> "1"
        n <= 5 -> "2-5"
        n <= 20 -> "6-20"
        n <= 100 -> "21-100"
        n <= 500 -> "101-500"
        else -> ">500"
    }

    fun amountUSD(usd: Double): String = when {
        usd <= 0.0 -> "0"
        usd < 1.0 -> "<1"
        usd < 10.0 -> "1-10"
        usd < 50.0 -> "10-50"
        usd < 100.0 -> "50-100"
        usd < 500.0 -> "100-500"
        else -> ">500"
    }

    fun percent(p: Double): String = when {
        p < 10.0 -> "0-10"
        p < 25.0 -> "10-25"
        p < 50.0 -> "25-50"
        p < 75.0 -> "50-75"
        p < 90.0 -> "75-90"
        else -> "90-100"
    }

    fun sizeBytes(b: Int): String = when {
        b < 1_000 -> "<1KB"
        b < 100_000 -> "1-100KB"
        b < 1_000_000 -> "100KB-1MB"
        b < 10_000_000 -> "1-10MB"
        b < 100_000_000 -> "10-100MB"
        else -> ">100MB"
    }

    fun durationSeconds(s: Double): String = when {
        s < 5.0 -> "<5s"
        s < 30.0 -> "5-30s"
        s < 120.0 -> "30s-2m"
        s < 600.0 -> "2-10m"
        s < 3_600.0 -> "10-60m"
        else -> ">60m"
    }
}
