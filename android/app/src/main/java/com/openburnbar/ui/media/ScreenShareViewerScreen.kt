package com.openburnbar.ui.media

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardTab
import androidx.compose.material.icons.filled.AdsClick
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardDoubleArrowDown
import androidx.compose.material.icons.filled.KeyboardDoubleArrowUp
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CropFree
import androidx.compose.material.icons.filled.HighlightAlt
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.NorthWest
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.SwipeVertical
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import com.openburnbar.irohrelay.HermesRealtimeRelayDisplayDescriptor
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraShadows
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Android Mercury screen-share viewer. 1:1 port of
 * `ScreenShareViewerView.swift` (iOS).
 *
 * Full-bleed `SurfaceView` with a triple-tap toggle for the stats
 * overlay. The viewer hosts a `VideoReceivePipeline` and binds its
 * output surface to the surface view's holder. Picture-in-Picture is
 * handled by the host `ScreenShareViewerActivity` (manifest entry).
 */
@Composable
fun ScreenShareViewerScreen(
    pipeline: VideoReceivePipeline,
    modifier: Modifier = Modifier,
    lastPeerHeartbeatAtMillis: Long = 0L,
    availableDisplays: List<HermesRealtimeRelayDisplayDescriptor> = emptyList(),
    selectedDisplayId: String? = null,
    latestFocusContext: ScreenShareSmartZoomContext? = null,
    onSelectDisplay: (String) -> Unit = {},
    onClose: () -> Unit = {},
    onEnterPictureInPicture: () -> Unit = {},
    onReconnect: () -> Unit = {},
    onTapNormalized: (Double, Double, Int, String?) -> Unit = { _, _, _, _ -> },
    onScrollDragNormalized: (Double, Double, Double, Double, String?) -> Unit = { _, _, _, _, _ -> },
    onScrollNormalized: (Double, String?) -> Unit = { _, _ -> },
    onPointerMove: (Double, Double) -> Unit = { _, _ -> },
    onPointerClick: (Int) -> Unit = {},
    onTypeText: (String) -> Unit = {},
    onShortcut: (String, List<String>) -> Unit = { _, _ -> },
    onPanic: () -> Unit = {},
    onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit = { _, _, _, _, _ -> },
    onPasteClipboardToMac: () -> Unit = {},
    onGrabClipboardFromMac: () -> Unit = {},
    controlStatus: String? = null,
    onTrustControlDevice: () -> Unit = {},
) {
    var statsVisible by remember { mutableStateOf(false) }
    var toolsCollapsed by rememberSaveable { mutableStateOf(false) }
    var customizeOpen by rememberSaveable { mutableStateOf(false) }
    var fitName by rememberSaveable { mutableStateOf(ScreenMirrorFit.FIT.name) }
    var controlModeName by rememberSaveable { mutableStateOf(ScreenMirrorControlMode.VIEW.name) }
    var smartZoomModeName by rememberSaveable { mutableStateOf(SmartZoomMode.SMART.name) }
    var smartZoomManualOverrideUntilMillis by remember { mutableStateOf<Long?>(null) }
    var smartZoomDecision by remember { mutableStateOf(ScreenShareSmartZoomDecision.identity) }
    var surfaceLayoutSize by remember { mutableStateOf(IntSize.Zero) }
    var typingOpen by rememberSaveable { mutableStateOf(false) }
    var trayScale by rememberSaveable { mutableStateOf(1.0f) }
    var coPilotTarget by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var coPilotViewPoint by remember { mutableStateOf<Offset?>(null) }
    var coPilotRuntime by remember { mutableStateOf("hermes") }
    var activeDisplayId by remember(selectedDisplayId) { mutableStateOf(selectedDisplayId) }
    var tapCount by remember { mutableStateOf(0) }
    var lastTapAt by remember { mutableStateOf(0L) }
    var dragActive by remember { mutableStateOf(false) }
    var dragStartNormalized by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var pressStartedAt by remember { mutableStateOf(0L) }
    var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
    var lastInteractionTime by remember { mutableStateOf(System.currentTimeMillis()) }
    val stats by pipeline.stats.collectAsState()

    LaunchedEffect(lastInteractionTime, toolsCollapsed, customizeOpen, typingOpen) {
        if (!toolsCollapsed && !customizeOpen && !typingOpen) {
            delay(2000)
            toolsCollapsed = true
        }
    }
    val phase by pipeline.phase.collectAsState()
    val coroutineScope = rememberCoroutineScope()
    val fit = ScreenMirrorFit.entries.firstOrNull { it.name == fitName } ?: ScreenMirrorFit.FIT
    val controlMode = ScreenMirrorControlMode.entries.firstOrNull { it.name == controlModeName }
        ?: ScreenMirrorControlMode.VIEW
    val smartZoomMode = SmartZoomMode.entries.firstOrNull { it.name == smartZoomModeName } ?: SmartZoomMode.SMART
    val aspect = (stats.widthPx.toFloat() / stats.heightPx.toFloat())
        .takeIf { it.isFinite() && it > 0.1f }
        ?: (16f / 9f)
    val statusText = screenShareStatusText(
        phase = phase,
        stats = stats,
        nowMillis = nowMillis,
        lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
    )
    val streamNeedsRecovery = screenShareNeedsAutomaticRecovery(
        phase = phase,
        stats = stats,
        nowMillis = nowMillis,
        lastPeerHeartbeatAtMillis = lastPeerHeartbeatAtMillis,
    )
    var lastAutomaticReconnectAtMillis by remember { mutableStateOf(0L) }

    fun beginManualSmartZoomOverride() {
        smartZoomManualOverrideUntilMillis = System.currentTimeMillis() +
            ScreenShareSmartZoomReducer.MANUAL_OVERRIDE_HOLD_MILLIS
    }

    fun recomputeSmartZoomDecision(rootSize: IntSize) {
        val bounds = ScreenMirrorInputPolicy.surfaceBounds(rootSize, fit, aspect) ?: return
        val viewportSize = IntSize(bounds.width.toInt(), bounds.height.toInt())
        val contentRect = androidx.compose.ui.geometry.Rect(
            left = 0f,
            top = 0f,
            right = bounds.width,
            bottom = bounds.height,
        )
        smartZoomDecision = ScreenShareSmartZoomReducer.reduce(
            viewportSize = viewportSize,
            contentRect = contentRect,
            currentScale = smartZoomDecision.scale,
            currentTranslation = smartZoomDecision.translation,
            context = latestFocusContext,
            mode = smartZoomMode,
            selectedDisplayId = activeDisplayId,
            manualOverrideUntilMillis = smartZoomManualOverrideUntilMillis,
            nowMillis = System.currentTimeMillis(),
        )
    }

    LaunchedEffect(latestFocusContext, smartZoomMode, activeDisplayId, aspect, fit, surfaceLayoutSize) {
        if (surfaceLayoutSize != IntSize.Zero) recomputeSmartZoomDecision(surfaceLayoutSize)
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .onSizeChanged { surfaceLayoutSize = it }
            .pointerInput(fit, aspect) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        lastInteractionTime = System.currentTimeMillis()
                        val activePointers = event.changes.filter { it.pressed }
                        if (activePointers.size >= 2) {
                            val p1 = activePointers[0]
                            val p2 = activePointers[1]

                            val currentDist = (p1.position - p2.position).getDistance()
                            val prevDist = (p1.previousPosition - p2.previousPosition).getDistance()

                            if (prevDist > 0f && currentDist > 0f) {
                                val scaleMultiplier = currentDist / prevDist

                                val currentCentroid = (p1.position + p2.position) / 2f
                                val prevCentroid = (p1.previousPosition + p2.previousPosition) / 2f
                                val panDelta = currentCentroid - prevCentroid

                                beginManualSmartZoomOverride()

                                val currentScale = smartZoomDecision.scale
                                val currentTranslation = smartZoomDecision.translation
                                val newScale = (currentScale * scaleMultiplier).coerceIn(1f, 5f)

                                val halfW = size.width / 2f
                                val halfH = size.height / 2f
                                val centroidX = currentCentroid.x - halfW
                                val centroidY = currentCentroid.y - halfH

                                var newTranslationX = (currentTranslation.x - centroidX) * scaleMultiplier + centroidX + panDelta.x
                                var newTranslationY = (currentTranslation.y - centroidY) * scaleMultiplier + centroidY + panDelta.y

                                val maxTransX = halfW * (newScale - 1f)
                                val maxTransY = halfH * (newScale - 1f)
                                newTranslationX = newTranslationX.coerceIn(-maxTransX, maxTransX)
                                newTranslationY = newTranslationY.coerceIn(-maxTransY, maxTransY)

                                smartZoomDecision = ScreenShareSmartZoomDecision(
                                    scale = newScale,
                                    translation = Offset(newTranslationX, newTranslationY),
                                    isAutoFollowing = false
                                )
                            }

                            event.changes.forEach { it.consume() }
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        val smartZoomSpring = spring<Float>(
            dampingRatio = Spring.DampingRatioLowBouncy,
            stiffness = Spring.StiffnessMediumLow,
        )
        val animatedScale by animateFloatAsState(
            targetValue = smartZoomDecision.scale,
            animationSpec = smartZoomSpring,
            label = "smartZoomScale",
        )
        val animatedTranslationX by animateFloatAsState(
            targetValue = smartZoomDecision.translation.x,
            animationSpec = smartZoomSpring,
            label = "smartZoomTranslationX",
        )
        val animatedTranslationY by animateFloatAsState(
            targetValue = smartZoomDecision.translation.y,
            animationSpec = smartZoomSpring,
            label = "smartZoomTranslationY",
        )
        val surfaceModifier = Modifier
            .screenMirrorSurface(fit = fit, aspect = aspect)
            .align(Alignment.Center)
            .graphicsLayer {
                scaleX = animatedScale
                scaleY = animatedScale
                translationX = animatedTranslationX
                translationY = animatedTranslationY
            }

        Box(modifier = surfaceModifier) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    SurfaceView(ctx).apply {
                        holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                        // Make native SurfaceView completely transparent to native touches,
                        // allowing the Compose gesture overlay to naturally receive pointer inputs.
                        setOnTouchListener { _, _ -> false }
                        isClickable = false
                        isFocusable = false
                        isLongClickable = false
                    }
                },
            )
            if (controlMode != ScreenMirrorControlMode.VIEW) {
                ScreenMirrorInputOverlay()
            }
        }

        if (controlMode != ScreenMirrorControlMode.VIEW) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(controlMode, fit, aspect) {
                        awaitPointerEventScope {
                            while (true) {
                                val event = awaitPointerEvent()
                                val down = event.changes.firstOrNull { it.pressed && !it.previousPressed }
                                if (down != null) {
                                    event.changes.forEach { it.consume() }
                                    val now = System.currentTimeMillis()
                                    pressStartedAt = now
                                    if (now - lastTapAt > 600) tapCount = 0
                                    lastTapAt = now
                                    tapCount += 1
                                    if (tapCount >= 3) {
                                        statsVisible = !statsVisible
                                        tapCount = 0
                                    }
                                    if (controlMode == ScreenMirrorControlMode.SCROLL) {
                                        ScreenMirrorInputPolicy.normalizedPoint(
                                            down.position, size, fit, aspect,
                                            smartZoomDecision.scale, smartZoomDecision.translation
                                        )?.let { point ->
                                            dragActive = true
                                            dragStartNormalized = point
                                        }
                                    }
                                }

                                val up = event.changes.firstOrNull { !it.pressed && it.previousPressed }
                                if (up != null) {
                                    event.changes.forEach { it.consume() }
                                    when (controlMode) {
                                        ScreenMirrorControlMode.TOUCH -> {
                                            ScreenMirrorInputPolicy.normalizedPoint(
                                                up.position, size, fit, aspect,
                                                smartZoomDecision.scale, smartZoomDecision.translation
                                            )?.let { point ->
                                                onTapNormalized(
                                                    point.first,
                                                    point.second,
                                                    ScreenMirrorInputPolicy.controlClickMouseButton(
                                                        heldMillis = System.currentTimeMillis() - pressStartedAt
                                                    ),
                                                    activeDisplayId,
                                                )
                                            }
                                        }
                                        ScreenMirrorControlMode.SCROLL -> {
                                            val start = dragStartNormalized
                                            val end = ScreenMirrorInputPolicy.normalizedPoint(
                                                up.position, size, fit, aspect,
                                                smartZoomDecision.scale, smartZoomDecision.translation
                                            )
                                            if (dragActive && start != null && end != null) {
                                                onScrollDragNormalized(start.first, start.second, end.first, end.second, activeDisplayId)
                                            }
                                            dragActive = false
                                            dragStartNormalized = null
                                        }
                                        ScreenMirrorControlMode.COPILOT -> {
                                            ScreenMirrorInputPolicy.normalizedPoint(
                                                up.position, size, fit, aspect,
                                                smartZoomDecision.scale, smartZoomDecision.translation
                                            )?.let { point ->
                                                coPilotTarget = point
                                                coPilotViewPoint = up.position
                                            }
                                        }
                                        ScreenMirrorControlMode.TRACKPAD,
                                        ScreenMirrorControlMode.VIEW -> Unit
                                    }
                                }
                            }
                        }
                    }
            )
        }

        if (controlMode == ScreenMirrorControlMode.COPILOT) {
            coPilotViewPoint?.let { pos ->
                CoPilotTargetReticle(position = pos)
            }
        }

        if (controlMode == ScreenMirrorControlMode.COPILOT && coPilotTarget != null) {
            CoPilotTargetOverlay(
                coPilotTarget = coPilotTarget!!,
                coPilotRuntime = coPilotRuntime,
                activeDisplayId = activeDisplayId,
                onRuntimeChange = { coPilotRuntime = it },
                onClearTarget = {
                    coPilotTarget = null
                    coPilotViewPoint = null
                },
                onAgentContextTargetNormalized = onAgentContextTargetNormalized,
                modifier = Modifier.align(Alignment.BottomCenter)
            )
        }

        if (controlMode == ScreenMirrorControlMode.TRACKPAD) {
            ScreenMirrorTrackpadSurface(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 18.dp, bottom = 138.dp),
                onMove = { delta ->
                    onPointerMove(delta.x.toDouble(), delta.y.toDouble())
                },
                onClick = onPointerClick,
            )
        }

        if (typingOpen) {
            RemoteKeyboardCaptureField(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 1.dp, bottom = 1.dp),
                onText = onTypeText,
                onKey = { key -> onShortcut(key, emptyList()) },
                onDismiss = { typingOpen = false },
            )
        }

        // Frosted-glass loading/stopped panel with custom rotating golden loader
        statusText?.let { message ->
            FrostedGlassStatusPanel(
                message = message,
                modifier = Modifier.align(Alignment.Center)
            )
        }

        // Highly polished diagnostic developer HUD stats overlay
        if (statsVisible) {
            DiagnosticStatsHud(
                stats = stats,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
            )
        }

        ScreenMirrorToolsDock(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 14.dp, vertical = 18.dp)
                .graphicsLayer {
                    scaleX = trayScale
                    scaleY = trayScale
                    transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 1f)
                },
            collapsed = toolsCollapsed,
            customizeOpen = customizeOpen,
            fit = fit,
            controlMode = controlMode,
            typingOpen = typingOpen,
            statsVisible = statsVisible,
            phaseLabel = when (phase) {
                VideoReceivePipeline.Phase.Idle -> "Preparing"
                is VideoReceivePipeline.Phase.Running -> when {
                    stats.queuedFrameCount == 0L -> "Waiting"
                    streamNeedsRecovery -> "Recovering"
                    else -> "Live"
                }
                is VideoReceivePipeline.Phase.Failed -> "Decoder"
                VideoReceivePipeline.Phase.Stopped -> "Stopped"
            },
            trayScale = trayScale,
            stats = stats,
            availableDisplays = availableDisplays,
            activeDisplayId = activeDisplayId,
            onSelectDisplay = { displayId ->
                activeDisplayId = displayId
                onSelectDisplay(displayId)
            },
            onTrayScaleChange = { trayScale = it },
            onToggleCollapsed = { toolsCollapsed = !toolsCollapsed },
            onToggleCustomize = { customizeOpen = !customizeOpen },
            onToggleStats = { statsVisible = !statsVisible },
            onCycleFit = { fitName = fit.next().name },
            onCycleControlMode = { controlModeName = controlMode.next().name },
            smartZoomMode = smartZoomMode,
            smartZoomAutoFollowing = smartZoomDecision.isAutoFollowing,
            onSelectSmartZoomMode = { mode ->
                smartZoomModeName = mode.name
                smartZoomManualOverrideUntilMillis = null
                if (mode == SmartZoomMode.OFF) {
                    smartZoomDecision = ScreenShareSmartZoomDecision.identity
                } else if (surfaceLayoutSize != IntSize.Zero) {
                    recomputeSmartZoomDecision(surfaceLayoutSize)
                }
            },
            onSelectControlMode = { mode ->
                controlModeName = mode.name
                if (mode == ScreenMirrorControlMode.VIEW) {
                    typingOpen = false
                }
            },
            onToggleTyping = {
                typingOpen = !typingOpen
                if (typingOpen && controlMode == ScreenMirrorControlMode.VIEW) {
                    controlModeName = ScreenMirrorControlMode.TOUCH.name
                }
            },
            onScrollUp = { onScrollNormalized(-0.16, activeDisplayId) },
            onScrollDown = { onScrollNormalized(0.16, activeDisplayId) },
            onEscape = { onShortcut("escape", emptyList()) },
            onCommandTab = { onShortcut("tab", listOf("command")) },
            onPasteClipboardToMac = onPasteClipboardToMac,
            onGrabClipboardFromMac = onGrabClipboardFromMac,
            onPanic = onPanic,
            controlStatus = controlStatus,
            onTrustControlDevice = onTrustControlDevice,
            onReconnect = onReconnect,
            onEnterPictureInPicture = onEnterPictureInPicture,
            onClose = onClose,
        )
    }

    DisposableEffect(pipeline) {
        onDispose {
            // Best-effort tear-down when the composable leaves composition.
            runBlocking { pipeline.stop() }
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            nowMillis = System.currentTimeMillis()
            delay(1_000)
        }
    }

    LaunchedEffect(streamNeedsRecovery, nowMillis) {
        if (!streamNeedsRecovery) return@LaunchedEffect
        if (nowMillis - lastAutomaticReconnectAtMillis < AUTO_RECOVERY_RETRY_MILLIS) return@LaunchedEffect
        lastAutomaticReconnectAtMillis = nowMillis
        onReconnect()
    }
}

