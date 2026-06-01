package com.openburnbar.data.media

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock

object AndroidRuntimeHealthProbe {
    fun snapshot(
        context: Context,
        timestampMillis: Long = System.currentTimeMillis(),
        cpuUsagePercent: Double? = measuredCpuUsagePercent(),
    ): MercuryRuntimeHealthSnapshot {
        val appContext = context.applicationContext
        val batteryManager = appContext.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val batteryIntent = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return MercuryRuntimeHealthSnapshot(
            timestampMillis = timestampMillis,
            cpuUsagePercent = cpuUsagePercent,
            batteryLevelPercent = batteryLevelPercent(batteryManager, batteryIntent),
            isCharging = isCharging(batteryIntent),
            isLowPowerModeEnabled = powerManager?.isPowerSaveMode,
            thermalState = thermalState(powerManager),
        )
    }

    private fun batteryLevelPercent(manager: BatteryManager?, intent: Intent?): Double? {
        val property = manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (property != null && property >= 0) return property.toDouble()
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        if (level < 0 || scale <= 0) return null
        return level.toDouble() / scale.toDouble() * 100.0
    }

    private fun isCharging(intent: Intent?): Boolean? {
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING,
            BatteryManager.BATTERY_STATUS_FULL,
            -> true
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            BatteryManager.BATTERY_STATUS_NOT_CHARGING,
            -> false
            else -> null
        }
    }

    private fun thermalState(powerManager: PowerManager?): MercuryThermalState {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || powerManager == null) {
            return MercuryThermalState.UNKNOWN
        }
        return when (powerManager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> MercuryThermalState.NOMINAL
            PowerManager.THERMAL_STATUS_LIGHT -> MercuryThermalState.FAIR
            PowerManager.THERMAL_STATUS_MODERATE,
            PowerManager.THERMAL_STATUS_SEVERE,
            -> MercuryThermalState.SERIOUS
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN,
            -> MercuryThermalState.CRITICAL
            else -> MercuryThermalState.UNKNOWN
        }
    }

    private fun measuredCpuUsagePercent(): Double? {
        val processCpuMillis = Process.getElapsedCpuTime()
        val processUptimeMillis =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()
            } else {
                SystemClock.uptimeMillis()
            }
        if (processCpuMillis < 0 || processUptimeMillis <= 0) return null
        val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
        return (processCpuMillis.toDouble() / (processUptimeMillis.toDouble() * cores.toDouble()) * 100.0)
            .coerceIn(0.0, 100.0)
    }
}
