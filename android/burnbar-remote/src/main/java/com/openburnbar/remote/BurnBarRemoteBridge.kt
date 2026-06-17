package com.openburnbar.remote

import uniffi.burnbar_remote.burnbarRemoteReadiness
import uniffi.burnbar_remote.remoteModeRequiresPermission
import uniffi.burnbar_remote.remoteScaledDimensions
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import uniffi.burnbar_remote.RemoteDimensions as NativeRemoteDimensions
import uniffi.burnbar_remote.RemotePermission as NativeRemotePermission
import uniffi.burnbar_remote.RemoteReadiness as NativeRemoteReadiness
import uniffi.burnbar_remote.RemoteSessionMode as NativeRemoteSessionMode

private const val REMOTE_PROTOCOL_VERSION = "burnbar-remote/v1"
private const val NATIVE_LIBRARY_PATH_PROPERTY = "burnbar.remote.nativeLibraryPath"

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

    @Volatile private var lastNativeCallFailure: String? = null

    fun readiness(): BurnBarRemoteReadiness {
        nativeReadinessOrNull()?.let { readiness ->
            return BurnBarRemoteReadiness(
                protocolVersion = readiness.protocolVersion,
                supportsIrohTransport = readiness.supportsIrohTransport,
                supportsAdaptiveQuality = readiness.supportsAdaptiveQuality,
                supportsPermissionGate = readiness.supportsPermissionGate,
                nativeBridgeAvailable = true,
            )
        }

        return BurnBarRemoteReadiness(
            protocolVersion = REMOTE_PROTOCOL_VERSION,
            supportsIrohTransport = true,
            supportsAdaptiveQuality = true,
            supportsPermissionGate = true,
            nativeBridgeAvailable = false,
        )
    }

    fun isNativeAvailable(): Boolean {
        cachedAvailability?.let { return it }
        val ok = nativeReadinessOrNull(updateAvailabilityCache = false) != null
        cachedAvailability = ok
        return ok
    }

    fun scaledDimensions(
        dimensions: BurnBarRemoteDimensions,
        numerator: UInt,
        denominator: UInt,
    ): BurnBarRemoteDimensions =
        nativeScaledDimensionsOrNull(dimensions, numerator, denominator) ?: fallbackScaledDimensions(
            dimensions = dimensions,
            numerator = numerator,
            denominator = denominator,
        )

    fun modeRequiresPermission(
        mode: BurnBarRemoteSessionMode,
        permission: BurnBarRemotePermission,
    ): Boolean =
        nativeModeRequiresPermissionOrNull(mode, permission) ?: fallbackModeRequiresPermission(
            mode = mode,
            permission = permission,
        )

    private fun fallbackScaledDimensions(
        dimensions: BurnBarRemoteDimensions,
        numerator: UInt,
        denominator: UInt,
    ): BurnBarRemoteDimensions {
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

    private fun fallbackModeRequiresPermission(
        mode: BurnBarRemoteSessionMode,
        permission: BurnBarRemotePermission,
    ): Boolean =
        when (mode) {
            BurnBarRemoteSessionMode.ViewOnly,
            BurnBarRemoteSessionMode.AgentObserve,
            -> permission == BurnBarRemotePermission.ViewScreen

            BurnBarRemoteSessionMode.Control,
            BurnBarRemoteSessionMode.AgentAssist,
            ->
                permission == BurnBarRemotePermission.ViewScreen ||
                    permission == BurnBarRemotePermission.InjectInput
        }

    private fun nativeReadinessOrNull(updateAvailabilityCache: Boolean = true): NativeRemoteReadiness? {
        if (!BurnBarRemoteNativeContext.ensureLoaded()) {
            if (updateAvailabilityCache) cachedAvailability = false
            return null
        }
        return try {
            burnbarRemoteReadiness().also {
                lastNativeCallFailure = null
                if (updateAvailabilityCache) cachedAvailability = true
            }
        } catch (error: Throwable) {
            lastNativeCallFailure = "${error::class.java.simpleName}: ${error.message}"
            if (updateAvailabilityCache) cachedAvailability = false
            null
        }
    }

    private fun nativeScaledDimensionsOrNull(
        dimensions: BurnBarRemoteDimensions,
        numerator: UInt,
        denominator: UInt,
    ): BurnBarRemoteDimensions? {
        if (!isNativeAvailable()) return null
        return try {
            val scaled =
                remoteScaledDimensions(
                    dimensions = NativeRemoteDimensions(width = dimensions.width, height = dimensions.height),
                    numerator = numerator,
                    denominator = denominator,
                )
            BurnBarRemoteDimensions(width = scaled.width, height = scaled.height)
        } catch (_: Throwable) {
            null
        }
    }

    private fun nativeModeRequiresPermissionOrNull(
        mode: BurnBarRemoteSessionMode,
        permission: BurnBarRemotePermission,
    ): Boolean? {
        if (!isNativeAvailable()) return null
        return try {
            remoteModeRequiresPermission(
                mode = mode.toNative(),
                permission = permission.toNative(),
            )
        } catch (_: Throwable) {
            null
        }
    }

    internal fun lastNativeCallFailureForTesting(): String? = lastNativeCallFailure
}