private const val STALE_STREAM_MILLIS = 12_000L
private const val HEARTBEAT_FRESH_MILLIS = 7_500L
private const val AUTO_RECOVERY_RETRY_MILLIS = 15_000L

private val screenShareControlGradientColors = listOf(
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
    is VideoReceivePipeline.Phase.Running -> when {
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
    val heartbeatIsFresh = lastPeerHeartbeatAtMillis > 0L &&
        nowMillis - lastPeerHeartbeatAtMillis <= HEARTBEAT_FRESH_MILLIS
    return !heartbeatIsFresh && nowMillis - lastSignalAtMillis > STALE_STREAM_MILLIS
}

internal enum class ScreenMirrorFit {
    FIT,
    FILL,
    FLOAT;

    fun next(): ScreenMirrorFit = when (this) {
        FIT -> FILL
        FILL -> FLOAT
        FLOAT -> FIT
    }

    val label: String
        get() = when (this) {
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
    COPILOT;

    fun next(): ScreenMirrorControlMode = when (this) {
        VIEW -> TOUCH
        TOUCH -> TRACKPAD
        TRACKPAD -> SCROLL
        SCROLL -> COPILOT
        COPILOT -> VIEW
    }

    val label: String
        get() = when (this) {
            VIEW -> "View"
            TOUCH -> "Click"
            TRACKPAD -> "Trackpad"
            SCROLL -> "Scroll"
            COPILOT -> "Co-Pilot"
        }
}

private fun Modifier.screenMirrorSurface(fit: ScreenMirrorFit, aspect: Float): Modifier = when (fit) {
    ScreenMirrorFit.FIT -> this
        .fillMaxSize()
        .wrapContentSize(Alignment.Center)
        .aspectRatio(aspect)
    ScreenMirrorFit.FILL -> this.fillMaxSize()
    ScreenMirrorFit.FLOAT -> this
        .fillMaxSize(0.92f)
        .wrapContentSize(Alignment.Center)
        .aspectRatio(aspect)
        .clip(RoundedCornerShape(18.dp))
        .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(18.dp))
}

@Composable
private fun ScreenMirrorInputOverlay() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .border(
                width = 1.dp,
                color = AuroraColors.hermesMercury.copy(alpha = 0.48f),
                shape = RoundedCornerShape(18.dp),
            ),
    )
}

