@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import android.content.Context
import android.view.SurfaceHolder
import androidx.compose.material.icons.Icons
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Rect
import androidx.compose.material.icons.filled.AdsClick
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.SwipeVertical
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.openburnbar.data.media.MercuryAutoKeyboardPreference
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayDisplayDescriptor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal const val STALE_STREAM_MILLIS = 12_000L
internal const val HEARTBEAT_FRESH_MILLIS = 7_500L
internal const val AUTO_RECOVERY_RETRY_MILLIS = 15_000L

internal val screenShareControlGradientColors =
    listOf(
        Color(0xFF2BCABF),
        Color(0xFF8E80D8),
    )

internal fun screenShareStatusText(
    phase: VideoReceivePipeline.Phase,
    stats: VideoReceivePipeline.Stats,
    nowMillis: Long,
    lastPeerHeartbeatAtMillis: Long,
): String? = when (phase) {
    VideoReceivePipeline.Phase.Idle -> "Preparing decoder..."
    is VideoReceivePipeline.Phase.Running ->
        when {
            stats.queuedFrameCount == 0L -> "Waiting for Mac video..."
            screenShareNeedsAutomaticRecovery(
                phase = phase,
                stats = stats,
                nowMillis = nowMillis,
                lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
            ) -> "Mac video is recovering automatically..."
            else -> null
        }
    is VideoReceivePipeline.Phase.Failed -> "Decoder unavailable: ${phase.reason}"
    VideoReceivePipeline.Phase.Stopped -> "Screen share stopped"
}

internal fun screenShareNeedsAutomaticRecovery(
    phase: VideoReceivePipeline.Phase,
    stats: VideoReceivePipeline.Stats,
    nowMillis: Long,
    lastPeerHeartbeatAtMillis: Long,
): Boolean {
    if (phase !is VideoReceivePipeline.Phase.Running) return false
    if (stats.lastFrameAtMillis <= 0L) return false

    val lastSignalAtMillis = maxOf(stats.lastFrameAtMillis, lastPeerHeartbeatAtMillis)
    val heartbeatIsFresh =
        lastPeerHeartbeatAtMillis > 0L &&
            nowMillis - lastPeerHeartbeatAtMillis <= HEARTBEAT_FRESH_MILLIS
    return !heartbeatIsFresh && nowMillis - lastSignalAtMillis > STALE_STREAM_MILLIS
}

internal enum class ScreenMirrorFit {
    FIT,
    FILL,
    FLOAT,
    ;

    fun next(): ScreenMirrorFit = when (this) {
        FIT -> FILL
        FILL -> FLOAT
        FLOAT -> FIT
    }

    val label: String
        get() =
            when (this) {
                FIT -> "Fit"
                FILL -> "Fill"
                FLOAT -> "Float"
            }
}

internal enum class ScreenMirrorControlMode {
    VIEW,
    TOUCH,
    TRACKPAD,
    SCROLL,
    COPILOT,
    ;

    fun next(): ScreenMirrorControlMode = when (this) {
        VIEW -> TOUCH
        TOUCH -> TRACKPAD
        TRACKPAD -> SCROLL
        SCROLL -> COPILOT
        COPILOT -> VIEW
    }

    val label: String
        get() =
            when (this) {
                VIEW -> "View"
                TOUCH -> "Click"
                TRACKPAD -> "Trackpad"
                SCROLL -> "Scroll"
                COPILOT -> "Co-Pilot"
            }
}

internal data class ScreenMirrorSurfaceBounds(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
) {
    val right: Float get() = left + width
    val bottom: Float get() = top + height
    val center: Offset get() = Offset(left + width / 2f, top + height / 2f)
}

internal fun Modifier.screenMirrorSurface(fit: ScreenMirrorFit, aspect: Float): Modifier = when (fit) {
    ScreenMirrorFit.FIT ->
        this
            .fillMaxSize()
            .wrapContentSize(Alignment.Center)
            .aspectRatio(aspect)
    ScreenMirrorFit.FILL -> this.fillMaxSize()
    ScreenMirrorFit.FLOAT ->
        this
            .fillMaxSize(0.92f)
            .wrapContentSize(Alignment.Center)
            .aspectRatio(aspect)
            .clip(RoundedCornerShape(18.dp))
            .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(18.dp))
}

internal object ScreenMirrorInputPolicy {
    const val RIGHT_CLICK_HOLD_MILLIS: Long = 550L
    const val TRACKPAD_TAP_TRAVEL_LIMIT_PX: Float = 8f

    fun controlClickMouseButton(heldMillis: Long): Int = if (heldMillis >= RIGHT_CLICK_HOLD_MILLIS) 1 else 0

    fun trackpadClickMouseButton(heldMillis: Long, travelDistancePx: Float): Int? {
        if (heldMillis >= RIGHT_CLICK_HOLD_MILLIS) return 1
        return if (travelDistancePx < TRACKPAD_TAP_TRAVEL_LIMIT_PX) 0 else null
    }

    fun surfaceBounds(rootSize: IntSize, fit: ScreenMirrorFit, aspect: Float): ScreenMirrorSurfaceBounds? {
        if (rootSize.width <= 0 || rootSize.height <= 0 || aspect <= 0f) return null
        val rootWidth = rootSize.width.toFloat()
        val rootHeight = rootSize.height.toFloat()
        val width: Float
        val height: Float
        val left: Float
        val top: Float

        when (fit) {
            ScreenMirrorFit.FILL -> {
                width = rootWidth
                height = rootHeight
                left = 0f
                top = 0f
            }
            ScreenMirrorFit.FIT -> {
                val containerAspect = rootWidth / rootHeight
                if (containerAspect > aspect) {
                    // Height is the bottleneck
                    height = rootHeight
                    width = rootHeight * aspect
                    left = (rootWidth - width) / 2f
                    top = 0f
                } else {
                    // Width is the bottleneck
                    width = rootWidth
                    height = rootWidth / aspect
                    left = 0f
                    top = (rootHeight - height) / 2f
                }
            }
            ScreenMirrorFit.FLOAT -> {
                val maxW = rootWidth * 0.92f
                val maxH = rootHeight * 0.92f
                val containerAspect = maxW / maxH
                if (containerAspect > aspect) {
                    // Height is the bottleneck
                    height = maxH
                    width = maxH * aspect
                    left = (rootWidth - width) / 2f
                    top = (rootHeight - height) / 2f
                } else {
                    // Width is the bottleneck
                    width = maxW
                    height = maxW / aspect
                    left = (rootWidth - width) / 2f
                    top = (rootHeight - height) / 2f
                }
            }
        }

        return ScreenMirrorSurfaceBounds(left = left, top = top, width = width, height = height)
    }

