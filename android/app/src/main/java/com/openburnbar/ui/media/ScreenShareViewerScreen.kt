package com.openburnbar.ui.media

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
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
    onClose: () -> Unit = {},
    onEnterPictureInPicture: () -> Unit = {},
    onReconnect: () -> Unit = {},
    onTapNormalized: (Double, Double, Int) -> Unit = { _, _, _ -> },
    onScrollDragNormalized: (Double, Double, Double, Double) -> Unit = { _, _, _, _ -> },
    onScrollNormalized: (Double) -> Unit = {},
    onPointerMove: (Double, Double) -> Unit = { _, _ -> },
    onPointerClick: (Int) -> Unit = {},
    onTypeText: (String) -> Unit = {},
    onShortcut: (String, List<String>) -> Unit = { _, _ -> },
    onPanic: () -> Unit = {},
    controlStatus: String? = null,
    onTrustControlDevice: () -> Unit = {},
) {
    var statsVisible by remember { mutableStateOf(false) }
    var toolsCollapsed by rememberSaveable { mutableStateOf(false) }
    var customizeOpen by rememberSaveable { mutableStateOf(false) }
    var fitName by rememberSaveable { mutableStateOf(ScreenMirrorFit.FIT.name) }
    var controlModeName by rememberSaveable { mutableStateOf(ScreenMirrorControlMode.VIEW.name) }
    var typingOpen by rememberSaveable { mutableStateOf(false) }
    var typeDraft by rememberSaveable { mutableStateOf("") }
    var tapCount by remember { mutableStateOf(0) }
    var lastTapAt by remember { mutableStateOf(0L) }
    var dragActive by remember { mutableStateOf(false) }
    var dragStartNormalized by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    var pressStartedAt by remember { mutableStateOf(0L) }
    var cursorPoint by remember { mutableStateOf<Offset?>(null) }
    var rootSize by remember { mutableStateOf(IntSize.Zero) }
    var nowMillis by remember { mutableStateOf(System.currentTimeMillis()) }
    val stats by pipeline.stats.collectAsState()
    val phase by pipeline.phase.collectAsState()
    val coroutineScope = rememberCoroutineScope()
    val fit = ScreenMirrorFit.entries.firstOrNull { it.name == fitName } ?: ScreenMirrorFit.FIT
    val controlMode = ScreenMirrorControlMode.entries.firstOrNull { it.name == controlModeName }
        ?: ScreenMirrorControlMode.VIEW
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

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .onSizeChanged { rootSize = it }
            .pointerInput(controlMode, fit, aspect) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val down = event.changes.firstOrNull { it.pressed && !it.previousPressed }
                        if (down != null) {
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
                                ScreenMirrorInputPolicy.normalizedPoint(down.position, size, fit, aspect)?.let { point ->
                                    dragActive = true
                                    dragStartNormalized = point
                                }
                            }
                        }

                        val move = event.changes.firstOrNull { it.pressed && it.previousPressed }
                        if (move != null && controlMode == ScreenMirrorControlMode.TOUCH) {
                            ScreenMirrorInputPolicy.clampedCursorPoint(move.position, size, fit, aspect)?.let { point ->
                                cursorPoint = point
                            }
                        }

                        val up = event.changes.firstOrNull { !it.pressed && it.previousPressed }
                        if (up != null) {
                            when (controlMode) {
                                ScreenMirrorControlMode.TOUCH -> {
                                    ScreenMirrorInputPolicy.normalizedPoint(up.position, size, fit, aspect)?.let { point ->
                                        cursorPoint = ScreenMirrorInputPolicy.clampedCursorPoint(up.position, size, fit, aspect)
                                        onTapNormalized(
                                            point.first,
                                            point.second,
                                            ScreenMirrorInputPolicy.controlClickMouseButton(
                                                heldMillis = System.currentTimeMillis() - pressStartedAt
                                            ),
                                        )
                                    }
                                }
                                ScreenMirrorControlMode.SCROLL -> {
                                    val start = dragStartNormalized
                                    val end = ScreenMirrorInputPolicy.normalizedPoint(up.position, size, fit, aspect)
                                    if (dragActive && start != null && end != null) {
                                        onScrollDragNormalized(start.first, start.second, end.first, end.second)
                                    }
                                    dragActive = false
                                    dragStartNormalized = null
                                }
                                ScreenMirrorControlMode.TRACKPAD,
                                ScreenMirrorControlMode.VIEW -> Unit
                            }
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        val surfaceModifier = Modifier
            .screenMirrorSurface(fit = fit, aspect = aspect)
            .align(Alignment.Center)

        Box(modifier = surfaceModifier) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    SurfaceView(ctx).apply {
                        holder.addCallback(SurfaceCallback(pipeline = pipeline, scope = coroutineScope))
                    }
                },
            )
            if (controlMode != ScreenMirrorControlMode.VIEW) {
                ScreenMirrorInputOverlay()
            }
        }

        if (controlMode != ScreenMirrorControlMode.VIEW) {
            val visibleCursor = cursorPoint ?: ScreenMirrorInputPolicy.initialCursorPoint(rootSize, fit, aspect)
            visibleCursor?.let {
                ScreenMirrorCursorOverlay(point = it)
            }
        }

        if (controlMode == ScreenMirrorControlMode.TRACKPAD) {
            ScreenMirrorTrackpadSurface(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 18.dp, bottom = 138.dp),
                onMove = { delta ->
                    cursorPoint = ScreenMirrorInputPolicy.movedCursorPoint(cursorPoint, delta, rootSize, fit, aspect)
                    onPointerMove(delta.x.toDouble(), delta.y.toDouble())
                },
                onClick = onPointerClick,
            )
        }

        // Frosted-glass loading/stopped panel with custom rotating golden loader
        statusText?.let { message ->
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
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

        // Highly polished diagnostic developer HUD stats overlay
        if (statsVisible) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(16.dp)
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

        ScreenMirrorToolsDock(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 14.dp, vertical = 18.dp),
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
            onToggleCollapsed = { toolsCollapsed = !toolsCollapsed },
            onToggleCustomize = { customizeOpen = !customizeOpen },
            onToggleStats = { statsVisible = !statsVisible },
            onCycleFit = { fitName = fit.next().name },
            onCycleControlMode = { controlModeName = controlMode.next().name },
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
            typeDraft = typeDraft,
            onTypeDraftChange = { typeDraft = it },
            onSendText = {
                val trimmed = typeDraft.take(512)
                if (trimmed.isNotBlank()) {
                    onTypeText(trimmed)
                    typeDraft = ""
                }
            },
            onScrollUp = { onScrollNormalized(-0.16) },
            onScrollDown = { onScrollNormalized(0.16) },
            onEscape = { onShortcut("escape", emptyList()) },
            onCommandTab = { onShortcut("tab", listOf("command")) },
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
    SCROLL;

    fun next(): ScreenMirrorControlMode = when (this) {
        VIEW -> TOUCH
        TOUCH -> TRACKPAD
        TRACKPAD -> SCROLL
        SCROLL -> VIEW
    }

    val label: String
        get() = when (this) {
            VIEW -> "View"
            TOUCH -> "Touch"
            TRACKPAD -> "Trackpad"
            SCROLL -> "Scroll"
        }
}