@Composable
private fun CoPilotTargetReticle(
    position: Offset,
    modifier: Modifier = Modifier
) {
    val infiniteTransition = rememberInfiniteTransition(label = "reticle")
    val scale by infiniteTransition.animateFloat(
        initialValue = 0.85f,
        targetValue = 1.15f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "scale"
    )

    Canvas(
        modifier = modifier
            .fillMaxSize()
            .graphicsLayer {
                translationX = position.x - 24.dp.toPx()
                translationY = position.y - 24.dp.toPx()
                scaleX = scale
                scaleY = scale
            }
            .size(48.dp)
    ) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val radiusOuter = 24.dp.toPx()
        val radiusInner = 14.dp.toPx()

        // Outermost circle
        drawCircle(
            color = Color.Red,
            radius = radiusOuter,
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx())
        )

        // Reticle lines (crosshairs)
        // Top
        drawLine(
            color = Color.Red,
            start = Offset(center.x, center.y - radiusOuter),
            end = Offset(center.x, center.y - radiusInner),
            strokeWidth = 2.dp.toPx()
        )
        // Bottom
        drawLine(
            color = Color.Red,
            start = Offset(center.x, center.y + radiusInner),
            end = Offset(center.x, center.y + radiusOuter),
            strokeWidth = 2.dp.toPx()
        )
        // Left
        drawLine(
            color = Color.Red,
            start = Offset(center.x - radiusOuter, center.y),
            end = Offset(center.x - radiusInner, center.y),
            strokeWidth = 2.dp.toPx()
        )
        // Right
        drawLine(
            color = Color.Red,
            start = Offset(center.x + radiusInner, center.y),
            end = Offset(center.x + radiusOuter, center.y),
            strokeWidth = 2.dp.toPx()
        )

        // Center core dot
        drawCircle(
            color = Color.Red,
            radius = 3.dp.toPx()
        )
    }
}

