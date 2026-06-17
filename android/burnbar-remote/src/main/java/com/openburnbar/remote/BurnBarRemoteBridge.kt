package com.openburnbar.remote

import java.util.concurrent.atomic.AtomicBoolean

private const val REMOTE_PROTOCOL_VERSION = "burnbar-remote/v1"

data class BurnBarRemoteReadiness(
    val protocolVersion: String,
    val supportsIrohTransport: Boolean,
    val supportsAdaptiveQuality: Boolean,
    val supportsPermissionGate: Boolean,
    val nativeBridgeAvailable: Boolean,
)

data class BurnBarRemoteDimensions(
    val width: UInt,
    val height: UInt,
) {
    init {
        require(width > 0u && height > 0u) {
            "BurnBar remote dimensions must be non-zero; got ${width}x$height"
        }
    }
}

enum class BurnBarRemoteSessionMode {
    ViewOnly,
    Control,
    AgentObserve,
    AgentAssist,
}

enum class BurnBarRemotePermission {
    ViewScreen,
    HearAudio,
    InjectInput,
    ClipboardRead,
    ClipboardWrite,
    TransferFiles,
    SystemControl,
    ElevateControl,
    AuditExport,
}

object BurnBarRemoteBridge {
    @Volatile private var cachedAvailability: Boolean? = null

    fun readiness(): BurnBarRemoteReadiness = BurnBarRemoteReadiness(
        protocolVersion = REMOTE_PROTOCOL_VERSION,
        supportsIrohTransport = true,
        supportsAdaptiveQuality = true,
        supportsPermissionGate = true,
        nativeBridgeAvailable = isNativeAvailable(),
    )

    fun isNativeAvailable(): Boolean {
        if (isAndroidRuntime() && !BurnBarRemoteNativeContext.ensureLoaded()) {
            return false
        }
        cachedAvailability?.let { return it }
        val ok =
            try {
                Class.forName("uniffi.burnbar_remote.BurnBarRemoteQualityController")
                true
            } catch (_: Throwable) {
                false
            }
        cachedAvailability = ok
        return ok
    }

    fun scaledDimensions(dimensions: BurnBarRemoteDimensions, numerator: UInt, denominator: UInt): BurnBarRemoteDimensions {
        val divisor = denominator.toULong().coerceAtLeast(1u)
        val width =
            ((dimensions.width.toULong() * numerator.toULong()) / divisor)
                .coerceAtLeast(1u)
                .coerceAtMost(UInt.MAX_VALUE.toULong())
                .toUInt()
        val height =
            ((dimensions.height.toULong() * numerator.toULong()) / divisor)
                .coerceAtLeast(1u)
                .coerceAtMost(UInt.MAX_VALUE.toULong())
                .toUInt()
        return BurnBarRemoteDimensions(width = width, height = height)
    }

    fun modeRequiresPermission(mode: BurnBarRemoteSessionMode, permission: BurnBarRemotePermission): Boolean = when (mode) {
        BurnBarRemoteSessionMode.ViewOnly,
        BurnBarRemoteSessionMode.AgentObserve,
        -> permission == BurnBarRemotePermission.ViewScreen

        BurnBarRemoteSessionMode.Control,
        BurnBarRemoteSessionMode.AgentAssist,
        -> permission == BurnBarRemotePermission.ViewScreen ||
            permission == BurnBarRemotePermission.InjectInput
    }

    private fun isAndroidRuntime(): Boolean = System.getProperty("java.runtime.name")?.contains("Android", ignoreCase = true) == true ||
        System.getProperty("java.vm.vendor")?.contains("Android", ignoreCase = true) == true
}

object BurnBarRemoteNativeContext {
    private val loaded = AtomicBoolean(false)

    fun ensureLoaded(): Boolean {
        if (loaded.get()) return true
        return try {
            System.loadLibrary("burnbar_remote")
            loaded.set(true)
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun isLoaded(): Boolean = loaded.get()
}
