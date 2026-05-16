package com.openburnbar.data.media

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Receiver-driven bandwidth-estimation ceiling for Mercury video streams.
 * Trimmed Kotlin port of the iOS `BitrateController` + plan § E.7
 * `BweEstimator`. Delay-based loss detection plus a slow-start ramp.
 *
 * Receiver computes the target ceiling every 200 ms (caller cadence)
 * and feeds it back to the encoder over the `media.control` stream as
 * a `BweFeedback` frame; the encoder treats the value as a hard cap so
 * producer-side pacing stays coupled to whatever the network is
 * actually swallowing.
 */
class BweEstimator(
    val steps: List<Int>,
    val rttDownAdaptThresholdMillis: Int = 200,
    val lossDownAdaptThreshold: Double = 0.04,
    val recoveryHysteresisSamples: Int = 3,
) {
    init {
        require(steps.isNotEmpty()) { "BweEstimator requires at least one step" }
    }

    private val sortedSteps: List<Int> = steps.sorted()
    var currentBitsPerSecond: Int = sortedSteps.last()
        private set
    private var goodSamplesSinceDownAdapt: Int = 0

    data class Sample(
        val roundTripMillis: Int,
        val packetLossRate: Double, // 0.0 ... 1.0
        val observedBitsPerSecond: Int,
    )

    fun apply(sample: Sample): Int {
        if (sample.roundTripMillis >= rttDownAdaptThresholdMillis ||
            sample.packetLossRate >= lossDownAdaptThreshold
        ) {
            stepDown()
            goodSamplesSinceDownAdapt = 0
            return currentBitsPerSecond
        }

        goodSamplesSinceDownAdapt += 1
        if (goodSamplesSinceDownAdapt >= recoveryHysteresisSamples) {
            stepUp()
            goodSamplesSinceDownAdapt = 0
        }
        return currentBitsPerSecond
    }

    private fun stepDown() {
        val idx = sortedSteps.indexOf(currentBitsPerSecond)
        currentBitsPerSecond = if (idx < 0) sortedSteps.first() else sortedSteps[max(0, idx - 1)]
    }

    private fun stepUp() {
        val idx = sortedSteps.indexOf(currentBitsPerSecond)
        currentBitsPerSecond = if (idx < 0) sortedSteps.last() else sortedSteps[min(sortedSteps.size - 1, idx + 1)]
    }

    @Suppress("unused")
    fun gccDecayConstant(rttMillis: Int): Double = (1.0 - 0.5).pow(rttMillis.toDouble() / 1000.0)

    companion object {
        val SCREEN_SHARE_STEPS = listOf(1_000_000, 2_000_000, 4_000_000, 8_000_000)
        val VIDEO_CALL_STEPS = listOf(300_000, 600_000, 1_200_000)
    }
}