    fun normalizedPoint(
        position: Offset,
        rootSize: IntSize,
        fit: ScreenMirrorFit,
        aspect: Float,
        smartZoomScale: Float = 1f,
        smartZoomTranslation: Offset = Offset.Zero,
    ): Pair<Double, Double>? {
        val bounds = surfaceBounds(rootSize, fit, aspect) ?: return null
        val localX = position.x - bounds.left
        val localY = position.y - bounds.top
        val unzoomed =
            inverseSmartZoom(
                local = Offset(localX, localY),
                bounds = bounds,
                smartZoomScale = smartZoomScale,
                smartZoomTranslation = smartZoomTranslation,
            )
        val isOutsideBounds =
            unzoomed.x < 0f || unzoomed.y < 0f || unzoomed.x > bounds.width || unzoomed.y > bounds.height
        if (isOutsideBounds) {
            return null
        }
        return Pair(
            (unzoomed.x / bounds.width).coerceIn(0f, 1f).toDouble(),
            (unzoomed.y / bounds.height).coerceIn(0f, 1f).toDouble(),
        )
    }

    fun inverseSmartZoom(local: Offset, bounds: ScreenMirrorSurfaceBounds, smartZoomScale: Float, smartZoomTranslation: Offset): Offset {
        if (smartZoomScale <= 0.0001f) return local
        val halfW = bounds.width / 2f
        val halfH = bounds.height / 2f
        val x = (local.x - halfW - smartZoomTranslation.x) / smartZoomScale + halfW
        val y = (local.y - halfH - smartZoomTranslation.y) / smartZoomScale + halfH
        return Offset(x, y)
    }

    fun initialCursorPoint(rootSize: IntSize, fit: ScreenMirrorFit, aspect: Float): Offset? = surfaceBounds(rootSize, fit, aspect)?.center

    fun clampedCursorPoint(position: Offset, rootSize: IntSize, fit: ScreenMirrorFit, aspect: Float): Offset? {
        val bounds = surfaceBounds(rootSize, fit, aspect) ?: return null
        return Offset(
            x = position.x.coerceIn(bounds.left, bounds.right),
            y = position.y.coerceIn(bounds.top, bounds.bottom),
        )
    }

    fun movedCursorPoint(current: Offset?, delta: Offset, rootSize: IntSize, fit: ScreenMirrorFit, aspect: Float): Offset? {
        val bounds = surfaceBounds(rootSize, fit, aspect) ?: return null
        val base = current ?: bounds.center
        return Offset(
            x = (base.x + delta.x).coerceIn(bounds.left, bounds.right),
            y = (base.y + delta.y).coerceIn(bounds.top, bounds.bottom),
        )
    }
}

internal enum class MirrorControlGroup(val title: String, val hint: String) {
    MODE("Mode", "Interaction mode — view, click, trackpad, Co-Pilot"),
    ZOOM("Zoom", "Fit and Smart Zoom"),
    SCROLL("Scroll", "Scroll the Mac up and down"),
    KEYS("Keys", "Keyboard and clipboard"),
    SCREEN("Screen", "Display, stats and window"),
}

internal fun mirrorGroupIcon(group: MirrorControlGroup, controlMode: ScreenMirrorControlMode): ImageVector = when (group) {
    MirrorControlGroup.MODE -> screenMirrorControlIcon(controlMode)
    MirrorControlGroup.ZOOM -> Icons.Filled.ZoomIn
    MirrorControlGroup.SCROLL -> Icons.Filled.SwapVert
    MirrorControlGroup.KEYS -> Icons.Filled.Keyboard
    MirrorControlGroup.SCREEN -> Icons.Filled.DesktopWindows
}

internal data class MirrorDockUiState(
    val collapsed: Boolean,
    val openGroup: MirrorControlGroup?,
    val fit: ScreenMirrorFit,
    val controlMode: ScreenMirrorControlMode,
    val typingOpen: Boolean,
    val statsVisible: Boolean,
    val phaseLabel: String,
    val trayScale: Float,
    val stats: VideoReceivePipeline.Stats,
    val availableDisplays: List<HermesRealtimeRelayDisplayDescriptor>,
    val activeDisplayId: String?,
    val smartZoomMode: SmartZoomMode,
    val smartZoomAutoFollowing: Boolean,
    val autoKeyboardOnTextFocus: Boolean,
    val controlStatus: String?,
    val isZoomed: Boolean = false,
)

internal data class MirrorDockActions(
    val onSelectDisplay: (String) -> Unit,
    val onTrayScaleChange: (Float) -> Unit,
    val onToggleCollapsed: () -> Unit,
    val onSelectGroup: (MirrorControlGroup?) -> Unit,
    val onToggleStats: () -> Unit,
    val onCycleFit: () -> Unit,
    val onCycleControlMode: () -> Unit,
    val onSelectSmartZoomMode: (SmartZoomMode) -> Unit,
    val onSelectControlMode: (ScreenMirrorControlMode) -> Unit,
    val onAutoKeyboardOnTextFocusChange: (Boolean) -> Unit,
    val onToggleTyping: () -> Unit,
    val onScrollUp: () -> Unit,
    val onScrollDown: () -> Unit,
    val onEscape: () -> Unit,
    val onCommandTab: () -> Unit,
    val onPasteClipboardToMac: () -> Unit,
    val onGrabClipboardFromMac: () -> Unit,
    val onPanic: () -> Unit,
    val onTrustControlDevice: () -> Unit,
    val onReconnect: () -> Unit,
    val onEnterPictureInPicture: () -> Unit,
    val onClose: () -> Unit,
    val onZoomIn: () -> Unit = {},
    val onZoomOut: () -> Unit = {},
    val onResetZoom: () -> Unit = {},
)

internal data class MirrorControlShelfParams(
    val group: MirrorControlGroup,
    val controlMode: ScreenMirrorControlMode,
    val typingOpen: Boolean,
    val statsVisible: Boolean,
    val autoKeyboardOnTextFocus: Boolean,
    val smartZoomMode: SmartZoomMode,
    val smartZoomAutoFollowing: Boolean,
    val fit: ScreenMirrorFit,
    val trayScale: Float,
    val availableDisplays: List<HermesRealtimeRelayDisplayDescriptor>,
    val activeDisplayId: String?,
    val isZoomed: Boolean,
    val onSelectControlMode: (ScreenMirrorControlMode) -> Unit,
    val onTrustControlDevice: () -> Unit,
    val onPanic: () -> Unit,
    val onCycleFit: () -> Unit,
    val onSelectSmartZoomMode: (SmartZoomMode) -> Unit,
    val onScrollUp: () -> Unit,
    val onScrollDown: () -> Unit,
    val onToggleTyping: () -> Unit,
    val onAutoKeyboardOnTextFocusChange: (Boolean) -> Unit,
    val onPasteClipboardToMac: () -> Unit,
    val onGrabClipboardFromMac: () -> Unit,
    val onEscape: () -> Unit,
    val onCommandTab: () -> Unit,
    val onSelectDisplay: (String) -> Unit,
    val onToggleStats: () -> Unit,
    val onReconnect: () -> Unit,
    val onEnterPictureInPicture: () -> Unit,
    val onTrayScaleChange: (Float) -> Unit,
    val showTooltip: (String) -> Unit,
    val onZoomIn: () -> Unit,
    val onZoomOut: () -> Unit,
    val onResetZoom: () -> Unit,
)