@Composable
private fun ScreenMirrorTrackpadSurface(
    modifier: Modifier = Modifier,
    onMove: (Offset) -> Unit,
    onClick: (Int) -> Unit,
) {
    var touchLocation by remember { mutableStateOf<Offset?>(null) }
    var touchHistory by remember { mutableStateOf<List<Offset>>(emptyList()) }
    var lastPosition by remember { mutableStateOf<Offset?>(null) }
    var pressStartedAt by remember { mutableStateOf(0L) }
    var travelDistance by remember { mutableStateOf(0f) }

    Box(
        modifier = modifier
            .fillMaxWidth(0.48f)
            .widthIn(min = 170.dp, max = 360.dp)
            .heightIn(min = 130.dp, max = 260.dp)
            .aspectRatio(1.45f)
            .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.38f, shadow = AuroraShadows.large)
            .border(
                width = 1.dp,
                color = if (touchLocation != null) AuroraColors.hermesMercury.copy(alpha = 0.84f) else Color.White.copy(alpha = 0.16f),
                shape = RoundedCornerShape(24.dp),
            )
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val down = event.changes.firstOrNull { it.pressed && !it.previousPressed }
                        if (down != null) {
                            event.changes.forEach { it.consume() }
                            pressStartedAt = System.currentTimeMillis()
                            travelDistance = 0f
                            lastPosition = down.position
                            touchLocation = down.position
                            touchHistory = listOf(down.position)
                        }

                        val move = event.changes.firstOrNull { it.pressed && it.previousPressed }
                        if (move != null) {
                            event.changes.forEach { it.consume() }
                            val last = lastPosition
                            val current = move.position
                            if (last != null) {
                                val delta = current - last
                                if (abs(delta.x) > 0.5f || abs(delta.y) > 0.5f) {
                                    onMove(delta)
                                    travelDistance += hypot(delta.x, delta.y)
                                }
                            }
                            lastPosition = current
                            touchLocation = current
                            touchHistory = (touchHistory + current).takeLast(4)
                        }

                        val up = event.changes.firstOrNull { !it.pressed && it.previousPressed }
                        if (up != null) {
                            event.changes.forEach { it.consume() }
                            ScreenMirrorInputPolicy.trackpadClickMouseButton(
                                heldMillis = System.currentTimeMillis() - pressStartedAt,
                                travelDistancePx = travelDistance,
                            )?.let(onClick)
                            touchLocation = null
                            touchHistory = emptyList()
                            lastPosition = null
                            travelDistance = 0f
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val lineColor = Color.White.copy(alpha = 0.05f)
            repeat(5) { index ->
                val y = size.height * (index + 1) / 6f
                drawLine(lineColor, Offset(0f, y), Offset(size.width, y), strokeWidth = 1.dp.toPx())
                val x = size.width * (index + 1) / 6f
                drawLine(lineColor, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1.dp.toPx())
            }
            touchHistory.forEachIndexed { index, point ->
                val age = touchHistory.lastIndex - index
                val alpha = (0.72f - age * 0.16f).coerceAtLeast(0.12f)
                drawCircle(
                    color = AuroraColors.hermesMercury.copy(alpha = alpha),
                    radius = (14f - age * 2.5f).coerceAtLeast(4f),
                    center = point,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.5.dp.toPx()),
                )
            }
        }
        Text(
            text = "Glass Trackpad",
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(14.dp),
            color = Color.White.copy(alpha = 0.76f),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
        )
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

internal object ScreenMirrorInputPolicy {
    const val RIGHT_CLICK_HOLD_MILLIS: Long = 550L
    const val TRACKPAD_TAP_TRAVEL_LIMIT_PX: Float = 8f

    fun controlClickMouseButton(heldMillis: Long): Int =
        if (heldMillis >= RIGHT_CLICK_HOLD_MILLIS) 1 else 0

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
        val unzoomed = inverseSmartZoom(
            local = Offset(localX, localY),
            bounds = bounds,
            smartZoomScale = smartZoomScale,
            smartZoomTranslation = smartZoomTranslation,
        )
        if (unzoomed.x < 0f || unzoomed.y < 0f || unzoomed.x > bounds.width || unzoomed.y > bounds.height) {
            return null
        }
        return Pair(
            (unzoomed.x / bounds.width).coerceIn(0f, 1f).toDouble(),
            (unzoomed.y / bounds.height).coerceIn(0f, 1f).toDouble(),
        )
    }

    fun inverseSmartZoom(
        local: Offset,
        bounds: ScreenMirrorSurfaceBounds,
        smartZoomScale: Float,
        smartZoomTranslation: Offset,
    ): Offset {
        if (smartZoomScale <= 0.0001f) return local
        val halfW = bounds.width / 2f
        val halfH = bounds.height / 2f
        val x = ((local.x - halfW - smartZoomTranslation.x) / smartZoomScale) + halfW
        val y = ((local.y - halfH - smartZoomTranslation.y) / smartZoomScale) + halfH
        return Offset(x, y)
    }

    fun initialCursorPoint(rootSize: IntSize, fit: ScreenMirrorFit, aspect: Float): Offset? =
        surfaceBounds(rootSize, fit, aspect)?.center

    fun clampedCursorPoint(position: Offset, rootSize: IntSize, fit: ScreenMirrorFit, aspect: Float): Offset? {
        val bounds = surfaceBounds(rootSize, fit, aspect) ?: return null
        return Offset(
            x = position.x.coerceIn(bounds.left, bounds.right),
            y = position.y.coerceIn(bounds.top, bounds.bottom),
        )
    }

    fun movedCursorPoint(
        current: Offset?,
        delta: Offset,
        rootSize: IntSize,
        fit: ScreenMirrorFit,
        aspect: Float,
    ): Offset? {
        val bounds = surfaceBounds(rootSize, fit, aspect) ?: return null
        val base = current ?: bounds.center
        return Offset(
            x = (base.x + delta.x).coerceIn(bounds.left, bounds.right),
            y = (base.y + delta.y).coerceIn(bounds.top, bounds.bottom),
        )
    }
}