private fun Modifier.screenMirrorSurface(fit: ScreenMirrorFit, aspect: Float): Modifier = when (fit) {
    ScreenMirrorFit.FIT -> this
        .fillMaxWidth()
        .aspectRatio(aspect)
    ScreenMirrorFit.FILL -> this.fillMaxSize()
    ScreenMirrorFit.FLOAT -> this
        .fillMaxWidth(0.92f)
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
private fun ScreenMirrorCursorOverlay(point: Offset) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val outer = 13.dp.toPx()
        val inner = 4.dp.toPx()
        val strokeWidth = 1.5.dp.toPx()
        drawCircle(
            color = AuroraColors.hermesMercury.copy(alpha = 0.72f),
            radius = outer,
            center = point,
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = strokeWidth),
        )
        drawCircle(
            color = Color.White,
            radius = inner,
            center = point,
        )
        val arrow = Path().apply {
            moveTo(point.x + 7.dp.toPx(), point.y + 8.dp.toPx())
            lineTo(point.x + 17.dp.toPx(), point.y + 26.dp.toPx())
            lineTo(point.x + 11.dp.toPx(), point.y + 25.dp.toPx())
            lineTo(point.x + 7.dp.toPx(), point.y + 35.dp.toPx())
            lineTo(point.x + 3.dp.toPx(), point.y + 33.dp.toPx())
            lineTo(point.x + 7.dp.toPx(), point.y + 24.dp.toPx())
            lineTo(point.x + 2.dp.toPx(), point.y + 28.dp.toPx())
            close()
        }
        drawPath(
            path = arrow,
            color = Color.White.copy(alpha = 0.92f),
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
                            pressStartedAt = System.currentTimeMillis()
                            travelDistance = 0f
                            lastPosition = down.position
                            touchLocation = down.position
                            touchHistory = listOf(down.position)
                        }

                        val move = event.changes.firstOrNull { it.pressed && it.previousPressed }
                        if (move != null) {
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
                width = rootWidth
                height = rootWidth / aspect
                left = 0f
                top = (rootHeight - height) / 2f
            }
            ScreenMirrorFit.FLOAT -> {
                width = rootWidth * 0.92f
                height = width / aspect
                left = (rootWidth - width) / 2f
                top = (rootHeight - height) / 2f
            }
        }

        return ScreenMirrorSurfaceBounds(left = left, top = top, width = width, height = height)
    }

    fun normalizedPoint(
        position: Offset,
        rootSize: IntSize,
        fit: ScreenMirrorFit,
        aspect: Float,
    ): Pair<Double, Double>? {
        val bounds = surfaceBounds(rootSize, fit, aspect) ?: return null
        val localX = position.x - bounds.left
        val localY = position.y - bounds.top
        if (localX < 0f || localY < 0f || localX > bounds.width || localY > bounds.height) {
            return null
        }
        return Pair(
            (localX / bounds.width).coerceIn(0f, 1f).toDouble(),
            (localY / bounds.height).coerceIn(0f, 1f).toDouble(),
        )
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
private fun ScreenMirrorToolsDock(
    modifier: Modifier = Modifier,
    collapsed: Boolean,
    customizeOpen: Boolean,
    fit: ScreenMirrorFit,
    controlMode: ScreenMirrorControlMode,
    typingOpen: Boolean,
    statsVisible: Boolean,
    phaseLabel: String,
    typeDraft: String,
    onToggleCollapsed: () -> Unit,
    onToggleCustomize: () -> Unit,
    onToggleStats: () -> Unit,
    onCycleFit: () -> Unit,
    onCycleControlMode: () -> Unit,
    onSelectControlMode: (ScreenMirrorControlMode) -> Unit,
    onToggleTyping: () -> Unit,
    onTypeDraftChange: (String) -> Unit,
    onSendText: () -> Unit,
    onScrollUp: () -> Unit,
    onScrollDown: () -> Unit,
    onEscape: () -> Unit,
    onCommandTab: () -> Unit,
    onPanic: () -> Unit,
    controlStatus: String?,
    onTrustControlDevice: () -> Unit,
    onReconnect: () -> Unit,
    onEnterPictureInPicture: () -> Unit,
    onClose: () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .auroraGlass(cornerRadius = 18.dp, tintAlpha = 0.36f, shadow = AuroraShadows.large)
            .animateContentSize()
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusChip(phaseLabel)
            Spacer(modifier = Modifier.weight(1f))
            MirrorToolButton(
                icon = if (collapsed) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                label = if (collapsed) "Expand" else "Collapse",
                onClick = onToggleCollapsed,
            )
        }

        if (!collapsed) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                MirrorToolButton(Icons.Filled.PanTool, controlMode.label, onCycleControlMode)
                MirrorToolTextButton(fit.label, onCycleFit)
                MirrorToolTextButton("Type", onToggleTyping)
                MirrorToolButton(Icons.Filled.Computer, "PiP", onEnterPictureInPicture)
                MirrorToolButton(Icons.Filled.Refresh, "Retry", onReconnect)
                MirrorToolButton(Icons.Filled.Settings, "Tune", onToggleCustomize)
                MirrorToolButton(Icons.Filled.Close, "Close", onClose)
            }
            MirrorModePicker(
                controlMode = controlMode,
                onSelect = onSelectControlMode,
            )
            if (typingOpen) {
                TypingControlRow(
                    typeDraft = typeDraft,
                    onTypeDraftChange = onTypeDraftChange,
                    onSendText = onSendText,
                    onClose = onToggleTyping,
                )
            }
            if (customizeOpen) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    DockToggleRow(
                        label = "Stream stats",
                        checked = statsVisible,
                        onCheckedChange = { onToggleStats() },
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        MirrorToolTextButton("Trust", onTrustControlDevice)
                        MirrorToolTextButton("Up", onScrollUp)
                        MirrorToolTextButton("Down", onScrollDown)
                        MirrorToolTextButton("Esc", onEscape)
                        MirrorToolTextButton("CmdTab", onCommandTab)
                    }
                    MirrorToolTextButton("Panic", onPanic)
                    DockInfoRow("Fit mode", fit.label)
                    DockInfoRow("Input mode", controlMode.label)
                    controlStatus?.let { DockInfoRow("Mac control", it) }
                    DockInfoRow("Tools", "Collapsible + signed")
                }
            }
        }
    }
}

