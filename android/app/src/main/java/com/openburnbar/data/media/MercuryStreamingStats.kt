package com.openburnbar.data.media

enum class MercuryThermalState {
    NOMINAL,
    FAIR,
    SERIOUS,
    CRITICAL,
    UNKNOWN,
}

enum class MercuryContentMode {
    UNKNOWN,
    SCREEN_TEXT,
    SCREEN_MIXED,
    SCREEN_VIDEO,
    VIDEO_CALL,
}

data class MercuryRuntimeHealthSnapshot(
    val timestampMillis: Long,
    val cpuUsagePercent: Double? = null,
    val batteryLevelPercent: Double? = null,
    val isCharging: Boolean? = null,
    val isLowPowerModeEnabled: Boolean? = null,
    val thermalState: MercuryThermalState = MercuryThermalState.UNKNOWN,
)

data class MercuryRtcStatsSnapshot(
    val timestampMillis: Long,
    val codec: MercuryVideoCodec? = null,
    val wireVersion: MercuryMediaFrameWireVersion = MercuryMediaFrameWireVersion.V1,
    val targetBitsPerSecond: Int? = null,
    val actualBitsPerSecond: Int? = null,
    val pacerQueueDepth: Int? = null,
    val decodedFramesPerSecond: Double? = null,
    val presentTimeErrorMillis: Double? = null,
    val freezeCount: Int = 0,
    val longTermReferenceRecoveries: Int = 0,
    val fecRecoveredBytes: Int = 0,
    val idrFallbacks: Int = 0,
    val gopLossRate: Double? = null,
    val roundTripMillis: Int? = null,
    val packetLossRate: Double? = null,
    val networkJitterMillis: Double? = null,
    val contentMode: MercuryContentMode = MercuryContentMode.UNKNOWN,
    val runtimeHealth: MercuryRuntimeHealthSnapshot? = null,
)

data class MercuryImpairmentScenario(
    val packetLossPercent: Double,
    val roundTripMillis: Int,
) {
    companion object {
        val DEFAULT_MATRIX = listOf(
            MercuryImpairmentScenario(0.0, 30),
            MercuryImpairmentScenario(0.0, 100),
            MercuryImpairmentScenario(0.0, 300),
            MercuryImpairmentScenario(1.0, 30),
            MercuryImpairmentScenario(1.0, 100),
            MercuryImpairmentScenario(1.0, 300),
            MercuryImpairmentScenario(3.0, 30),
            MercuryImpairmentScenario(3.0, 100),
            MercuryImpairmentScenario(3.0, 300),
            MercuryImpairmentScenario(5.0, 30),
            MercuryImpairmentScenario(5.0, 100),
            MercuryImpairmentScenario(5.0, 300),
            MercuryImpairmentScenario(10.0, 30),
            MercuryImpairmentScenario(10.0, 100),
            MercuryImpairmentScenario(10.0, 300),
        )
    }
}
