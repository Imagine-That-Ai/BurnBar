package com.openburnbar.data.media

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test

class PacerTest {

    @Test
    fun first_pace_within_burst_returns_immediately() = runTest {
        val pacer = Pacer(
            initialTargetBitsPerSecond = 8_000,
            initialBurstBitsPerSecond = 80_000,
        )
        val started = System.nanoTime()
        pacer.pace(byteCount = 1_000) // 8_000 bits inside the 80_000-bit burst
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertTrue(
            "expected near-zero latency, got ${elapsedMillis}ms",
            elapsedMillis < 250,
        )
    }

    @Test
    fun second_pace_within_burst_still_returns_quickly() = runTest {
        val pacer = Pacer(
            initialTargetBitsPerSecond = 8_000,
            initialBurstBitsPerSecond = 80_000,
        )
        pacer.pace(byteCount = 1_000)
        val started = System.nanoTime()
        pacer.pace(byteCount = 1_000)
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertTrue(
            "fair-share should keep latency low, got ${elapsedMillis}ms",
            elapsedMillis < 350,
        )
    }

    @Test
    fun setting_target_higher_releases_subsequent_burst() = runTest {
        val pacer = Pacer(
            initialTargetBitsPerSecond = 8_000,
            initialBurstBitsPerSecond = 64_000,
        )
        pacer.setTargetBitsPerSecond(800_000)
        pacer.setBurstBitsPerSecond(8_000_000)
        val started = System.nanoTime()
        pacer.pace(byteCount = 8_000)
        val elapsedMillis = (System.nanoTime() - started) / 1_000_000
        assertTrue(
            "high target should permit fast emit, got ${elapsedMillis}ms",
            elapsedMillis < 300,
        )
    }
}
