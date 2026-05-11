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
            when (type) {
                HapticType.LIGHT -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
                HapticType.MEDIUM -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
                HapticType.HEAVY -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
                // SUCCESS upgraded to HEAVY_CLICK for parity with iOS UINotificationFeedbackGenerator(.success)
                HapticType.SUCCESS -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
                HapticType.ERROR -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
                HapticType.SELECTION -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
                HapticType.TAB_CHANGE -> vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
                // Custom 4-tap warning waveform — matches the iOS warning notification's pulsed feel.
                HapticType.WARNING -> vibrator.vibrate(
                    VibrationEffect.createWaveform(
                        longArrayOf(0L, 50L, 100L, 50L),
                        intArrayOf(0, 200, 0, 100),
                        -1
                    )
                )
            }
        } else {
            @Suppress("DEPRECATION")
            val millis = when (type) {
                HapticType.LIGHT -> 10L
                HapticType.MEDIUM -> 20L
                HapticType.HEAVY -> 30L
                HapticType.SUCCESS -> 20L
                HapticType.ERROR -> 40L
                HapticType.SELECTION -> 5L
                HapticType.TAB_CHANGE -> 15L
                HapticType.WARNING -> 35L
            }
            vibrator.vibrate(millis)
        }
    }

    // Convenience methods
    fun light(context: Context) = perform(context, HapticType.LIGHT)
    fun medium(context: Context) = perform(context, HapticType.MEDIUM)
    fun heavy(context: Context) = perform(context, HapticType.HEAVY)
    fun success(context: Context) = perform(context, HapticType.SUCCESS)
    fun warning(context: Context) = perform(context, HapticType.WARNING)
    fun error(context: Context) = perform(context, HapticType.ERROR)
    fun selection(context: Context) = perform(context, HapticType.SELECTION)
    fun tabChange(context: Context) = perform(context, HapticType.TAB_CHANGE)
}

enum class HapticType {
    LIGHT,
    MEDIUM,
    HEAVY,
    SUCCESS,
    WARNING,
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
    fun warning() = HapticBus.warning(context)
    fun error() = HapticBus.error(context)
    fun selection() = HapticBus.selection(context)
    fun tabChange() = HapticBus.tabChange(context)
}
