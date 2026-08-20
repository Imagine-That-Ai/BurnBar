package com.openburnbar.ui.tokens

import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import kotlin.math.PI
import kotlin.math.min

/**
 * Native Jetpack Compose animation mapping for Pensieve motion tokens.
 *
 * Resolves response/damping tokens into Compose `spring(dampingRatio, stiffness)`.
 * Implements the Reduce Motion vocabulary: springs -> fades, stagger -> 0ms,
 * and ambient animations halted.
 */
object PensieveMotion {
    val settleResponseMs: Float = PensieveTokens.motionSettleResponseMs.toFloatOrNull() ?: 420f
    val settleDamping: Float = PensieveTokens.motionSettleDamping.toFloatOrNull() ?: 0.88f
    val arriveResponseMs: Float = PensieveTokens.motionArriveResponseMs.toFloatOrNull() ?: 340f
    val arriveDamping: Float = PensieveTokens.motionArriveDamping.toFloatOrNull() ?: 0.80f
    val arriveRisePx: Float = PensieveTokens.motionArriveRisePx.toFloatOrNull() ?: 18f
    val arriveScale: Float = PensieveTokens.motionArriveScale.toFloatOrNull() ?: 0.97f
    val departMs: Int = PensieveTokens.motionDepartMs.toIntOrNull() ?: 160
    val departScale: Float = PensieveTokens.motionDepartScale.toFloatOrNull() ?: 0.98f
    val staggerStepMs: Long = PensieveTokens.motionStaggerStepMs.toLongOrNull() ?: 60L
    val staggerCapMs: Long = PensieveTokens.motionStaggerCapMs.toLongOrNull() ?: 240L
    val tickMs: Int = PensieveTokens.motionTickMs.toIntOrNull() ?: 300
    val pulsePeriodMs: Int = PensieveTokens.motionPulsePeriodMs.toIntOrNull() ?: 1400
    val pulseFloor: Float = PensieveTokens.motionPulseFloor.toFloatOrNull() ?: 0.55f
    val reducedMs: Int = PensieveTokens.motionReducedMs.toIntOrNull() ?: 180

    // Stiffness k = (2 * PI / (responseMs / 1000))^2
    val settleStiffness: Float = calculateStiffness(settleResponseMs)
    val arriveStiffness: Float = calculateStiffness(arriveResponseMs)

    private fun calculateStiffness(responseMs: Float): Float {
        val omega = (2.0 * PI) / (responseMs / 1000.0)
        return (omega * omega).toFloat()
    }

    /**
     * Settle animation spec: Used when layout elements change size or position.
     * Damped harder than arrive to prevent wobble on plate edges.
     */
    fun <T> settleSpec(reduceMotion: Boolean = false): FiniteAnimationSpec<T> =
        if (reduceMotion) {
            tween(durationMillis = reducedMs, easing = FastOutSlowInEasing)
        } else {
            spring(dampingRatio = settleDamping, stiffness = settleStiffness)
        }

    /**
     * Arrive animation spec: Used for entering content.
     */
    fun <T> arriveSpec(reduceMotion: Boolean = false): FiniteAnimationSpec<T> =
        if (reduceMotion) {
            tween(durationMillis = reducedMs, easing = FastOutSlowInEasing)
        } else {
            spring(dampingRatio = arriveDamping, stiffness = arriveStiffness)
        }

    /**
     * Depart animation spec: Fast exit.
     */
    fun <T> departSpec(reduceMotion: Boolean = false): FiniteAnimationSpec<T> =
        tween(
            durationMillis = if (reduceMotion) reducedMs else departMs,
            easing = FastOutLinearInEasing,
        )

    /**
     * Tick spec: Numeric or value transitions inside stationary frames.
     */
    fun <T> tickSpec(reduceMotion: Boolean = false): FiniteAnimationSpec<T> =
        tween(
            durationMillis = if (reduceMotion) reducedMs else tickMs,
            easing = FastOutSlowInEasing,
        )

    /**
     * Stagger delay for index, capped at staggerCapMs. Under reduceMotion, delay is 0ms.
     */
    fun staggerDelay(index: Int, reduceMotion: Boolean = false): Long {
        if (reduceMotion || index <= 0) return 0L
        return min(index * staggerStepMs, staggerCapMs)
    }
}