@Composable
internal fun ScreenMirrorToolsDock(
    modifier: Modifier = Modifier,
    collapsed: Boolean,
    customizeOpen: Boolean,
    fit: ScreenMirrorFit,
    controlMode: ScreenMirrorControlMode,
    typingOpen: Boolean,
    statsVisible: Boolean,
    phaseLabel: String,
    trayScale: Float,
    stats: VideoReceivePipeline.Stats,
    availableDisplays: List<HermesRealtimeRelayDisplayDescriptor>,
    activeDisplayId: String?,
    onSelectDisplay: (String) -> Unit,
    onTrayScaleChange: (Float) -> Unit,
    onToggleCollapsed: () -> Unit,
    onToggleCustomize: () -> Unit,
    onToggleStats: () -> Unit,
    onCycleFit: () -> Unit,
    onCycleControlMode: () -> Unit,
    smartZoomMode: SmartZoomMode,
    smartZoomAutoFollowing: Boolean,
    onSelectSmartZoomMode: (SmartZoomMode) -> Unit,
    onSelectControlMode: (ScreenMirrorControlMode) -> Unit,
    onToggleTyping: () -> Unit,
    onScrollUp: () -> Unit,
    onScrollDown: () -> Unit,
    onEscape: () -> Unit,
    onCommandTab: () -> Unit,
    onPasteClipboardToMac: () -> Unit,
    onGrabClipboardFromMac: () -> Unit,
    onPanic: () -> Unit,
    controlStatus: String?,
    onTrustControlDevice: () -> Unit,
    onReconnect: () -> Unit,
    onEnterPictureInPicture: () -> Unit,
    onClose: () -> Unit,
) {
    val scale = 1.0f
    val dockShape = RoundedCornerShape(24.dp)
    val mercuryBrush = Brush.linearGradient(screenShareControlGradientColors)
    val dockSheen = Brush.linearGradient(
        colors = listOf(
            screenShareControlGradientColors.first().copy(alpha = 0.16f),
            Color.White.copy(alpha = 0.05f),
            screenShareControlGradientColors.last().copy(alpha = 0.14f),
        ),
        start = Offset.Zero,
        end = Offset(900f, 380f),
    )
    if (collapsed) {
        Box(
            modifier = modifier
                .wrapContentWidth()
                .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.45f, shadow = AuroraShadows.large)
                .clickable { onToggleCollapsed() }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            contentAlignment = Alignment.Center
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Dot 1: Red (Close)
                Box(
                    modifier = Modifier
                        .size(12.dp)
                        .clip(CircleShape)
                        .background(Color(0xFFFF5F56))
                        .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
                        .clickable { onClose() }
                )
                // Dot 2: Yellow/Amber (Toggle Stats)
                val dotColor = if (statsVisible) Color(0xFFFFBD2E) else Color(0xFFFFBD2E).copy(alpha = 0.6f)
                Box(
                    modifier = Modifier
                        .size(12.dp)
                        .clip(CircleShape)
                        .background(dotColor)
                        .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
                        .clickable { onToggleStats() }
                )
                // Dot 3: Green (Expand)
                Box(
                    modifier = Modifier
                        .size(12.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF27C93F))
                        .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
                        .clickable { onToggleCollapsed() }
                )
            }
        }
    } else {
        Column(
            modifier = modifier
                .fillMaxWidth()
                .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.36f, shadow = AuroraShadows.large)
                .background(dockSheen, dockShape)
                .border(1.5.dp, mercuryBrush, dockShape)
                .animateContentSize()
                .pointerInput(Unit) {} // Prevent touch events on the tools tray from triggering Mac input!
                .padding(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            // Horizontally scrollable row of square glass keycaps exactly matching iOS!
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 6.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (statsVisible) {
                    // Premium Compact Stats Capsule
                    CompactStatsChip(
                        roundTripMillis = stats.roundTripMillis,
                        bitrateMbps = (stats.bitsPerSecond / 1_000_000.0).toFloat()
                    )
                }

                KeycapButton(
                    icon = Icons.Filled.Tune,
                    selected = customizeOpen,
                    label = "Details",
                    contentDescription = if (customizeOpen) {
                        "Hide detailed controls"
                    } else {
                        "Show detailed controls"
                    },
                    onClick = onToggleCustomize,
                    modifier = Modifier.width(68.dp),
                )

                ScreenMirrorControlMode.entries.forEach { mode ->
                    ControlModeKeycap(
                        mode = mode,
                        selected = controlMode == mode,
                        onClick = { onSelectControlMode(mode) },
                    )
                }

                // Display selector Menus / cycler
                if (!availableDisplays.isNullOrEmpty() && availableDisplays.size > 1) {
                    val currentIndex = availableDisplays.indexOfFirst { it.id == activeDisplayId }.coerceAtLeast(0)
                    val nextIndex = (currentIndex + 1) % availableDisplays.size
                    val nextDisplay = availableDisplays[nextIndex]
                    KeycapButton(
                        icon = Icons.Filled.Tv,
                        selected = false,
                        contentDescription = "Switch display",
                        onClick = { onSelectDisplay(nextDisplay.id) }
                    )
                }

                KeycapButton(
                    icon = Icons.Filled.AspectRatio,
                    selected = false,
                    contentDescription = "Cycle fit mode",
                    onClick = onCycleFit
                )

                // 6b. Smart Zoom toggle (tap toggles On/Off; long-press picks a specific mode)
                SmartZoomKeycap(
                    mode = smartZoomMode,
                    autoFollowing = smartZoomAutoFollowing,
                    onToggle = {
                        onSelectSmartZoomMode(
                            if (smartZoomMode == SmartZoomMode.OFF) SmartZoomMode.SMART
                            else SmartZoomMode.OFF
                        )
                    },
                    onSelectMode = onSelectSmartZoomMode,
                )

                KeycapButton(
                    icon = Icons.Filled.ExpandLess,
                    selected = false,
                    contentDescription = "Scroll up",
                    onClick = onScrollUp
                )
                KeycapButton(
                    icon = Icons.Filled.ExpandMore,
                    selected = false,
                    contentDescription = "Scroll down",
                    onClick = onScrollDown
                )

                KeycapButton(
                    icon = Icons.Filled.Keyboard,
                    selected = typingOpen,
                    contentDescription = "Type on Mac",
                    onClick = onToggleTyping
                )

                // 10. Remote clipboard: phone clipboard -> Mac paste
                KeycapButton(
                    icon = Icons.Filled.ContentPaste,
                    selected = false,
                    contentDescription = "Paste to Mac",
                    onClick = onPasteClipboardToMac
                )

                // 11. Remote clipboard: Mac clipboard -> phone
                KeycapButton(
                    icon = Icons.Filled.Download,
                    selected = false,
                    contentDescription = "Grab from Mac",
                    onClick = onGrabClipboardFromMac
                )

                // 12. Reconnect
                KeycapButton(
                    icon = Icons.Filled.Refresh,
                    selected = false,
                    contentDescription = "Reconnect mirror",
                    onClick = onReconnect
                )

                KeycapButton(
                    icon = Icons.Filled.Computer,
                    selected = false,
                    contentDescription = "Enter Picture in Picture",
                    onClick = onEnterPictureInPicture
                )

                KeycapButton(
                    icon = Icons.Filled.ExpandLess,
                    selected = false,
                    contentDescription = "Collapse mirror controls",
                    onClick = onToggleCollapsed
                )

                KeycapButton(
                    icon = Icons.Filled.Close,
                    selected = false,
                    contentDescription = "Close mirror",
                    onClick = onClose
                )
            }

            if (customizeOpen) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalArrangement = Arrangement.spacedBy((8 * scale).dp)
                ) {
                    Text(
                        "Detailed controls",
                        color = Color.White.copy(alpha = 0.72f),
                        style = AuroraType.monoTiny.copy(
                            fontSize = (10 * scale).sp,
                            fontWeight = FontWeight.Bold,
                        ),
                    )
                    DockToggleRow(
                        label = "Stream stats",
                        checked = statsVisible,
                        scale = scale,
                        onCheckedChange = { onToggleStats() },
                    )

                    // Resizable slide control inside customize settings (flicker-free!)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy((8 * scale).dp),
                    ) {
                        Text(
                            "Tray size",
                            color = Color.White.copy(alpha = 0.76f),
                            style = AuroraType.caption.copy(fontSize = (12 * scale).sp),
                            modifier = Modifier.weight(1f)
                        )
                        androidx.compose.material3.Slider(
                            value = trayScale,
                            onValueChange = onTrayScaleChange,
                            valueRange = 0.5f..1.2f,
                            modifier = Modifier
                                .weight(2f)
                                .height((30 * scale).dp)
                        )
                    }

                    // Display selection list in Customize
                    if (!availableDisplays.isNullOrEmpty()) {
                        Text(
                            "Select Display",
                            color = Color.White.copy(alpha = 0.56f),
                            style = AuroraType.monoTiny.copy(fontSize = (9 * scale).sp),
                            modifier = Modifier.padding(top = (8 * scale).dp)
                        )
                        availableDisplays.forEach { display ->
                            val isSelected = display.id == activeDisplayId
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onSelectDisplay(display.id) }
                                    .padding(vertical = (4 * scale).dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    display.name,
                                    color = if (isSelected) AuroraColors.hermesMercury else Color.White.copy(alpha = 0.8f),
                                    style = AuroraType.caption.copy(
                                        fontSize = (12 * scale).sp,
                                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
                                    )
                                )
                                if (isSelected) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = "Selected",
                                        tint = AuroraColors.hermesMercury,
                                        modifier = Modifier.size((14 * scale).dp)
                                    )
                                }
                            }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy((8 * scale).dp),
                    ) {
                        MirrorToolButton(Icons.Filled.VerifiedUser, "Trust", scale = scale, onClick = onTrustControlDevice)
                        MirrorToolButton(Icons.Filled.KeyboardDoubleArrowUp, "Up", scale = scale, onClick = onScrollUp)
                        MirrorToolButton(Icons.Filled.KeyboardDoubleArrowDown, "Down", scale = scale, onClick = onScrollDown)
                        MirrorToolButton(Icons.Filled.Close, "Esc", scale = scale, onClick = onEscape)
                        MirrorToolButton(Icons.AutoMirrored.Filled.KeyboardTab, "Cmd Tab", scale = scale, onClick = onCommandTab)
                    }
                    MirrorToolButton(Icons.Filled.Report, "Panic", scale = scale, onClick = onPanic)

                    DockInfoRow("Fit mode", fit.label, scale = scale)
                    DockInfoRow("Input mode", controlMode.label, scale = scale)
                    controlStatus?.let { DockInfoRow("Mac control", it, scale = scale) }
                    DockInfoRow("Tools", "Collapsible + signed", scale = scale)
                }
            }
        }
    }
}