internal data class RemoteUnlockCallbacks(
    val onReconnect: () -> Unit,
    val onClose: () -> Unit,
    val onSendPassword: (String) -> Unit,
    val onSavePassword: (String) -> Unit,
    val onSendSavedPassword: () -> Unit,
    val onDeleteSavedPassword: () -> Unit,
)

internal data class RemoteKeyboardDiff(
    val insertedText: String,
    val deletedCount: Int,
)

internal fun remoteKeyboardDiff(oldText: String, newText: String): RemoteKeyboardDiff {
    var prefix = 0
    val commonPrefixLimit = minOf(oldText.length, newText.length)
    while (prefix < commonPrefixLimit && oldText[prefix] == newText[prefix]) {
        prefix += 1
    }

    var oldSuffix = oldText.length
    var newSuffix = newText.length
    while (
        oldSuffix > prefix &&
        newSuffix > prefix &&
        oldText[oldSuffix - 1] == newText[newSuffix - 1]
    ) {
        oldSuffix -= 1
        newSuffix -= 1
    }

    return RemoteKeyboardDiff(
        insertedText = newText.substring(prefix, newSuffix),
        deletedCount = oldSuffix - prefix,
    )
}

internal fun dispatchRemoteKeyboardText(text: String, onText: (String) -> Unit, onKey: (String) -> Unit) {
    if (text.isEmpty()) return
    val buffer = StringBuilder()

    fun flushText() {
        if (buffer.isNotEmpty()) {
            onText(buffer.toString())
            buffer.clear()
        }
    }

    text.forEach { char ->
        when (char) {
            '\n', '\r' -> {
                flushText()
                onKey("return")
            }
            '\t' -> {
                flushText()
                onKey("tab")
            }
            else -> buffer.append(char)
        }
    }
    flushText()
}
internal class SurfaceCallback(
    private val pipeline: VideoReceivePipeline,
    private val scope: CoroutineScope,
) : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
        scope.launch { pipeline.start(holder.surface) }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        scope.launch { pipeline.stop() }
    }
}
internal fun screenMirrorControlIcon(mode: ScreenMirrorControlMode): ImageVector = when (mode) {
    ScreenMirrorControlMode.VIEW -> Icons.Filled.Visibility
    ScreenMirrorControlMode.TOUCH -> Icons.Filled.AdsClick
    ScreenMirrorControlMode.TRACKPAD -> Icons.Filled.Mouse
    ScreenMirrorControlMode.SCROLL -> Icons.Filled.SwipeVertical
    ScreenMirrorControlMode.COPILOT -> Icons.Filled.TrackChanges
}

internal fun screenMirrorControlLabel(mode: ScreenMirrorControlMode): String = when (mode) {
    ScreenMirrorControlMode.VIEW -> "View"
    ScreenMirrorControlMode.TOUCH -> "Click"
    ScreenMirrorControlMode.TRACKPAD -> "Trackpad"
    ScreenMirrorControlMode.SCROLL -> "Scroll"
    ScreenMirrorControlMode.COPILOT -> "Co-Pilot"
}

internal fun screenMirrorControlWidth(mode: ScreenMirrorControlMode) = when (mode) {
    ScreenMirrorControlMode.TRACKPAD -> 74.dp
    ScreenMirrorControlMode.COPILOT -> 70.dp
    else -> 58.dp
}

internal fun screenMirrorControlContentDescription(mode: ScreenMirrorControlMode): String = when (mode) {
    ScreenMirrorControlMode.VIEW -> "View mode"
    ScreenMirrorControlMode.TOUCH -> "Click mode"
    ScreenMirrorControlMode.TRACKPAD -> "Glass Trackpad mode"
    ScreenMirrorControlMode.SCROLL -> "Scroll mode"
    ScreenMirrorControlMode.COPILOT -> "Agent Co-Pilot"
}

data class ScreenShareViewerScreenOptions(
    val lastPeerHeartbeatAtMillis: Long = 0L,
    val availableDisplays: List<HermesRealtimeRelayDisplayDescriptor> = emptyList(),
    val selectedDisplayId: String? = null,
    val latestFocusContext: ScreenShareSmartZoomContext? = null,
    val remoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState? = null,
    val savedRemoteUnlockCredentialAvailable: Boolean = false,
    val controlStatus: String? = null,
    val onSelectDisplay: (String) -> Unit = {},
    val onClose: () -> Unit = {},
    val onEnterPictureInPicture: () -> Unit = {},
    val onReconnect: () -> Unit = {},
    val onTapNormalized: (Double, Double, Int, String?) -> Unit = { x, y, button, displayId -> },
    val onScrollDragNormalized: (Double, Double, Double, Double, String?) -> Unit = { startX, startY, endX, endY, displayId -> },
    val onScrollNormalized: (Double, String?) -> Unit = { delta, displayId -> },
    val onPointerMove: (Double, Double) -> Unit = { x, y -> },
    val onPointerClick: (Int) -> Unit = {},
    val onTypeText: (String) -> Unit = {},
    val onShortcut: (String, List<String>) -> Unit = { key, modifiers -> },
    val onPanic: () -> Unit = {},
    val onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit = { x, y, instruction, runtime, displayId -> },
    val onPasteClipboardToMac: () -> Unit = {},
    val onGrabClipboardFromMac: () -> Unit = {},
    val onSendRemoteUnlockPassword: (String) -> Unit = {},
    val onSaveRemoteUnlockPassword: (String) -> Unit = {},
    val onSendSavedRemoteUnlockPassword: () -> Unit = {},
    val onDeleteSavedRemoteUnlockPassword: () -> Unit = {},
    val onTrustControlDevice: () -> Unit = {},
)

