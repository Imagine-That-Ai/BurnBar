
package com.openburnbar.data.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MercuryStreamingStatsTest {
    @Test
    fun rtc_stats_snapshot_carries_benchmark_fields() {
        val health =
            MercuryRuntimeHealthSnapshot(
                timestampMillis = 1_777_000,
                cpuUsagePercent = 42.5,
                batteryLevelPercent = 81.0,
                isCharging = true,
                isLowPowerModeEnabled = false,
                thermalState = MercuryThermalState.FAIR,
            )
        val stats =
            MercuryRtcStatsSnapshot(
                timestampMillis = 1_777_001,
                codec = MercuryVideoCodec.HEVC,
                wireVersion = MercuryMediaFrameWireVersion.V2,
                targetBitsPerSecond = 4_000_000,
                actualBitsPerSecond = 3_800_000,
                pacerQueueDepth = 2,
                decodedFramesPerSecond = 59.7,
                presentTimeErrorMillis = 3.5,
                freezeCount = 1,
                longTermReferenceRecoveries = 2,
                fecRecoveredBytes = 1_024,
                idrFallbacks = 1,
                gopLossRate = 0.03,
                roundTripMillis = 80,
                packetLossRate = 0.01,
                networkJitterMillis = 7.5,
                contentMode = MercuryContentMode.SCREEN_TEXT,
                runtimeHealth = health,
            )

        assertEquals(MercuryVideoCodec.HEVC, stats.codec)
        assertEquals(MercuryThermalState.FAIR, stats.runtimeHealth?.thermalState)
        assertEquals(1, stats.freezeCount)
    }

    @Test
    fun default_impairment_matrix_matches_launch_gate_shape() {
        assertEquals(15, MercuryImpairmentScenario.DEFAULT_MATRIX.size)
        assertTrue(MercuryImpairmentScenario.DEFAULT_MATRIX.contains(MercuryImpairmentScenario(10.0, 300)))
    }
}