@Composable
private fun MirrorModePicker(
    controlMode: ScreenMirrorControlMode,
    scale: Float,
    onSelect: (ScreenMirrorControlMode) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy((6 * scale).dp),
    ) {
        listOf(
            ScreenMirrorControlMode.VIEW,
            ScreenMirrorControlMode.TOUCH,
            ScreenMirrorControlMode.TRACKPAD,
            ScreenMirrorControlMode.SCROLL,
        ).forEach { mode ->
            val selected = mode == controlMode
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape((10 * scale).dp))
                    .background(if (selected) AuroraColors.hermesMercury.copy(alpha = 0.28f) else Color.White.copy(alpha = 0.08f))
                    .border(
                        width = 1.dp,
                        color = if (selected) AuroraColors.hermesMercury.copy(alpha = 0.62f) else Color.White.copy(alpha = 0.10f),
                        shape = RoundedCornerShape((10 * scale).dp),
                    )
                    .clickable { onSelect(mode) }
                    .padding(vertical = (9 * scale).dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = mode.label,
                    color = Color.White.copy(alpha = if (selected) 0.98f else 0.68f),
                    style = AuroraType.monoTiny.copy(
                        fontWeight = FontWeight.Bold,
                        fontSize = (9 * scale).sp
                    ),
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun RemoteKeyboardCaptureField(
    modifier: Modifier = Modifier,
    onText: (String) -> Unit,
    onKey: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var capturedText by remember { mutableStateOf("") }
    var hasFocused by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current

    DisposableEffect(Unit) {
        onDispose {
            keyboardController?.hide()
        }
    }

    LaunchedEffect(Unit) {
        listOf(80L, 220L, 420L).forEach { delayMillis ->
            delay(delayMillis)
            focusRequester.requestFocus()
            keyboardController?.show()
        }
    }

    BasicTextField(
        value = capturedText,
        onValueChange = { newText ->
            val diff = remoteKeyboardDiff(capturedText, newText)
            repeat(diff.deletedCount.coerceAtMost(64)) {
                onKey("delete")
            }
            dispatchRemoteKeyboardText(diff.insertedText, onText = onText, onKey = onKey)
            capturedText = if (newText.length > 256) "" else newText
        },
        modifier = modifier
            .size(1.dp)
            .focusRequester(focusRequester)
            .onFocusChanged { state ->
                if (state.isFocused) {
                    hasFocused = true
                } else if (hasFocused) {
                    onDismiss()
                }
            },
        textStyle = AuroraType.caption.copy(color = Color.Transparent, fontSize = 1.sp),
        cursorBrush = SolidColor(Color.Transparent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { onKey("return") }),
        decorationBox = { innerTextField ->
            Box(modifier = Modifier.size(1.dp)) {
                innerTextField()
            }
        },
    )
}

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

internal fun dispatchRemoteKeyboardText(
    text: String,
    onText: (String) -> Unit,
    onKey: (String) -> Unit,
) {
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

@Composable
private fun StatusChip(label: String, scale: Float) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(
                if (label == "Live") AuroraColors.successDark.copy(alpha = 0.22f)
                else Color.White.copy(alpha = 0.12f)
            )
            .padding(horizontal = (10 * scale).dp, vertical = (7 * scale).dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy((7 * scale).dp),
    ) {
        Box(
            modifier = Modifier
                .size((7 * scale).dp)
                .clip(CircleShape)
                .background(if (label == "Live") AuroraColors.successDark else AuroraColors.amber)
        )
        Text(
            text = label,
            color = Color.White,
            style = AuroraType.monoTiny.copy(
                fontWeight = FontWeight.Bold,
                fontSize = (9 * scale).sp
            ),
        )
    }
}

@Composable
private fun MirrorToolButton(
    icon: ImageVector,
    label: String,
    scale: Float,
    onClick: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        IconButton(
            onClick = onClick,
            modifier = Modifier
                .size((42 * scale).dp)
                .mirrorKeycapChrome(selected = false, shape = CircleShape)
        ) {
            Icon(
                icon,
                contentDescription = label,
                tint = Color.White,
                modifier = Modifier.size((24 * scale).dp)
            )
        }
        Text(
            label,
            color = Color.White.copy(alpha = 0.68f),
            style = AuroraType.monoTiny.copy(fontSize = (9 * scale).sp)
        )
    }
}

@Composable
private fun DockToggleRow(label: String, checked: Boolean, scale: Float, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            label,
            color = Color.White.copy(alpha = 0.76f),
            style = AuroraType.caption.copy(fontSize = (12 * scale).sp)
        )
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            modifier = Modifier.graphicsLayer(scaleX = scale, scaleY = scale)
        )
    }
}