internal fun ScreenShareViewerScreenOptions.toScreenParams(
    pipeline: VideoReceivePipeline,
): Pair<ScreenShareViewerScreenInputs, ScreenShareViewerScreenRouteCallbacks> =
    screenShareViewerScreenParams(
        pipeline = pipeline,
        lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
        availableDisplays = availableDisplays,
        selectedDisplayId = selectedDisplayId,
        latestFocusContext = latestFocusContext,
        remoteUnlockState = remoteUnlockState,
        savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable,
        controlStatus = controlStatus,
        onSelectDisplay = onSelectDisplay,
        onClose = onClose,
        onEnterPictureInPicture = onEnterPictureInPicture,
        onReconnect = onReconnect,
        onTapNormalized = onTapNormalized,
        onScrollDragNormalized = onScrollDragNormalized,
        onScrollNormalized = onScrollNormalized,
        onPointerMove = onPointerMove,
        onPointerClick = onPointerClick,
        onTypeText = onTypeText,
        onShortcut = onShortcut,
        onPanic = onPanic,
        onAgentContextTargetNormalized = onAgentContextTargetNormalized,
        onPasteClipboardToMac = onPasteClipboardToMac,
        onGrabClipboardFromMac = onGrabClipboardFromMac,
        onSendRemoteUnlockPassword = onSendRemoteUnlockPassword,
        onSaveRemoteUnlockPassword = onSaveRemoteUnlockPassword,
        onSendSavedRemoteUnlockPassword = onSendSavedRemoteUnlockPassword,
        onDeleteSavedRemoteUnlockPassword = onDeleteSavedRemoteUnlockPassword,
        onTrustControlDevice = onTrustControlDevice,
    )

internal data class ScreenShareViewerScreenInputs(
    val pipeline: VideoReceivePipeline,
    val lastPeerHeartbeatAtMillis: Long = 0L,
    val availableDisplays: List<HermesRealtimeRelayDisplayDescriptor> = emptyList(),
    val selectedDisplayId: String? = null,
    val latestFocusContext: ScreenShareSmartZoomContext? = null,
    val remoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState? = null,
    val savedRemoteUnlockCredentialAvailable: Boolean = false,
    val controlStatus: String? = null,
)

@Suppress("LongParameterList")
internal fun screenShareViewerScreenParams(
    pipeline: VideoReceivePipeline,
    lastPeerHeartbeatAtMillis: Long,
    availableDisplays: List<HermesRealtimeRelayDisplayDescriptor>,
    selectedDisplayId: String?,
    latestFocusContext: ScreenShareSmartZoomContext?,
    remoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState?,
    savedRemoteUnlockCredentialAvailable: Boolean,
    controlStatus: String?,
    onSelectDisplay: (String) -> Unit,
    onClose: () -> Unit,
    onEnterPictureInPicture: () -> Unit,
    onReconnect: () -> Unit,
    onTapNormalized: (Double, Double, Int, String?) -> Unit,
    onScrollDragNormalized: (Double, Double, Double, Double, String?) -> Unit,
    onScrollNormalized: (Double, String?) -> Unit,
    onPointerMove: (Double, Double) -> Unit,
    onPointerClick: (Int) -> Unit,
    onTypeText: (String) -> Unit,
    onShortcut: (String, List<String>) -> Unit,
    onPanic: () -> Unit,
    onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit,
    onPasteClipboardToMac: () -> Unit,
    onGrabClipboardFromMac: () -> Unit,
    onSendRemoteUnlockPassword: (String) -> Unit,
    onSaveRemoteUnlockPassword: (String) -> Unit,
    onSendSavedRemoteUnlockPassword: () -> Unit,
    onDeleteSavedRemoteUnlockPassword: () -> Unit,
    onTrustControlDevice: () -> Unit,
): Pair<ScreenShareViewerScreenInputs, ScreenShareViewerScreenRouteCallbacks> =
    ScreenShareViewerScreenInputs(
        pipeline = pipeline,
        lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
        availableDisplays = availableDisplays,
        selectedDisplayId = selectedDisplayId,
        latestFocusContext = latestFocusContext,
        remoteUnlockState = remoteUnlockState,
        savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable,
        controlStatus = controlStatus,
    ) to
        ScreenShareViewerScreenRouteCallbacks(
            onSelectDisplay = onSelectDisplay,
            onClose = onClose,
            onEnterPictureInPicture = onEnterPictureInPicture,
            onReconnect = onReconnect,
            onTapNormalized = onTapNormalized,
            onScrollDragNormalized = onScrollDragNormalized,
            onScrollNormalized = onScrollNormalized,
            onPointerMove = onPointerMove,
            onPointerClick = onPointerClick,
            onTypeText = onTypeText,
            onShortcut = onShortcut,
            onPanic = onPanic,
            onAgentContextTargetNormalized = onAgentContextTargetNormalized,
            onPasteClipboardToMac = onPasteClipboardToMac,
            onGrabClipboardFromMac = onGrabClipboardFromMac,
            onSendRemoteUnlockPassword = onSendRemoteUnlockPassword,
            onSaveRemoteUnlockPassword = onSaveRemoteUnlockPassword,
            onSendSavedRemoteUnlockPassword = onSendSavedRemoteUnlockPassword,
            onDeleteSavedRemoteUnlockPassword = onDeleteSavedRemoteUnlockPassword,
            onTrustControlDevice = onTrustControlDevice,
        )

internal data class ScreenShareViewerScreenRouteCallbacks(
    val onSelectDisplay: (String) -> Unit = {},
    val onClose: () -> Unit = {},
    val onEnterPictureInPicture: () -> Unit = {},
    val onReconnect: () -> Unit = {},
    val onTapNormalized: (Double, Double, Int, String?) -> Unit = { x, y, button, displayId -> },
    val onScrollDragNormalized: (Double, Double, Double, Double, String?) -> Unit = { startX, startY, endX, endY, displayId -> },
    val onScrollNormalized: (Double, String?) -> Unit = { delta, displayId -> },
    val onPointerMove: (Double, Double) -> Unit = { x, y -> },
    val onPointerClick: (Int) -> Unit = {},
    val onTypeText: (String) -> Unit = {},
    val onShortcut: (String, List<String>) -> Unit = { key, modifiers -> },
    val onPanic: () -> Unit = {},
    val onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit = { x, y, instruction, runtime, displayId -> },
    val onPasteClipboardToMac: () -> Unit = {},
    val onGrabClipboardFromMac: () -> Unit = {},
    val onSendRemoteUnlockPassword: (String) -> Unit = {},
    val onSaveRemoteUnlockPassword: (String) -> Unit = {},
    val onSendSavedRemoteUnlockPassword: () -> Unit = {},
    val onDeleteSavedRemoteUnlockPassword: () -> Unit = {},
    val onTrustControlDevice: () -> Unit = {},
)

internal data class ScreenShareViewerDerivedUi(
    val fit: ScreenMirrorFit,
    val controlMode: ScreenMirrorControlMode,
    val smartZoomMode: SmartZoomMode,
    val activeRemoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState?,
    val standardControlEnabled: Boolean,
    val aspect: Float,
    val statusText: String?,
    val streamNeedsRecovery: Boolean,
)

