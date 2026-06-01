@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.media

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MILLIS = 250
private const val MILLIS_2 = 350
private const val MILLIS_3 = 300
private const val NANOS_PER_MILLIS = 1_000_000
private const val SECONDS = 800_000
private const val SECONDS_2 = 8_000_000

class PacerTest {
    @Test
    fun first_pace_within_burst_returns_immediately() = runTest {
        val pacer =
            Pacer(
                initialTargetBitsPerSecond = 8_000,
                initialBurstBitsPerSecond = 80_000,
            )
        val started = System.nanoTime()
        pacer.pace(byteCount = 1_000) // 8_000 bits inside the 80_000-bit burst
        val elapsedMillis = (System.nanoTime() - started) / NANOS_PER_MILLIS
        assertTrue(
            "expected near-zero latency, got ${elapsedMillis}ms",
            elapsedMillis < MILLIS,
        )
    }

    @Test
    fun second_pace_within_burst_still_returns_quickly() = runTest {
        val pacer =
            Pacer(
                initialTargetBitsPerSecond = 8_000,
                initialBurstBitsPerSecond = 80_000,
            )
        pacer.pace(byteCount = 1_000)
        val started = System.nanoTime()
        pacer.pace(byteCount = 1_000)
        val elapsedMillis = (System.nanoTime() - started) / NANOS_PER_MILLIS
        assertTrue(
            "fair-share should keep latency low, got ${elapsedMillis}ms",
            elapsedMillis < MILLIS_2,
        )
    }

    @Test
    fun setting_target_higher_releases_subsequent_burst() = runTest {
        val pacer =
            Pacer(
                initialTargetBitsPerSecond = 8_000,
                initialBurstBitsPerSecond = 64_000,
            )
        pacer.setTargetBitsPerSecond(SECONDS)
        pacer.setBurstBitsPerSecond(SECONDS_2)
        val started = System.nanoTime()
        pacer.pace(byteCount = 8_000)
        val elapsedMillis = (System.nanoTime() - started) / NANOS_PER_MILLIS
        assertTrue(
            "high target should permit fast emit, got ${elapsedMillis}ms",
            elapsedMillis < MILLIS_3,
        )
    }
}