@Composable
private fun MirrorModePicker(
    controlMode: ScreenMirrorControlMode,
    onSelect: (ScreenMirrorControlMode) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
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
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (selected) AuroraColors.hermesMercury.copy(alpha = 0.28f) else Color.White.copy(alpha = 0.08f))
                    .border(
                        width = 1.dp,
                        color = if (selected) AuroraColors.hermesMercury.copy(alpha = 0.62f) else Color.White.copy(alpha = 0.10f),
                        shape = RoundedCornerShape(10.dp),
                    )
                    .clickable { onSelect(mode) }
                    .padding(vertical = 9.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = mode.label,
                    color = Color.White.copy(alpha = if (selected) 0.98f else 0.68f),
                    style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun TypingControlRow(
    typeDraft: String,
    onTypeDraftChange: (String) -> Unit,
    onSendText: () -> Unit,
    onClose: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current

    LaunchedEffect(Unit) {
        listOf(80L, 220L, 420L).forEach { delayMillis ->
            delay(delayMillis)
            focusRequester.requestFocus()
            keyboardController?.show()
        }
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TextField(
            value = typeDraft,
            onValueChange = { onTypeDraftChange(it.take(512)) },
            modifier = Modifier
                .weight(1f)
                .focusRequester(focusRequester),
            singleLine = true,
            textStyle = AuroraType.caption.copy(color = Color.White),
            placeholder = {
                Text("Type to Mac", style = AuroraType.caption, color = Color.White.copy(alpha = 0.48f))
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { onSendText() }),
        )
        MirrorToolTextButton("Send", onSendText)
        MirrorToolTextButton("Hide", onClose)
    }
}

@Composable
private fun StatusChip(label: String) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(
                if (label == "Live") AuroraColors.successDark.copy(alpha = 0.22f)
                else Color.White.copy(alpha = 0.12f)
            )
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            modifier = Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(if (label == "Live") AuroraColors.successDark else AuroraColors.amber)
        )
        Text(
            text = label,
            color = Color.White,
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
        )
    }
}

@Composable
private fun MirrorToolButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        IconButton(
            onClick = onClick,
            modifier = Modifier
                .size(42.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.10f))
        ) {
            Icon(icon, contentDescription = label, tint = Color.White)
        }
        Text(label, color = Color.White.copy(alpha = 0.68f), style = AuroraType.monoTiny)
    }
}

@Composable
private fun MirrorToolTextButton(label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        IconButton(
            onClick = onClick,
            modifier = Modifier
                .size(42.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.10f))
        ) {
            Text(label.take(1), color = Color.White, fontWeight = FontWeight.Bold)
        }
        Text(label, color = Color.White.copy(alpha = 0.68f), style = AuroraType.monoTiny)
    }
}

@Composable
private fun DockToggleRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, color = Color.White.copy(alpha = 0.76f), style = AuroraType.caption)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun DockInfoRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, color = Color.White.copy(alpha = 0.56f), style = AuroraType.monoTiny)
        Text(value, color = Color.White, style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold))
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