internal class ScreenShareViewerLocals(
    context: Context,
    val toolsCollapsed: androidx.compose.runtime.MutableState<Boolean>,
    val fitName: androidx.compose.runtime.MutableState<String>,
    val controlModeName: androidx.compose.runtime.MutableState<String>,
    val smartZoomModeName: androidx.compose.runtime.MutableState<String>,
    val typingOpen: androidx.compose.runtime.MutableState<Boolean>,
    val trayScale: androidx.compose.runtime.MutableState<Float>,
) {
    var statsVisible by mutableStateOf(false)
    var openGroup by mutableStateOf<MirrorControlGroup?>(null)
    var smartZoomManualOverrideUntilMillis by mutableStateOf<Long?>(null)
    var smartZoomDecision by mutableStateOf(ScreenShareSmartZoomDecision.identity)
    var surfaceLayoutSize by mutableStateOf(IntSize.Zero)
    var autoKeyboardOnTextFocus by mutableStateOf(MercuryAutoKeyboardPreference.isEnabled(context))
    var autoTypeManualDismissUntilMillis by mutableStateOf<Long?>(null)
    var coPilotTarget by mutableStateOf<Pair<Double, Double>?>(null)
    var coPilotViewPoint by mutableStateOf<Offset?>(null)
    var coPilotRuntime by mutableStateOf("hermes")
    var activeDisplayId by mutableStateOf<String?>(null)
    var tapCount by mutableStateOf(0)
    var lastTapAt by mutableStateOf(0L)
    var dragActive by mutableStateOf(false)
    var dragStartNormalized by mutableStateOf<Pair<Double, Double>?>(null)
    var pressStartedAt by mutableStateOf(0L)
    var nowMillis by mutableStateOf(System.currentTimeMillis())
    var lastInteractionTime by mutableStateOf(System.currentTimeMillis())
    var lastAutomaticReconnectAtMillis by mutableStateOf(0L)

    fun syncActiveDisplayId(selectedDisplayId: String?) {
        activeDisplayId = selectedDisplayId
    }

    fun markInteraction() {
        lastInteractionTime = System.currentTimeMillis()
    }

    fun triggerSmartZoomManualOverride() {
        smartZoomManualOverrideUntilMillis =
            System.currentTimeMillis() + ScreenShareSmartZoomReducer.MANUAL_OVERRIDE_HOLD_MILLIS
    }

    fun recomputeSmartZoom(
        latestFocusContext: ScreenShareSmartZoomContext?,
        smartZoomMode: SmartZoomMode,
        fit: ScreenMirrorFit,
        aspect: Float,
    ) {
        val bounds = ScreenMirrorInputPolicy.surfaceBounds(surfaceLayoutSize, fit, aspect) ?: return
        val viewportSize = IntSize(bounds.width.toInt(), bounds.height.toInt())
        val contentRect = Rect(0f, 0f, bounds.width, bounds.height)
        smartZoomDecision =
            ScreenShareSmartZoomReducer.reduce(
                viewport =
                ScreenShareSmartZoomReducer.SmartZoomViewport(
                    viewportSize = viewportSize,
                    contentRect = contentRect,
                    currentScale = smartZoomDecision.scale,
                    currentTranslation = smartZoomDecision.translation,
                ),
                inputs =
                ScreenShareSmartZoomReducer.SmartZoomReduceInputs(
                    context = latestFocusContext,
                    mode = smartZoomMode,
                    selectedDisplayId = activeDisplayId,
                    manualOverrideUntilMillis = smartZoomManualOverrideUntilMillis,
                    nowMillis = System.currentTimeMillis(),
                ),
            )
    }

    fun lifecycleParams(
        pipeline: VideoReceivePipeline,
        inputs: ScreenShareViewerScreenInputs,
        route: ScreenShareViewerScreenRouteCallbacks,
        derived: ScreenShareViewerDerivedUi,
    ): ScreenShareViewerLifecycleParams =
        ScreenShareViewerLifecycleParams(
            pipeline = pipeline,
            lastInteractionTime = lastInteractionTime,
            toolsCollapsed = toolsCollapsed.value,
            openGroup = openGroup,
            typingOpen = typingOpen.value,
            onAutoCollapseTools = { toolsCollapsed.value = true },
            latestFocusContext = inputs.latestFocusContext,
            smartZoomMode = derived.smartZoomMode,
            activeDisplayId = activeDisplayId,
            aspect = derived.aspect,
            fit = derived.fit,
            surfaceLayoutSize = surfaceLayoutSize,
            smartZoomManualOverrideUntilMillis = smartZoomManualOverrideUntilMillis,
            smartZoomDecision = smartZoomDecision,
            onSmartZoomDecision = { smartZoomDecision = it },
            autoKeyboardOnTextFocus = autoKeyboardOnTextFocus,
            controlMode = derived.controlMode,
            standardControlEnabled = derived.standardControlEnabled,
            autoTypeManualDismissUntilMillis = autoTypeManualDismissUntilMillis,
            onTypingOpenChange = { typingOpen.value = it },
            onControlModeNameChange = { controlModeName.value = it },
            nowMillis = nowMillis,
            onNowMillis = { nowMillis = it },
            streamNeedsRecovery = derived.streamNeedsRecovery,
            lastAutomaticReconnectAtMillis = lastAutomaticReconnectAtMillis,
            onLastAutomaticReconnectAtMillis = { lastAutomaticReconnectAtMillis = it },
            onReconnect = route.onReconnect,
        )

    fun mainUiState(input: ScreenShareViewerMainUiStateBuildInput): ScreenShareViewerMainUiState {
        val derived = input.derived
        val inputs = input.inputs
        val stats = input.stats
        val phase = input.phase
        return ScreenShareViewerMainUiState(
            fit = derived.fit,
            aspect = derived.aspect,
            controlMode = derived.controlMode,
            standardControlEnabled = derived.standardControlEnabled,
            smartZoomDecision = smartZoomDecision,
            surfaceLayoutSize = surfaceLayoutSize,
            animatedScale = input.animatedScale,
            animatedTranslationX = input.animatedTranslationX,
            animatedTranslationY = input.animatedTranslationY,
            statsVisible = statsVisible,
            statusText = derived.statusText,
            stats = stats,
            activeRemoteUnlockState = derived.activeRemoteUnlockState,
            savedRemoteUnlockCredentialAvailable = inputs.savedRemoteUnlockCredentialAvailable,
            coPilotTarget = coPilotTarget,
            coPilotViewPoint = coPilotViewPoint,
            coPilotRuntime = coPilotRuntime,
            typingOpen = typingOpen.value,
            autoKeyboardOnTextFocus = autoKeyboardOnTextFocus,
            autoTypeManualDismissUntilMillis = autoTypeManualDismissUntilMillis,
            latestFocusContext = inputs.latestFocusContext,
            activeDisplayId = activeDisplayId,
            tapCount = tapCount,
            lastTapAt = lastTapAt,
            dragActive = dragActive,
            dragStartNormalized = dragStartNormalized,
            pressStartedAt = pressStartedAt,
            toolsCollapsed = toolsCollapsed.value,
            openGroup = openGroup,
            fitName = fitName.value,
            controlModeName = controlModeName.value,
            smartZoomModeName = smartZoomModeName.value,
            smartZoomMode = derived.smartZoomMode,
            trayScale = trayScale.value,
            phase = phase,
            streamNeedsRecovery = derived.streamNeedsRecovery,
            availableDisplays = inputs.availableDisplays,
            controlStatus = inputs.controlStatus,
        )
    }
}

