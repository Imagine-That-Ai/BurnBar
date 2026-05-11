package com.openburnbar.ui.components

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Semantic haptic wrapper for consistent tactile feedback across the app.
 * Mirrors the iOS HapticBus pattern with lightweight, medium, and heavy impacts,
 * plus selection changes and success/error patterns.
 */

object HapticBus {

    fun perform(context: Context, type: HapticType) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = when (type) {
                HapticType.LIGHT -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
                HapticType.MEDIUM -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
                HapticType.HEAVY -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK)
                HapticType.SUCCESS -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
                HapticType.ERROR -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK)
                HapticType.SELECTION -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
                HapticType.TAB_CHANGE -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
            }
            vibrator.vibrate(effect)
        } else {
            @Suppress("DEPRECATION")
            val millis = when (type) {
                HapticType.LIGHT -> 10L
                HapticType.MEDIUM -> 20L
                HapticType.HEAVY -> 30L
                HapticType.SUCCESS -> 15L
                HapticType.ERROR -> 40L
                HapticType.SELECTION -> 5L
                HapticType.TAB_CHANGE -> 15L
            }
            vibrator.vibrate(millis)
        }
    }

    // Convenience methods
    fun light(context: Context) = perform(context, HapticType.LIGHT)
    fun medium(context: Context) = perform(context, HapticType.MEDIUM)
    fun heavy(context: Context) = perform(context, HapticType.HEAVY)
    fun success(context: Context) = perform(context, HapticType.SUCCESS)
    fun error(context: Context) = perform(context, HapticType.ERROR)
    fun selection(context: Context) = perform(context, HapticType.SELECTION)
    fun tabChange(context: Context) = perform(context, HapticType.TAB_CHANGE)
}

enum class HapticType {
    LIGHT,
    MEDIUM,
    HEAVY,
    SUCCESS,
    ERROR,
    SELECTION,
    TAB_CHANGE
}

@Composable
fun rememberHapticBus(): HapticBusHandle {
    val context = LocalContext.current
    return remember { HapticBusHandle(context) }
}

class HapticBusHandle(private val context: Context) {
    fun light() = HapticBus.light(context)
    fun medium() = HapticBus.medium(context)
    fun heavy() = HapticBus.heavy(context)
    fun success() = HapticBus.success(context)
    fun error() = HapticBus.error(context)
    fun selection() = HapticBus.selection(context)
    fun tabChange() = HapticBus.tabChange(context)
}