@Composable
private fun DockInfoRow(label: String, value: String, scale: Float) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            label,
            color = Color.White.copy(alpha = 0.56f),
            style = AuroraType.monoTiny.copy(fontSize = (9 * scale).sp)
        )
        Text(
            value,
            color = Color.White,
            style = AuroraType.monoTiny.copy(
                fontWeight = FontWeight.Bold,
                fontSize = (9 * scale).sp
            )
        )
    }
}

private class SurfaceCallback(
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

@Composable
private fun CompactStatsChip(roundTripMillis: Int, bitrateMbps: Float) {
    Row(
        modifier = Modifier
            .height(42.dp)
            .background(Color.White.copy(alpha = 0.10f), CircleShape)
            .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = "%.2f Mbps".format(bitrateMbps),
            color = Color.White.copy(alpha = 0.86f),
            style = AuroraType.monoTiny.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        )
        Text(
            text = "RTT ${roundTripMillis} ms",
            color = Color.White.copy(alpha = 0.86f),
            style = AuroraType.monoTiny.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        )
    }
}

@Composable
private fun Modifier.mirrorKeycapChrome(
    selected: Boolean,
    shape: Shape = RoundedCornerShape(12.dp),
): Modifier {
    val fill = if (selected) {
        Brush.linearGradient(
            colors = listOf(
                screenShareControlGradientColors.first().copy(alpha = 0.30f),
                screenShareControlGradientColors.last().copy(alpha = 0.22f),
            ),
            start = Offset.Zero,
            end = Offset(220f, 220f),
        )
    } else {
        Brush.verticalGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.11f),
                Color.White.copy(alpha = 0.045f),
            ),
        )
    }
    val stroke = if (selected) {
        Brush.linearGradient(
            colors = screenShareControlGradientColors,
            start = Offset.Zero,
            end = Offset(160f, 160f),
        )
    } else {
        Brush.linearGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.16f),
                Color.White.copy(alpha = 0.055f),
            ),
            start = Offset.Zero,
            end = Offset(120f, 120f),
        )
    }

    val keycap = if (selected) {
        this.shadow(
            elevation = 7.dp,
            shape = shape,
            clip = false,
            spotColor = screenShareControlGradientColors.first().copy(alpha = 0.42f),
            ambientColor = screenShareControlGradientColors.last().copy(alpha = 0.22f),
        )
    } else {
        this.shadow(
            elevation = 2.dp,
            shape = shape,
            clip = false,
            spotColor = Color.Black.copy(alpha = 0.18f),
            ambientColor = Color.Black.copy(alpha = 0.12f),
        )
    }

    return keycap
        .clip(shape)
        .background(fill, shape)
        .border(if (selected) 1.5.dp else 1.dp, stroke, shape)
}

@Composable
private fun ControlModeKeycap(
    mode: ScreenMirrorControlMode,
    selected: Boolean,
    onClick: () -> Unit,
) {
    KeycapButton(
        icon = screenMirrorControlIcon(mode),
        selected = selected,
        label = screenMirrorControlLabel(mode),
        contentDescription = screenMirrorControlContentDescription(mode),
        onClick = onClick,
        modifier = Modifier.width(screenMirrorControlWidth(mode)),
    )
}

private fun screenMirrorControlIcon(mode: ScreenMirrorControlMode): ImageVector = when (mode) {
    ScreenMirrorControlMode.VIEW -> Icons.Filled.Visibility
    ScreenMirrorControlMode.TOUCH -> Icons.Filled.AdsClick
    ScreenMirrorControlMode.TRACKPAD -> Icons.Filled.Mouse
    ScreenMirrorControlMode.SCROLL -> Icons.Filled.SwipeVertical
    ScreenMirrorControlMode.COPILOT -> Icons.Filled.TrackChanges
}

private fun screenMirrorControlLabel(mode: ScreenMirrorControlMode): String = when (mode) {
    ScreenMirrorControlMode.VIEW -> "View"
    ScreenMirrorControlMode.TOUCH -> "Click"
    ScreenMirrorControlMode.TRACKPAD -> "Trackpad"
    ScreenMirrorControlMode.SCROLL -> "Scroll"
    ScreenMirrorControlMode.COPILOT -> "Co-Pilot"
}

private fun screenMirrorControlWidth(mode: ScreenMirrorControlMode) = when (mode) {
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

@Composable
private fun KeycapButton(
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    label: String? = null,
    contentDescription: String? = null,
) {
    val semanticModifier = if (contentDescription != null) {
        modifier.semantics { this.contentDescription = contentDescription }
    } else {
        modifier
    }
    Box(
        modifier = semanticModifier
            .height(if (label == null) 42.dp else 54.dp)
            .widthIn(min = if (label == null) 42.dp else 56.dp)
            .mirrorKeycapChrome(selected = selected)
            .clickable { onClick() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) Color.White else Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(if (label == null) 20.dp else 19.dp)
            )
            label?.let {
                Text(
                    text = it,
                    color = if (selected) Color.White else Color.White.copy(alpha = 0.76f),
                    style = AuroraType.monoTiny.copy(
                        fontSize = 8.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                    maxLines = 1,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 3.dp),
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SmartZoomKeycap(
    mode: SmartZoomMode,
    autoFollowing: Boolean,
    onToggle: () -> Unit,
    onSelectMode: (SmartZoomMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val selected = mode != SmartZoomMode.OFF
    val icon = when (mode) {
        SmartZoomMode.OFF -> Icons.Filled.CropFree
        SmartZoomMode.SMART -> Icons.Filled.AutoAwesome
        SmartZoomMode.TEXT -> Icons.Filled.TextFields
        SmartZoomMode.WINDOW -> Icons.Filled.HighlightAlt
        SmartZoomMode.CURSOR -> Icons.Filled.NorthWest
    }
    val accessibilityLabel = "Smart Zoom: ${mode.label}" +
        if (autoFollowing) ", auto-following" else ""
    Box(
        modifier = modifier
            .size(42.dp)
            .semantics { contentDescription = accessibilityLabel }
            .mirrorKeycapChrome(selected = selected)
            .combinedClickable(
                onClick = { onToggle() },
                onLongClick = { menuOpen = true },
            ),
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) Color.White else Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(20.dp),
            )
        }
        if (autoFollowing) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(2.dp)
                    .clip(CircleShape)
                    .background(
                        androidx.compose.ui.graphics.Brush.linearGradient(
                            colors = listOf(
                                Color(0xFF2BCAB9),
                                Color(0xFF8E80D8),
                            ),
                        ),
                    )
                    .size(8.dp),
            )
        }
        DropdownMenu(
            expanded = menuOpen,
            onDismissRequest = { menuOpen = false },
        ) {
            SmartZoomMode.entries.forEach { entry ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = entry.label + if (entry == mode) " ·" else "",
                            color = Color.White,
                            fontSize = 13.sp,
                        )
                    },
                    onClick = {
                        onSelectMode(entry)
                        menuOpen = false
                    },
                    leadingIcon = {
                        Icon(
                            imageVector = when (entry) {
                                SmartZoomMode.OFF -> Icons.Filled.CropFree
                                SmartZoomMode.SMART -> Icons.Filled.AutoAwesome
                                SmartZoomMode.TEXT -> Icons.Filled.TextFields
                                SmartZoomMode.WINDOW -> Icons.Filled.HighlightAlt
                                SmartZoomMode.CURSOR -> Icons.Filled.NorthWest
                            },
                            contentDescription = null,
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(18.dp),
                        )
                    },
                )
            }
        }
    }
}