internal fun screenShareViewerMainUiCallbacks(
    source: ScreenShareViewerMainUiCallbacksSource,
): ScreenShareViewerMainUiCallbacks {
    val route = source.route
    val context = source.context
    val latestFocusContext = source.latestFocusContext
    val smartZoomMode = source.smartZoomMode
    val fit = source.fit
    val aspect = source.aspect
    val locals = source.locals
    return ScreenShareViewerMainUiCallbacks(
        onSmartZoomDecision = { locals.smartZoomDecision = it },
        onSmartZoomManualOverride = { locals.triggerSmartZoomManualOverride() },
        onSurfaceLayoutSize = { locals.surfaceLayoutSize = it },
        onLastInteraction = { locals.markInteraction() },
        onCoPilotRuntimeChange = { locals.coPilotRuntime = it },
        onCoPilotTargetChange = { locals.coPilotTarget = it },
        onCoPilotViewPointChange = { locals.coPilotViewPoint = it },
        onTypingOpenChange = { locals.typingOpen.value = it },
        onAutoTypeManualDismissUntilMillis = { locals.autoTypeManualDismissUntilMillis = it },
        onActiveDisplayId = { locals.activeDisplayId = it },
        onTapCount = { locals.tapCount = it },
        onLastTapAt = { locals.lastTapAt = it },
        onDragActive = { locals.dragActive = it },
        onDragStartNormalized = { locals.dragStartNormalized = it },
        onPressStartedAt = { locals.pressStartedAt = it },
        onStatsVisible = { locals.statsVisible = it },
        onFitName = { locals.fitName.value = it },
        onControlModeName = { locals.controlModeName.value = it },
        onSmartZoomModeName = { locals.smartZoomModeName.value = it },
        onSmartZoomManualOverrideUntilMillis = { locals.smartZoomManualOverrideUntilMillis = it },
        onRecomputeSmartZoom = { locals.recomputeSmartZoom(latestFocusContext, smartZoomMode, fit, aspect) },
        onTrayScale = { locals.trayScale.value = it },
        onToolsCollapsed = { locals.toolsCollapsed.value = it },
        onOpenGroup = { locals.openGroup = it },
        onAutoKeyboardOnTextFocus = { enabled ->
            locals.autoKeyboardOnTextFocus = enabled
            MercuryAutoKeyboardPreference.setEnabled(context, enabled)
        },
        onSelectDisplay = route.onSelectDisplay,
        onClose = route.onClose,
        onEnterPictureInPicture = route.onEnterPictureInPicture,
        onReconnect = route.onReconnect,
        onTapNormalized = route.onTapNormalized,
        onScrollDragNormalized = route.onScrollDragNormalized,
        onScrollNormalized = route.onScrollNormalized,
        onPointerMove = route.onPointerMove,
        onPointerClick = route.onPointerClick,
        onTypeText = route.onTypeText,
        onShortcut = route.onShortcut,
        onPanic = route.onPanic,
        onAgentContextTargetNormalized = route.onAgentContextTargetNormalized,
        onPasteClipboardToMac = route.onPasteClipboardToMac,
        onGrabClipboardFromMac = route.onGrabClipboardFromMac,
        onSendRemoteUnlockPassword = route.onSendRemoteUnlockPassword,
        onSaveRemoteUnlockPassword = route.onSaveRemoteUnlockPassword,
        onSendSavedRemoteUnlockPassword = route.onSendSavedRemoteUnlockPassword,
        onDeleteSavedRemoteUnlockPassword = route.onDeleteSavedRemoteUnlockPassword,
        onTrustControlDevice = route.onTrustControlDevice,
    )
}

internal fun screenShareViewerDerivedUi(
    fitName: String = ScreenMirrorFit.FIT.name,
    controlModeName: String = ScreenMirrorControlMode.VIEW.name,
    smartZoomModeName: String = SmartZoomMode.SMART.name,
    remoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState?,
    phase: VideoReceivePipeline.Phase,
    stats: VideoReceivePipeline.Stats,
    nowMillis: Long,
    lastPeerHeartbeatAtMillis: Long,
): ScreenShareViewerDerivedUi {
    val fit = ScreenMirrorFit.entries.firstOrNull { it.name == fitName } ?: ScreenMirrorFit.FIT
    val controlMode =
        ScreenMirrorControlMode.entries.firstOrNull { it.name == controlModeName }
            ?: ScreenMirrorControlMode.VIEW
    val smartZoomMode = SmartZoomMode.entries.firstOrNull { it.name == smartZoomModeName } ?: SmartZoomMode.SMART
    val activeRemoteUnlockState =
        remoteUnlockState?.takeIf { it.lockState != com.openburnbar.irohrelay.HermesRealtimeRelayMacLockState.UNLOCKED }
    val aspect =
        (stats.widthPx.toFloat() / stats.heightPx.toFloat())
            .takeIf { it.isFinite() && it > 0.1f }
            ?: 16f / 9f
    return ScreenShareViewerDerivedUi(
        fit = fit,
        controlMode = controlMode,
        smartZoomMode = smartZoomMode,
        activeRemoteUnlockState = activeRemoteUnlockState,
        standardControlEnabled = activeRemoteUnlockState == null,
        aspect = aspect,
        statusText =
        screenShareStatusText(
            phase = phase,
            stats = stats,
            nowMillis = nowMillis,
            lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
        ),
        streamNeedsRecovery =
        screenShareNeedsAutomaticRecovery(
            phase = phase,
            stats = stats,
            nowMillis = nowMillis,
            lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
        ),
    )
}

internal data class ScreenShareViewerAnimatedMainParams(
    val modifier: Modifier,
    val inputs: ScreenShareViewerScreenInputs,
    val route: ScreenShareViewerScreenRouteCallbacks,
    val locals: ScreenShareViewerLocals,
    val derived: ScreenShareViewerDerivedUi,
    val stats: VideoReceivePipeline.Stats,
    val phase: VideoReceivePipeline.Phase,
    val coroutineScope: CoroutineScope,
)

