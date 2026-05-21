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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.text.font.FontWeight
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
    onClose: () -> Unit = {},
    onEnterPictureInPicture: () -> Unit = {},
    onReconnect: () -> Unit = {},
    onTapNormalized: (Double, Double) -> Unit = { _, _ -> },
    onDragStartNormalized: (Double, Double) -> Unit = { _, _ -> },
    onDragMoveNormalized: (Double, Double) -> Unit = { _, _ -> },
    onDragEndNormalized: (Double, Double) -> Unit = { _, _ -> },
    onScrollNormalized: (Double) -> Unit = {},
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
    var typeDraft by rememberSaveable { mutableStateOf("") }
    var tapCount by remember { mutableStateOf(0) }
    var lastTapAt by remember { mutableStateOf(0L) }
    var dragActive by remember { mutableStateOf(false) }
    var lastDragNormalized by remember { mutableStateOf<Pair<Double, Double>?>(null) }
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
    val streamIsStale = stats.lastFrameAtMillis > 0 &&
        nowMillis - stats.lastFrameAtMillis > STALE_STREAM_MILLIS
    val statusText = when (val currentPhase = phase) {
        VideoReceivePipeline.Phase.Idle -> "Preparing decoder..."
        is VideoReceivePipeline.Phase.Running ->
            when {
                stats.queuedFrameCount == 0L -> "Waiting for Mac video..."
                streamIsStale -> "Mac video stalled. Tap Retry."
                else -> null
            }
        is VideoReceivePipeline.Phase.Failed -> "Decoder unavailable: ${currentPhase.reason}"
        VideoReceivePipeline.Phase.Stopped -> "Screen share stopped"
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(controlMode, fit, aspect) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val down = event.changes.firstOrNull { it.pressed && !it.previousPressed }
                        if (down != null) {
                            val now = System.currentTimeMillis()
                            if (now - lastTapAt > 600) tapCount = 0
                            lastTapAt = now
                            tapCount += 1
                            if (tapCount >= 3) {
                                statsVisible = !statsVisible
                                tapCount = 0
                            }
                            if (controlMode == ScreenMirrorControlMode.DRAG) {
                                mirrorNormalizedPoint(down.position, size, fit, aspect)?.let { point ->
                                    dragActive = true
                                    lastDragNormalized = point
                                    onDragStartNormalized(point.first, point.second)
                                }
                            }
                        }

                        val move = event.changes.firstOrNull { it.pressed && it.previousPressed }
                        if (move != null && dragActive && controlMode == ScreenMirrorControlMode.DRAG) {
                            mirrorNormalizedPoint(move.position, size, fit, aspect)?.let { point ->
                                lastDragNormalized = point
                                onDragMoveNormalized(point.first, point.second)
                            }
                        }

                        val up = event.changes.firstOrNull { !it.pressed && it.previousPressed }
                        if (up != null) {
                            when (controlMode) {
                                ScreenMirrorControlMode.TOUCH -> {
                                    mirrorNormalizedPoint(up.position, size, fit, aspect)?.let { point ->
                                        onTapNormalized(point.first, point.second)
                                    }
                                }
                                ScreenMirrorControlMode.DRAG -> {
                                    val point = mirrorNormalizedPoint(up.position, size, fit, aspect)
                                        ?: lastDragNormalized
                                    if (dragActive && point != null) {
                                        onDragEndNormalized(point.first, point.second)
                                    }
                                    dragActive = false
                                    lastDragNormalized = null
                                }
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
            statsVisible = statsVisible,
            phaseLabel = when (phase) {
                VideoReceivePipeline.Phase.Idle -> "Preparing"
                is VideoReceivePipeline.Phase.Running -> when {
                    stats.queuedFrameCount == 0L -> "Waiting"
                    streamIsStale -> "Stalled"
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
}

private const val STALE_STREAM_MILLIS = 3_500L

private enum class ScreenMirrorFit {
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

private enum class ScreenMirrorControlMode {
    VIEW,
    TOUCH,
    DRAG;

    fun next(): ScreenMirrorControlMode = when (this) {
        VIEW -> TOUCH
        TOUCH -> DRAG
        DRAG -> VIEW
    }

    val label: String
        get() = when (this) {
            VIEW -> "View"
            TOUCH -> "Touch"
            DRAG -> "Drag"
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

private fun mirrorNormalizedPoint(
    position: Offset,
    rootSize: IntSize,
    fit: ScreenMirrorFit,
    aspect: Float,
): Pair<Double, Double>? {
    if (rootSize.width <= 0 || rootSize.height <= 0 || aspect <= 0f) return null
    val rootWidth = rootSize.width.toFloat()
    val rootHeight = rootSize.height.toFloat()
    val surfaceWidth: Float
    val surfaceHeight: Float
    val surfaceLeft: Float
    val surfaceTop: Float

    when (fit) {
        ScreenMirrorFit.FILL -> {
            surfaceWidth = rootWidth
            surfaceHeight = rootHeight
            surfaceLeft = 0f
            surfaceTop = 0f
        }
        ScreenMirrorFit.FIT -> {
            surfaceWidth = rootWidth
            surfaceHeight = rootWidth / aspect
            surfaceLeft = 0f
            surfaceTop = (rootHeight - surfaceHeight) / 2f
        }
        ScreenMirrorFit.FLOAT -> {
            surfaceWidth = rootWidth * 0.92f
            surfaceHeight = surfaceWidth / aspect
            surfaceLeft = (rootWidth - surfaceWidth) / 2f
            surfaceTop = (rootHeight - surfaceHeight) / 2f
        }
    }

    val localX = position.x - surfaceLeft
    val localY = position.y - surfaceTop
    if (localX < 0f || localY < 0f || localX > surfaceWidth || localY > surfaceHeight) return null
    return Pair(
        (localX / surfaceWidth).coerceIn(0f, 1f).toDouble(),
        (localY / surfaceHeight).coerceIn(0f, 1f).toDouble(),
    )
}

@Composable
private fun ScreenMirrorToolsDock(
    modifier: Modifier = Modifier,
    collapsed: Boolean,
    customizeOpen: Boolean,
    fit: ScreenMirrorFit,
    controlMode: ScreenMirrorControlMode,
    statsVisible: Boolean,
    phaseLabel: String,
    typeDraft: String,
    onToggleCollapsed: () -> Unit,
    onToggleCustomize: () -> Unit,
    onToggleStats: () -> Unit,
    onCycleFit: () -> Unit,
    onCycleControlMode: () -> Unit,
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
                MirrorToolButton(Icons.Filled.Computer, "PiP", onEnterPictureInPicture)
                MirrorToolButton(Icons.Filled.Refresh, "Retry", onReconnect)
                MirrorToolButton(Icons.Filled.Settings, "Tune", onToggleCustomize)
                MirrorToolButton(Icons.Filled.Close, "Close", onClose)
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
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        TextField(
                            value = typeDraft,
                            onValueChange = { onTypeDraftChange(it.take(512)) },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            textStyle = AuroraType.caption.copy(color = Color.White),
                            placeholder = {
                                Text("Type to Mac", style = AuroraType.caption, color = Color.White.copy(alpha = 0.48f))
                            },
                        )
                        MirrorToolTextButton("Send", onSendText)
                    }
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