@Composable
private fun CoPilotTargetOverlay(
    coPilotTarget: Pair<Double, Double>,
    coPilotRuntime: String,
    activeDisplayId: String?,
    onRuntimeChange: (String) -> Unit,
    onClearTarget: () -> Unit,
    onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit,
    modifier: Modifier = Modifier
) {
    var inputInstruction by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current

    LaunchedEffect(coPilotTarget) {
        focusRequester.requestFocus()
    }

    Box(
        modifier = modifier
            .padding(start = 16.dp, end = 16.dp, bottom = 120.dp) // Stay above the dock
            .widthIn(max = 420.dp)
            .fillMaxWidth()
            .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.38f, shadow = AuroraShadows.large)
            .padding(18.dp)
            .pointerInput(Unit) {} // Prevent click-throughs
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Canvas(modifier = Modifier.size(8.dp)) {
                        drawCircle(Color.Red)
                    }
                    Text(
                        text = "Agent Co-Pilot Target Locked",
                        color = Color.White,
                        style = AuroraType.body.copy(fontWeight = FontWeight.Bold)
                    )
                }
                IconButton(
                    onClick = onClearTarget,
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = "Clear target",
                        tint = Color.White.copy(alpha = 0.5f)
                    )
                }
            }

            // Segmented Selector for Agent Runtime
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(8.dp))
                    .padding(2.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                val runtimes = listOf("hermes", "pi", "codex", "claude", "openclaw")
                runtimes.forEach { runtimeOption ->
                    val isSelected = coPilotRuntime == runtimeOption
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(6.dp))
                            .background(if (isSelected) Color.White.copy(alpha = 0.12f) else Color.Transparent)
                            .clickable { onRuntimeChange(runtimeOption) }
                            .padding(vertical = 6.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = runtimeOption.replaceFirstChar { it.uppercase() },
                            color = if (isSelected) Color.White else Color.White.copy(alpha = 0.6f),
                            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold)
                        )
                    }
                }
            }

            // Text Field for Instruction
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                BasicTextField(
                    value = inputInstruction,
                    onValueChange = { inputInstruction = it },
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(focusRequester),
                    textStyle = AuroraType.body.copy(color = Color.White),
                    cursorBrush = SolidColor(Color.White),
                    keyboardOptions = KeyboardOptions(
                        imeAction = ImeAction.Send
                    ),
                    keyboardActions = KeyboardActions(
                        onSend = {
                            val instr = inputInstruction.trim()
                            if (instr.isNotEmpty()) {
                                onAgentContextTargetNormalized(
                                    coPilotTarget.first,
                                    coPilotTarget.second,
                                    instr,
                                    coPilotRuntime,
                                    activeDisplayId
                                )
                                onClearTarget()
                                keyboardController?.hide()
                            }
                        }
                    ),
                    decorationBox = { innerTextField ->
                        if (inputInstruction.isEmpty()) {
                            Text(
                                text = "Enter instruction (e.g. 'click here')",
                                color = Color.White.copy(alpha = 0.4f),
                                style = AuroraType.body
                            )
                        }
                        innerTextField()
                    }
                )
                IconButton(
                    onClick = {
                        val instr = inputInstruction.trim()
                        if (instr.isNotEmpty()) {
                            onAgentContextTargetNormalized(
                                coPilotTarget.first,
                                coPilotTarget.second,
                                instr,
                                coPilotRuntime,
                                activeDisplayId
                            )
                            onClearTarget()
                            keyboardController?.hide()
                        }
                    },
                    enabled = inputInstruction.trim().isNotEmpty()
                ) {
                    Icon(
                        imageVector = Icons.Filled.Check,
                        contentDescription = "Submit instruction",
                        tint = if (inputInstruction.trim().isNotEmpty()) Color.Red else Color.White.copy(alpha = 0.3f)
                    )
                }
            }
        }
    }
}

@Composable
private fun FrostedGlassStatusPanel(
    message: String,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .width(280.dp)
            .auroraGlass(cornerRadius = 20.dp, tintAlpha = 0.35f, shadow = AuroraShadows.large)
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            val isLoading = message.contains("Preparing") || message.contains("Waiting")
            if (isLoading) {
                // Beautiful rotating golden loader ring
                val infiniteTransition = rememberInfiniteTransition(label = "loader")
                val rotation by infiniteTransition.animateFloat(
                    initialValue = 0f,
                    targetValue = 360f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(1000, easing = LinearEasing),
                        repeatMode = RepeatMode.Restart
                    ),
                    label = "rotation"
                )
                Canvas(modifier = Modifier.size(36.dp).graphicsLayer { rotationZ = rotation }) {
                    drawArc(
                        color = AuroraColors.amber,
                        startAngle = 0f,
                        sweepAngle = 270f,
                        useCenter = false,
                        style = androidx.compose.ui.graphics.drawscope.Stroke(
                            width = 3.dp.toPx(),
                            cap = androidx.compose.ui.graphics.StrokeCap.Round
                        )
                    )
                }
            } else {
                // Connection/stopped icon
                Icon(
                    imageVector = Icons.Filled.Computer,
                    contentDescription = null,
                    tint = if (message.contains("unavailable")) AuroraColors.errorDark else AuroraColors.hermesMercury,
                    modifier = Modifier.size(36.dp)
                )
            }
            Text(
                text = message,
                color = Color.White,
                style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                textAlign = TextAlign.Center
            )
        }
    }
}

@Composable
private fun DiagnosticStatsHud(
    stats: VideoReceivePipeline.Stats,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .width(200.dp)
            .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.35f, shadow = AuroraShadows.subtle)
            .padding(12.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                text = "MERCURY STREAM STATS",
                color = AuroraColors.hermesMercury,
                style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
            )

            Spacer(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Color.White.copy(alpha = 0.15f))
            )

            // Stat Rows
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("RESOLUTION", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                Text("${stats.widthPx}×${stats.heightPx}", style = AuroraType.monoTiny.copy(color = Color.White, fontWeight = FontWeight.Bold))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("CODEC", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                Text(stats.codecName.uppercase(), style = AuroraType.monoTiny.copy(color = Color.White, fontWeight = FontWeight.Bold))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("BITRATE", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                Text("%.2f Mbps".format(stats.bitsPerSecond / 1_000_000.0), style = AuroraType.monoTiny.copy(color = AuroraColors.successDark, fontWeight = FontWeight.Bold))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("FRAMES", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                Text("${stats.queuedFrameCount}", style = AuroraType.monoTiny.copy(color = Color.White, fontWeight = FontWeight.Bold))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("LATENCY", style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
                Text("${stats.roundTripMillis} ms", style = AuroraType.monoTiny.copy(
                    color = if (stats.roundTripMillis > 150) AuroraColors.errorDark else AuroraColors.successDark,
                    fontWeight = FontWeight.Bold
                ))
            }
        }
    }
}
