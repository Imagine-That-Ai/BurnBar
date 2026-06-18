package com.openburnbar.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Buckets must be BYTE-IDENTICAL to AnalyticsBuckets.swift / buckets.ts. These
 * assertions pin every boundary so a drift in any of the three implementations
 * fails CI on the platform that drifted.
 */
class AnalyticsBucketsTest {

    @Test
    fun durationMsBoundaries() {
        assertEquals("<100ms", AnalyticsBuckets.durationMs(0))
        assertEquals("<100ms", AnalyticsBuckets.durationMs(99))
        assertEquals("100-500ms", AnalyticsBuckets.durationMs(100))
        assertEquals("100-500ms", AnalyticsBuckets.durationMs(499))
        assertEquals("500ms-1s", AnalyticsBuckets.durationMs(500))
        assertEquals("500ms-1s", AnalyticsBuckets.durationMs(999))
        assertEquals("1-3s", AnalyticsBuckets.durationMs(1_000))
        assertEquals("1-3s", AnalyticsBuckets.durationMs(2_999))
        assertEquals("3-10s", AnalyticsBuckets.durationMs(3_000))
        assertEquals("3-10s", AnalyticsBuckets.durationMs(9_999))
        assertEquals("10-30s", AnalyticsBuckets.durationMs(10_000))
        assertEquals("10-30s", AnalyticsBuckets.durationMs(29_999))
        assertEquals(">30s", AnalyticsBuckets.durationMs(30_000))
        assertEquals(">30s", AnalyticsBuckets.durationMs(1_000_000))
    }

    @Test
    fun countBoundaries() {
        assertEquals("0", AnalyticsBuckets.count(0))
        assertEquals("0", AnalyticsBuckets.count(-5)) // negatives clamp to 0
        assertEquals("1", AnalyticsBuckets.count(1))
        assertEquals("2-5", AnalyticsBuckets.count(2))
        assertEquals("2-5", AnalyticsBuckets.count(5))
        assertEquals("6-20", AnalyticsBuckets.count(6))
        assertEquals("6-20", AnalyticsBuckets.count(20))
        assertEquals("21-100", AnalyticsBuckets.count(21))
        assertEquals("21-100", AnalyticsBuckets.count(100))
        assertEquals("101-500", AnalyticsBuckets.count(101))
        assertEquals("101-500", AnalyticsBuckets.count(500))
        assertEquals(">500", AnalyticsBuckets.count(501))
    }

    @Test
    fun amountUSDBoundaries() {
        assertEquals("0", AnalyticsBuckets.amountUSD(0.0))
        assertEquals("0", AnalyticsBuckets.amountUSD(-2.0))
        assertEquals("<1", AnalyticsBuckets.amountUSD(0.5))
        assertEquals("<1", AnalyticsBuckets.amountUSD(0.999))
        assertEquals("1-10", AnalyticsBuckets.amountUSD(1.0))
        assertEquals("1-10", AnalyticsBuckets.amountUSD(9.99))
        assertEquals("10-50", AnalyticsBuckets.amountUSD(10.0))
        assertEquals("50-100", AnalyticsBuckets.amountUSD(50.0))
        assertEquals("100-500", AnalyticsBuckets.amountUSD(100.0))
        assertEquals(">500", AnalyticsBuckets.amountUSD(500.0))
        assertEquals(">500", AnalyticsBuckets.amountUSD(99_999.0))
    }

    @Test
    fun percentBoundaries() {
        assertEquals("0-10", AnalyticsBuckets.percent(0.0))
        assertEquals("0-10", AnalyticsBuckets.percent(9.99))
        assertEquals("10-25", AnalyticsBuckets.percent(10.0))
        assertEquals("25-50", AnalyticsBuckets.percent(25.0))
        assertEquals("50-75", AnalyticsBuckets.percent(50.0))
        assertEquals("75-90", AnalyticsBuckets.percent(75.0))
        assertEquals("90-100", AnalyticsBuckets.percent(90.0))
        assertEquals("90-100", AnalyticsBuckets.percent(100.0))
    }

    @Test
    fun sizeBytesBoundaries() {
        assertEquals("<1KB", AnalyticsBuckets.sizeBytes(0))
        assertEquals("<1KB", AnalyticsBuckets.sizeBytes(999))
        assertEquals("1-100KB", AnalyticsBuckets.sizeBytes(1_000))
        assertEquals("1-100KB", AnalyticsBuckets.sizeBytes(99_999))
        assertEquals("100KB-1MB", AnalyticsBuckets.sizeBytes(100_000))
        assertEquals("1-10MB", AnalyticsBuckets.sizeBytes(1_000_000))
        assertEquals("10-100MB", AnalyticsBuckets.sizeBytes(10_000_000))
        assertEquals(">100MB", AnalyticsBuckets.sizeBytes(100_000_000))
    }

    @Test
    fun durationSecondsBoundaries() {
        assertEquals("<5s", AnalyticsBuckets.durationSeconds(0.0))
        assertEquals("<5s", AnalyticsBuckets.durationSeconds(4.99))
        assertEquals("5-30s", AnalyticsBuckets.durationSeconds(5.0))
        assertEquals("30s-2m", AnalyticsBuckets.durationSeconds(30.0))
        assertEquals("2-10m", AnalyticsBuckets.durationSeconds(120.0))
        assertEquals("10-60m", AnalyticsBuckets.durationSeconds(600.0))
        assertEquals(">60m", AnalyticsBuckets.durationSeconds(3_600.0))
    }

    @Test
    fun durationMsDoubleRoundsBeforeBucketing() {
        assertEquals("<100ms", AnalyticsBuckets.durationMs(99.4))
        assertEquals("100-500ms", AnalyticsBuckets.durationMs(99.6)) // rounds to 100
    }
}
