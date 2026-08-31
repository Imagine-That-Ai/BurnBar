package com.openburnbar.support

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.sqrt

internal object ShakeDetectionPolicy {
    const val THRESHOLD_GRAVITY = 2.7f
    const val SLOP_TIME_MS = 500L

    fun gForce(x: Float, y: Float, z: Float): Float = sqrt((x * x + y * y + z * z).toDouble()).toFloat()

    fun isShake(x: Float, y: Float, z: Float): Boolean = gForce(x, y, z) > THRESHOLD_GRAVITY

    fun shouldRegisterShake(nowMs: Long, lastShakeMs: Long): Boolean = lastShakeMs + SLOP_TIME_MS <= nowMs
}

class ShakeDetector(
    private val onShake: () -> Unit,
) : SensorEventListener {
    private var shakeTimestamp: Long = 0

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null) return
        val x = event.values[0] / SensorManager.GRAVITY_EARTH
        val y = event.values[1] / SensorManager.GRAVITY_EARTH
        val z = event.values[2] / SensorManager.GRAVITY_EARTH
        if (!ShakeDetectionPolicy.isShake(x, y, z)) return
        val now = System.currentTimeMillis()
        if (!ShakeDetectionPolicy.shouldRegisterShake(nowMs = now, lastShakeMs = shakeTimestamp)) {
            return
        }
        shakeTimestamp = now
        onShake()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