internal data class ScreenShareViewerSmartZoomFollowParams(
    val latestFocusContext: ScreenShareSmartZoomContext?,
    val smartZoomMode: SmartZoomMode,
    val activeDisplayId: String?,
    val aspect: Float,
    val fit: ScreenMirrorFit,
    val surfaceLayoutSize: IntSize,
    val smartZoomManualOverrideUntilMillis: Long?,
    val smartZoomDecision: ScreenShareSmartZoomDecision,
    val onSmartZoomDecision: (ScreenShareSmartZoomDecision) -> Unit,
)

internal data class ScreenShareViewerAutoTypeParams(
    val latestFocusContext: ScreenShareSmartZoomContext?,
    val autoKeyboardOnTextFocus: Boolean,
    val controlMode: ScreenMirrorControlMode,
    val standardControlEnabled: Boolean,
    val typingOpen: Boolean,
    val activeDisplayId: String?,
    val autoTypeManualDismissUntilMillis: Long?,
    val onTypingOpenChange: (Boolean) -> Unit,
    val onControlModeNameChange: (String) -> Unit,
)

internal data class ScreenShareViewerPipelineClockParams(
    val pipeline: VideoReceivePipeline,
    val onNowMillis: (Long) -> Unit,
    val streamNeedsRecovery: Boolean,
    val nowMillis: Long,
    val lastAutomaticReconnectAtMillis: Long,
    val onLastAutomaticReconnectAtMillis: (Long) -> Unit,
    val onReconnect: () -> Unit,
)

internal data class ScreenShareViewerStatusOverlayCallbacks(
    val onReconnect: () -> Unit,
    val onClose: () -> Unit,
    val onSendRemoteUnlockPassword: (String) -> Unit,
    val onSaveRemoteUnlockPassword: (String) -> Unit,
    val onSendSavedRemoteUnlockPassword: () -> Unit,
    val onDeleteSavedRemoteUnlockPassword: () -> Unit,
)

internal data class ScreenShareViewerStatusOverlayParams(
    val statusText: String?,
    val statsVisible: Boolean,
    val stats: VideoReceivePipeline.Stats,
    val activeRemoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState?,
    val savedRemoteUnlockCredentialAvailable: Boolean,
    val callbacks: ScreenShareViewerStatusOverlayCallbacks,
)

internal data class ScreenShareViewerMainUiStateBuildInput(
    val derived: ScreenShareViewerDerivedUi,
    val inputs: ScreenShareViewerScreenInputs,
    val stats: VideoReceivePipeline.Stats,
    val phase: VideoReceivePipeline.Phase,
    val animatedScale: Float,
    val animatedTranslationX: Float,
    val animatedTranslationY: Float,
)

internal data class ScreenShareViewerMainUiCallbacksSource(
    val route: ScreenShareViewerScreenRouteCallbacks,
    val context: Context,
    val locals: ScreenShareViewerLocals,
    val latestFocusContext: ScreenShareSmartZoomContext?,
    val smartZoomMode: SmartZoomMode,
    val fit: ScreenMirrorFit,
    val aspect: Float,
)

internal data class MirrorDockActionsBuildInput(
    val uiState: ScreenShareViewerMainUiState,
    val uiCallbacks: ScreenShareViewerMainUiCallbacks,
    val zoomHandlers: ScreenShareZoomHandlers,
)

internal fun ScreenShareViewerLifecycleParams.smartZoomFollowParams(): ScreenShareViewerSmartZoomFollowParams =
    ScreenShareViewerSmartZoomFollowParams(
        latestFocusContext = latestFocusContext,
        smartZoomMode = smartZoomMode,
        activeDisplayId = activeDisplayId,
        aspect = aspect,
        fit = fit,
        surfaceLayoutSize = surfaceLayoutSize,
        smartZoomManualOverrideUntilMillis = smartZoomManualOverrideUntilMillis,
        smartZoomDecision = smartZoomDecision,
        onSmartZoomDecision = onSmartZoomDecision,
    )

internal fun ScreenShareViewerLifecycleParams.autoTypeParams(): ScreenShareViewerAutoTypeParams =
    ScreenShareViewerAutoTypeParams(
        latestFocusContext = latestFocusContext,
        autoKeyboardOnTextFocus = autoKeyboardOnTextFocus,
        controlMode = controlMode,
        standardControlEnabled = standardControlEnabled,
        typingOpen = typingOpen,
        activeDisplayId = activeDisplayId,
        autoTypeManualDismissUntilMillis = autoTypeManualDismissUntilMillis,
        onTypingOpenChange = onTypingOpenChange,
        onControlModeNameChange = onControlModeNameChange,
    )

internal fun ScreenShareViewerLifecycleParams.pipelineClockParams(): ScreenShareViewerPipelineClockParams =
    ScreenShareViewerPipelineClockParams(
        pipeline = pipeline,
        onNowMillis = onNowMillis,
        streamNeedsRecovery = streamNeedsRecovery,
        nowMillis = nowMillis,
        lastAutomaticReconnectAtMillis = lastAutomaticReconnectAtMillis,
        onLastAutomaticReconnectAtMillis = onLastAutomaticReconnectAtMillis,
        onReconnect = onReconnect,
    )

internal data class ScreenShareViewerLifecycleParams(
    val pipeline: VideoReceivePipeline,
    val lastInteractionTime: Long,
    val toolsCollapsed: Boolean,
    val openGroup: MirrorControlGroup?,
    val typingOpen: Boolean,
    val onAutoCollapseTools: () -> Unit,
    val latestFocusContext: ScreenShareSmartZoomContext?,
    val smartZoomMode: SmartZoomMode,
    val activeDisplayId: String?,
    val aspect: Float,
    val fit: ScreenMirrorFit,
    val surfaceLayoutSize: IntSize,
    val smartZoomManualOverrideUntilMillis: Long?,
    val smartZoomDecision: ScreenShareSmartZoomDecision,
    val onSmartZoomDecision: (ScreenShareSmartZoomDecision) -> Unit,
    val autoKeyboardOnTextFocus: Boolean,
    val controlMode: ScreenMirrorControlMode,
    val standardControlEnabled: Boolean,
    val autoTypeManualDismissUntilMillis: Long?,
    val onTypingOpenChange: (Boolean) -> Unit,
    val onControlModeNameChange: (String) -> Unit,
    val nowMillis: Long,
    val onNowMillis: (Long) -> Unit,
    val streamNeedsRecovery: Boolean,
    val lastAutomaticReconnectAtMillis: Long,
    val onLastAutomaticReconnectAtMillis: (Long) -> Unit,
    val onReconnect: () -> Unit,
)

