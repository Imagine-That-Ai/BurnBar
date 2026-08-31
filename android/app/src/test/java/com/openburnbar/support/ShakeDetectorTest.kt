package com.openburnbar.support

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShakeDetectorTest {
    @Test
    fun restPoseIsBelowShakeThreshold() {
        assertFalse(ShakeDetectionPolicy.isShake(x = 0f, y = 0f, z = 1f))
        assertEquals(1.0f, ShakeDetectionPolicy.gForce(x = 0f, y = 0f, z = 1f), 0.0001f)
    }

    @Test
    fun strongImpulseIsAShake() {
        assertTrue(ShakeDetectionPolicy.isShake(x = 2.0f, y = 2.0f, z = 2.0f))
    }

    @Test
    fun slopWindowSuppressesRapidRepeats() {
        val firstShakeAt = 1_000L
        assertTrue(ShakeDetectionPolicy.shouldRegisterShake(nowMs = firstShakeAt, lastShakeMs = 0L))
        assertFalse(
            ShakeDetectionPolicy.shouldRegisterShake(
                nowMs = firstShakeAt + ShakeDetectionPolicy.SLOP_TIME_MS - 1,
                lastShakeMs = firstShakeAt,
            ),
        )
        assertTrue(
            ShakeDetectionPolicy.shouldRegisterShake(
                nowMs = firstShakeAt + ShakeDetectionPolicy.SLOP_TIME_MS,
                lastShakeMs = firstShakeAt,
            ),
        )
    }
}
