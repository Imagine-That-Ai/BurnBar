package com.openburnbar.data.computeruse

object PhoneControlSendRateLimiter {
    private const val WINDOW_MS = 1_000L
    private const val MAX_EVENTS = 30
    private val stamps = ArrayDeque<Long>()

    @Synchronized
    fun consume(nowMs: Long = System.currentTimeMillis()): Boolean {
        while (stamps.isNotEmpty() && nowMs - stamps.first() >= WINDOW_MS) {
            stamps.removeFirst()
        }
        if (stamps.size >= MAX_EVENTS) return false
        stamps.addLast(nowMs)
        return true
    }
}
