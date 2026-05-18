package com.openburnbar.data.media

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Outbound media pacer. 1:1 port of the iOS `Pacer` (the master plan
 * § E.7 calls for one). Smooths per-GOP send bursts into a target
 * bytes-per-second send rate so a 5 Mbps HEVC encoder doesn't dump a
 * 600 KB keyframe into the iroh stream as a single 5 ms blast that
 * stalls the relay.
 *
 * Implementation: token bucket. Tokens accrue at `targetBitsPerSecond`;
 * each `pace(byteCount)` call subtracts proportional tokens and blocks
 * until the bucket has enough. The bucket cap is `burstBitsPerSecond /
 * 8` so transient bursts up to one second's worth of payload are
 * allowed.
 */
class Pacer(
    initialTargetBitsPerSecond: Int = 4_000_000,
    initialBurstBitsPerSecond: Int = 8_000_000,
) {
    private val mutex = Mutex()
    private var lastRefillNanos: Long = System.nanoTime()
    private var availableBytes: Double = (initialBurstBitsPerSecond / 8).toDouble()
    private var targetBytesPerSecond: Double = initialTargetBitsPerSecond / 8.0
    private var burstBytes: Double = (initialBurstBitsPerSecond / 8).toDouble()

    suspend fun setTargetBitsPerSecond(bps: Int) {
        mutex.withLock { targetBytesPerSecond = (bps / 8).toDouble() }
    }

    suspend fun setBurstBitsPerSecond(bps: Int) {
        mutex.withLock { burstBytes = (bps / 8).toDouble() }
    }

    /**
     * Blocks the caller until at least `byteCount` bytes can be released.
     * Honours coroutine cancellation while waiting.
     */
    suspend fun pace(byteCount: Int) {
        val needed = byteCount.toDouble()
        while (true) {
            val waitNanos: Long = mutex.withLock {
                val now = System.nanoTime()
                val deltaSeconds = (now - lastRefillNanos).coerceAtLeast(0) / 1_000_000_000.0
                lastRefillNanos = now
                availableBytes = (availableBytes + deltaSeconds * targetBytesPerSecond).coerceAtMost(burstBytes)
                if (availableBytes >= needed) {
                    availableBytes -= needed
                    return@withLock 0L
                }
                val deficit = needed - availableBytes
                if (targetBytesPerSecond <= 0.0) Long.MAX_VALUE
                else (deficit / targetBytesPerSecond * 1_000_000_000.0).toLong().coerceAtMost(50_000_000L)
            }
            if (waitNanos <= 0L) return
            withContext(Dispatchers.Default) { delay(waitNanos / 1_000_000L) }
        }
    }
}