private fun BurnBarRemoteSessionMode.toNative(): NativeRemoteSessionMode =
    when (this) {
        BurnBarRemoteSessionMode.ViewOnly -> NativeRemoteSessionMode.VIEW_ONLY
        BurnBarRemoteSessionMode.Control -> NativeRemoteSessionMode.CONTROL
        BurnBarRemoteSessionMode.AgentObserve -> NativeRemoteSessionMode.AGENT_OBSERVE
        BurnBarRemoteSessionMode.AgentAssist -> NativeRemoteSessionMode.AGENT_ASSIST
    }

private fun BurnBarRemotePermission.toNative(): NativeRemotePermission =
    when (this) {
        BurnBarRemotePermission.ViewScreen -> NativeRemotePermission.VIEW_SCREEN
        BurnBarRemotePermission.HearAudio -> NativeRemotePermission.HEAR_AUDIO
        BurnBarRemotePermission.InjectInput -> NativeRemotePermission.INJECT_INPUT
        BurnBarRemotePermission.ClipboardRead -> NativeRemotePermission.CLIPBOARD_READ
        BurnBarRemotePermission.ClipboardWrite -> NativeRemotePermission.CLIPBOARD_WRITE
        BurnBarRemotePermission.TransferFiles -> NativeRemotePermission.TRANSFER_FILES
        BurnBarRemotePermission.SystemControl -> NativeRemotePermission.SYSTEM_CONTROL
        BurnBarRemotePermission.ElevateControl -> NativeRemotePermission.ELEVATE_CONTROL
        BurnBarRemotePermission.AuditExport -> NativeRemotePermission.AUDIT_EXPORT
    }

object BurnBarRemoteNativeContext {
    private val loaded = AtomicBoolean(false)

    @Volatile private var lastLoadFailure: String? = null

    fun ensureLoaded(): Boolean {
        if (loaded.get()) return true
        return try {
            loadNativeLibrary()
            loaded.set(true)
            lastLoadFailure = null
            true
        } catch (error: Throwable) {
            lastLoadFailure = "${error::class.java.simpleName}: ${error.message}"
            false
        }
    }

    fun isLoaded(): Boolean = loaded.get()

    internal fun lastLoadFailureForTesting(): String? = lastLoadFailure

    private fun loadNativeLibrary() {
        val libraryDirectory = System.getProperty(NATIVE_LIBRARY_PATH_PROPERTY)?.takeIf { it.isNotBlank() }
        if (libraryDirectory == null) {
            System.loadLibrary("burnbar_remote")
            return
        }

        System.setProperty("jna.library.path", libraryDirectory)
        val library = File(libraryDirectory, System.mapLibraryName("burnbar_remote"))
        System.load(library.absolutePath)
    }
}