internal data class ScreenShareViewerMainUiState(
    val fit: ScreenMirrorFit,
    val aspect: Float,
    val controlMode: ScreenMirrorControlMode,
    val standardControlEnabled: Boolean,
    val smartZoomDecision: ScreenShareSmartZoomDecision,
    val surfaceLayoutSize: IntSize,
    val animatedScale: Float,
    val animatedTranslationX: Float,
    val animatedTranslationY: Float,
    val statsVisible: Boolean,
    val statusText: String?,
    val stats: VideoReceivePipeline.Stats,
    val activeRemoteUnlockState: com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState?,
    val savedRemoteUnlockCredentialAvailable: Boolean,
    val coPilotTarget: Pair<Double, Double>?,
    val coPilotViewPoint: Offset?,
    val coPilotRuntime: String,
    val typingOpen: Boolean,
    val autoKeyboardOnTextFocus: Boolean,
    val autoTypeManualDismissUntilMillis: Long?,
    val latestFocusContext: ScreenShareSmartZoomContext?,
    val activeDisplayId: String?,
    val tapCount: Int,
    val lastTapAt: Long,
    val dragActive: Boolean,
    val dragStartNormalized: Pair<Double, Double>?,
    val pressStartedAt: Long,
    val toolsCollapsed: Boolean,
    val openGroup: MirrorControlGroup?,
    val fitName: String,
    val controlModeName: String,
    val smartZoomModeName: String,
    val smartZoomMode: SmartZoomMode,
    val trayScale: Float,
    val phase: VideoReceivePipeline.Phase,
    val streamNeedsRecovery: Boolean,
    val availableDisplays: List<HermesRealtimeRelayDisplayDescriptor>,
    val controlStatus: String?,
)

internal data class ScreenShareViewerMainUiCallbacks(
    val onSmartZoomDecision: (ScreenShareSmartZoomDecision) -> Unit,
    val onSmartZoomManualOverride: () -> Unit,
    val onSurfaceLayoutSize: (IntSize) -> Unit,
    val onLastInteraction: () -> Unit,
    val onCoPilotRuntimeChange: (String) -> Unit,
    val onCoPilotTargetChange: (Pair<Double, Double>?) -> Unit,
    val onCoPilotViewPointChange: (Offset?) -> Unit,
    val onTypingOpenChange: (Boolean) -> Unit,
    val onAutoTypeManualDismissUntilMillis: (Long) -> Unit,
    val onActiveDisplayId: (String?) -> Unit,
    val onTapCount: (Int) -> Unit,
    val onLastTapAt: (Long) -> Unit,
    val onDragActive: (Boolean) -> Unit,
    val onDragStartNormalized: (Pair<Double, Double>?) -> Unit,
    val onPressStartedAt: (Long) -> Unit,
    val onStatsVisible: (Boolean) -> Unit,
    val onFitName: (String) -> Unit,
    val onControlModeName: (String) -> Unit,
    val onSmartZoomModeName: (String) -> Unit,
    val onSmartZoomManualOverrideUntilMillis: (Long?) -> Unit,
    val onRecomputeSmartZoom: () -> Unit,
    val onTrayScale: (Float) -> Unit,
    val onToolsCollapsed: (Boolean) -> Unit,
    val onOpenGroup: (MirrorControlGroup?) -> Unit,
    val onAutoKeyboardOnTextFocus: (Boolean) -> Unit,
    val onSelectDisplay: (String) -> Unit,
    val onClose: () -> Unit,
    val onEnterPictureInPicture: () -> Unit,
    val onReconnect: () -> Unit,
    val onTapNormalized: (Double, Double, Int, String?) -> Unit,
    val onScrollDragNormalized: (Double, Double, Double, Double, String?) -> Unit,
    val onScrollNormalized: (Double, String?) -> Unit,
    val onPointerMove: (Double, Double) -> Unit,
    val onPointerClick: (Int) -> Unit,
    val onTypeText: (String) -> Unit,
    val onShortcut: (String, List<String>) -> Unit,
    val onPanic: () -> Unit,
    val onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit,
    val onPasteClipboardToMac: () -> Unit,
    val onGrabClipboardFromMac: () -> Unit,
    val onSendRemoteUnlockPassword: (String) -> Unit,
    val onSaveRemoteUnlockPassword: (String) -> Unit,
    val onSendSavedRemoteUnlockPassword: () -> Unit,
    val onDeleteSavedRemoteUnlockPassword: () -> Unit,
    val onTrustControlDevice: () -> Unit,
)

internal data class ScreenShareViewerGestureUiState(
    val controlMode: ScreenMirrorControlMode,
    val fit: ScreenMirrorFit,
    val aspect: Float,
    val standardControlEnabled: Boolean,
    val smartZoomDecision: ScreenShareSmartZoomDecision,
    val activeDisplayId: String?,
    val tapCount: Int,
    val lastTapAt: Long,
    val dragActive: Boolean,
    val dragStartNormalized: Pair<Double, Double>?,
    val pressStartedAt: Long,
    val statsVisible: Boolean,
)

internal data class ScreenShareViewerGestureUiCallbacks(
    val onTapCount: (Int) -> Unit,
    val onLastTapAt: (Long) -> Unit,
    val onDragActive: (Boolean) -> Unit,
    val onDragStartNormalized: (Pair<Double, Double>?) -> Unit,
    val onPressStartedAt: (Long) -> Unit,
    val onStatsVisible: (Boolean) -> Unit,
    val onCoPilotTargetChange: (Pair<Double, Double>?) -> Unit,
    val onCoPilotViewPointChange: (Offset?) -> Unit,
    val onTapNormalized: (Double, Double, Int, String?) -> Unit,
    val onScrollDragNormalized: (Double, Double, Double, Double, String?) -> Unit,
)

internal data class ScreenShareViewerModeOverlayParams(
    val controlMode: ScreenMirrorControlMode,
    val standardControlEnabled: Boolean,
    val coPilotViewPoint: Offset?,
    val coPilotTarget: Pair<Double, Double>?,
    val coPilotRuntime: String,
    val activeDisplayId: String?,
    val onCoPilotRuntimeChange: (String) -> Unit,
    val onCoPilotTargetChange: (Pair<Double, Double>?) -> Unit,
    val onCoPilotViewPointChange: (Offset?) -> Unit,
    val onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit,
    val typingOpen: Boolean,
    val onTypingOpenChange: (Boolean) -> Unit,
    val autoKeyboardOnTextFocus: Boolean,
    val autoTypeManualDismissUntilMillis: Long?,
    val onAutoTypeManualDismissUntilMillis: (Long) -> Unit,
    val latestFocusContext: ScreenShareSmartZoomContext?,
    val onTypeText: (String) -> Unit,
    val onShortcut: (String, List<String>) -> Unit,
    val onPointerMove: (Double, Double) -> Unit,
    val onPointerClick: (Int) -> Unit,
)
