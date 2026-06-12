// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardTab
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.CropFree
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.HighlightAlt
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.NorthWest
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.media.VideoReceivePipeline
import com.openburnbar.irohrelay.HermesRealtimeRelayMacLockState
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockState
import com.openburnbar.ui.components.auroraGlass
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraShadows
import com.openburnbar.ui.theme.AuroraType
import kotlin.math.abs
import kotlin.math.hypot
import kotlinx.coroutines.delay

@Composable
internal fun ScreenMirrorInputOverlay() {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .border(
                width = 1.dp,
                color = AuroraColors.hermesMercury.copy(alpha = 0.48f),
                shape = RoundedCornerShape(18.dp),
            ),
    )
}

@Composable
internal fun CoPilotTargetReticle(position: Offset, modifier: Modifier = Modifier) {
    val infiniteTransition = rememberInfiniteTransition(label = "reticle")
    val scale by infiniteTransition.animateFloat(
        initialValue = 0.85f,
        targetValue = 1.15f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "scale",
    )

    Canvas(
        modifier =
        modifier
            .fillMaxSize()
            .graphicsLayer {
                translationX = position.x - 24.dp.toPx()
                translationY = position.y - 24.dp.toPx()
                scaleX = scale
                scaleY = scale
            }
            .size(48.dp),
    ) {
        drawCoPilotReticleMarks()
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawCoPilotReticleMarks() {
    val center = Offset(size.width / 2f, size.height / 2f)
    val radiusOuter = 24.dp.toPx()
    val radiusInner = 14.dp.toPx()
    drawCircle(
        color = Color.Red,
        radius = radiusOuter,
        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()),
    )
    drawLine(
        color = Color.Red,
        start = Offset(center.x, center.y - radiusOuter),
        end = Offset(center.x, center.y - radiusInner),
        strokeWidth = 2.dp.toPx(),
    )
    drawLine(
        color = Color.Red,
        start = Offset(center.x, center.y + radiusInner),
        end = Offset(center.x, center.y + radiusOuter),
        strokeWidth = 2.dp.toPx(),
    )
    drawLine(
        color = Color.Red,
        start = Offset(center.x - radiusOuter, center.y),
        end = Offset(center.x - radiusInner, center.y),
        strokeWidth = 2.dp.toPx(),
    )
    drawLine(
        color = Color.Red,
        start = Offset(center.x + radiusInner, center.y),
        end = Offset(center.x + radiusOuter, center.y),
        strokeWidth = 2.dp.toPx(),
    )
    drawCircle(color = Color.Red, radius = 3.dp.toPx())
}

@Composable
internal fun ScreenMirrorTrackpadSurface(modifier: Modifier = Modifier, onMove: (Offset) -> Unit, onClick: (Int) -> Unit) {
    var touchLocation by remember { mutableStateOf<Offset?>(null) }
    var touchHistory by remember { mutableStateOf<List<Offset>>(emptyList()) }
    var lastPosition by remember { mutableStateOf<Offset?>(null) }
    var pressStartedAt by remember { mutableStateOf(0L) }
    var travelDistance by remember { mutableStateOf(0f) }

    Box(
        modifier =
        modifier
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
                trackpadPointerLoop(
                    hooks =
                    TrackpadPointerLoopHooks(
                        onMove = onMove,
                        onClick = onClick,
                        onTouchLocationChange = { touchLocation = it },
                    ),
                    mutableState =
                    TrackpadPointerMutableState(
                        readTouchHistory = { touchHistory },
                        onTouchHistoryChange = { touchHistory = it },
                        readLastPosition = { lastPosition },
                        writeLastPosition = { lastPosition = it },
                        readPressStartedAt = { pressStartedAt },
                        writePressStartedAt = { pressStartedAt = it },
                        readTravelDistance = { travelDistance },
                        writeTravelDistance = { travelDistance = it },
                    ),
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        TrackpadTouchHistoryCanvas(touchHistory = touchHistory)
        TrackpadSurfaceLabel(modifier = Modifier.align(Alignment.TopStart))
    }
}

@Composable
private fun TrackpadSurfaceLabel(modifier: Modifier = Modifier) {
    Text(
        text = "Glass Trackpad",
        modifier = modifier.padding(14.dp),
        color = Color.White.copy(alpha = 0.76f),
        style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
    )
}


@Composable
private fun TrackpadTouchHistoryCanvas(touchHistory: List<Offset>) {
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
}

@Composable
private fun rememberMirrorDockTooltip(): Pair<String?, (String) -> Unit> {
    val haptic = LocalHapticFeedback.current
    var tooltip by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(tooltip) {
        if (tooltip != null) {
            delay(2600)
            tooltip = null
        }
    }
    val showTip: (String) -> Unit = { tipText ->
        tooltip = tipText
        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
    }
    return tooltip to showTip
}

private fun mirrorToolsDockSheenBrush(): Brush =
    Brush.linearGradient(
        colors =
        listOf(
            screenShareControlGradientColors.first().copy(alpha = 0.16f),
            Color.White.copy(alpha = 0.05f),
            screenShareControlGradientColors.last().copy(alpha = 0.14f),
        ),
        start = Offset.Zero,
        end = Offset(900f, 380f),
    )

@Composable
internal fun ScreenMirrorToolsDock(modifier: Modifier = Modifier, state: MirrorDockUiState, actions: MirrorDockActions) {
    if (state.collapsed) {
        ScreenMirrorToolsDockCollapsed(modifier = modifier, state = state, actions = actions)
    } else {
        ScreenMirrorToolsDockExpanded(modifier = modifier, state = state, actions = actions)
    }
}

@Composable
private fun ScreenMirrorToolsDockCollapsed(
    modifier: Modifier,
    state: MirrorDockUiState,
    actions: MirrorDockActions,
) {
    val statsVisible = state.statsVisible
    Box(
        modifier =
        modifier
            .wrapContentWidth()
            .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.45f, shadow = AuroraShadows.large)
            .clickable { actions.onToggleCollapsed() }
            .padding(horizontal = 8.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier =
                Modifier
                    .size(12.dp)
                    .clip(CircleShape)
                    .background(Color(0xFFFF5F56))
                    .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
                    .clickable { actions.onClose() },
            )
            val dotColor = if (statsVisible) Color(0xFFFFBD2E) else Color(0xFFFFBD2E).copy(alpha = 0.6f)
            Box(
                modifier =
                Modifier
                    .size(12.dp)
                    .clip(CircleShape)
                    .background(dotColor)
                    .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
                    .clickable { actions.onToggleStats() },
            )
            Box(
                modifier =
                Modifier
                    .size(12.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF27C93F))
                    .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
                    .clickable { actions.onToggleCollapsed() },
            )
        }
    }
}

@Composable
private fun ScreenMirrorToolsDockExpanded(
    modifier: Modifier,
    state: MirrorDockUiState,
    actions: MirrorDockActions,
) {
    val (tooltip, showTip) = rememberMirrorDockTooltip()
    val dockShape = RoundedCornerShape(24.dp)
    val mercuryBrush = Brush.linearGradient(screenShareControlGradientColors)
    val dockSheen = mirrorToolsDockSheenBrush()
    Box(modifier = modifier) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.36f, shadow = AuroraShadows.large)
                .background(dockSheen, dockShape)
                .border(1.5.dp, mercuryBrush, dockShape)
                .animateContentSize()
                .pointerInput(Unit) {}
                .padding(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            MirrorDockStatusStrip(
                statsVisible = state.statsVisible,
                stats = state.stats,
                phaseLabel = state.phaseLabel,
                controlStatus = state.controlStatus,
            )
            state.openGroup?.let { group ->
                MirrorControlShelf(
                    params = mirrorControlShelfParams(group, state, actions, showTip),
                )
            }
            ScreenMirrorToolsDockPrimaryRow(
                state = state,
                actions = actions,
                showTip = showTip,
            )
        }
        tooltip?.let { tipText ->
            MirrorTooltipBubble(
                text = tipText,
                modifier = Modifier.align(Alignment.TopCenter).offset(y = (-12).dp),
            )
        }
    }
}

private fun mirrorControlShelfParams(
    group: MirrorControlGroup,
    state: MirrorDockUiState,
    actions: MirrorDockActions,
    showTip: (String) -> Unit,
): MirrorControlShelfParams =
    MirrorControlShelfParams(
        group = group,
        controlMode = state.controlMode,
        typingOpen = state.typingOpen,
        statsVisible = state.statsVisible,
        autoKeyboardOnTextFocus = state.autoKeyboardOnTextFocus,
        smartZoomMode = state.smartZoomMode,
        smartZoomAutoFollowing = state.smartZoomAutoFollowing,
        fit = state.fit,
        trayScale = state.trayScale,
        availableDisplays = state.availableDisplays,
        activeDisplayId = state.activeDisplayId,
        isZoomed = state.isZoomed,
        onSelectControlMode = { mode ->
            actions.onSelectControlMode(mode)
            actions.onSelectGroup(null)
        },
        onTrustControlDevice = {
            actions.onTrustControlDevice()
            actions.onSelectGroup(null)
        },
        onPanic = actions.onPanic,
        onCycleFit = actions.onCycleFit,
        onSelectSmartZoomMode = actions.onSelectSmartZoomMode,
        onScrollUp = actions.onScrollUp,
        onScrollDown = actions.onScrollDown,
        onToggleTyping = actions.onToggleTyping,
        onAutoKeyboardOnTextFocusChange = actions.onAutoKeyboardOnTextFocusChange,
        onPasteClipboardToMac = actions.onPasteClipboardToMac,
        onGrabClipboardFromMac = actions.onGrabClipboardFromMac,
        onEscape = actions.onEscape,
        onCommandTab = actions.onCommandTab,
        onSelectDisplay = actions.onSelectDisplay,
        onToggleStats = actions.onToggleStats,
        onReconnect = actions.onReconnect,
        onEnterPictureInPicture = actions.onEnterPictureInPicture,
        onTrayScaleChange = actions.onTrayScaleChange,
        showTooltip = showTip,
        onZoomIn = actions.onZoomIn,
        onZoomOut = actions.onZoomOut,
        onResetZoom = actions.onResetZoom,
    )

@Composable
private fun ScreenMirrorToolsDockPrimaryRow(
    state: MirrorDockUiState,
    actions: MirrorDockActions,
    showTip: (String) -> Unit,
) {
    val openGroup = state.openGroup
    val controlMode = state.controlMode
    val smartZoomMode = state.smartZoomMode
    val typingOpen = state.typingOpen
    val autoKeyboardOnTextFocus = state.autoKeyboardOnTextFocus
    val statsVisible = state.statsVisible
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.weight(1f).horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MirrorControlGroup.entries.forEach { group ->
                KeycapButton(
                    icon = mirrorGroupIcon(group, controlMode),
                    selected =
                    openGroup == group ||
                        mirrorGroupActive(
                            group,
                            controlMode,
                            smartZoomMode,
                            typingOpen,
                            autoKeyboardOnTextFocus,
                            statsVisible,
                        ),
                    label = group.title,
                    contentDescription = group.title,
                    onClick = { actions.onSelectGroup(if (openGroup == group) null else group) },
                    onLongClick = { showTip(group.hint) },
                )
            }
        }
        KeycapButton(
            icon = Icons.Filled.ExpandMore,
            selected = false,
            label = "Hide",
            contentDescription = "Collapse mirror controls",
            onClick = actions.onToggleCollapsed,
            onLongClick = { showTip("Minimize the control bar to a pill") },
        )
        KeycapButton(
            icon = Icons.Filled.Close,
            selected = false,
            label = "Close",
            contentDescription = "Close mirror",
            onClick = actions.onClose,
            onLongClick = { showTip("Close the mirror and disconnect") },
        )
    }
}

@Composable
internal fun MirrorDockStatusStrip(statsVisible: Boolean, stats: VideoReceivePipeline.Stats, phaseLabel: String, controlStatus: String?) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusChip(label = phaseLabel, scale = 1f)
        if (statsVisible) {
            CompactStatsChip(
                roundTripMillis = stats.roundTripMillis,
                bitrateMbps = (stats.bitsPerSecond / 1_000_000.0).toFloat(),
            )
        }
        controlStatus?.let { status ->
            Text(
                text = status,
                color = Color.White.copy(alpha = 0.78f),
                style = AuroraType.monoTiny.copy(fontSize = 10.sp),
                maxLines = 1,
            )
        }
    }
}

@Composable
internal fun MirrorTooltipBubble(text: String, modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .widthIn(max = 300.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xF21A1A22))
            .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 9.dp),
    ) {
        Text(
            text = text,
            color = Color.White,
            style = AuroraType.caption.copy(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
internal fun MirrorControlShelf(params: MirrorControlShelfParams) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .border(1.dp, Color.White.copy(alpha = 0.10f), RoundedCornerShape(18.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = params.group.title.uppercase(),
            color = Color.White.copy(alpha = 0.5f),
            style = AuroraType.monoTiny.copy(fontSize = 10.sp, fontWeight = FontWeight.Bold),
        )
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MirrorControlShelfGroupRow(params = params)
        }
        if (params.group == MirrorControlGroup.SCREEN) {
            MirrorControlShelfScreenExtras(params = params)
        }
    }
}

@Composable
private fun MirrorControlShelfGroupRow(params: MirrorControlShelfParams) {
    when (params.group) {
        MirrorControlGroup.MODE -> MirrorControlShelfModeGroup(params)
        MirrorControlGroup.ZOOM -> MirrorControlShelfZoomGroup(params)
        MirrorControlGroup.SCROLL -> MirrorControlShelfScrollGroup(params)
        MirrorControlGroup.KEYS -> MirrorControlShelfKeysGroup(params)
        MirrorControlGroup.SCREEN -> MirrorControlShelfScreenGroup(params)
    }
}

@Composable
private fun MirrorControlShelfModeGroup(params: MirrorControlShelfParams) {
    ScreenMirrorControlMode.entries.forEach { mode ->
        ControlModeKeycap(
            mode = mode,
            selected = params.controlMode == mode,
            onClick = { params.onSelectControlMode(mode) },
            onLongClick = { params.showTooltip(screenMirrorControlContentDescription(mode)) },
        )
    }
    KeycapButton(
        icon = Icons.Filled.VerifiedUser,
        selected = false,
        label = "Trust",
        contentDescription = "Trust this device",
        onClick = params.onTrustControlDevice,
        onLongClick = { params.showTooltip("Authorize this device to control the Mac") },
    )
    KeycapButton(
        icon = Icons.Filled.Report,
        selected = false,
        label = "Panic",
        contentDescription = "Panic, release control",
        onClick = params.onPanic,
        onLongClick = { params.showTooltip("Immediately release all input control of the Mac") },
    )
}

@Composable
private fun MirrorControlShelfZoomGroup(params: MirrorControlShelfParams) {
    KeycapButton(
        icon = Icons.Filled.ZoomIn,
        selected = false,
        label = "In",
        contentDescription = "Zoom in",
        onClick = params.onZoomIn,
        onLongClick = { params.showTooltip("Zoom into the mirrored screen") },
    )
    KeycapButton(
        icon = Icons.Filled.ZoomOut,
        selected = false,
        label = "Out",
        contentDescription = "Zoom out",
        onClick = params.onZoomOut,
        onLongClick = { params.showTooltip("Zoom back out") },
    )
    if (params.isZoomed) {
        KeycapButton(
            icon = Icons.Filled.Refresh,
            selected = false,
            label = "Reset",
            contentDescription = "Reset zoom",
            onClick = params.onResetZoom,
            onLongClick = { params.showTooltip("Return to fit-to-screen") },
        )
    }
    KeycapButton(
        icon = Icons.Filled.AspectRatio,
        selected = false,
        label = params.fit.label,
        contentDescription = "Cycle fit mode",
        onClick = params.onCycleFit,
        onLongClick = { params.showTooltip("Cycle fit: Fit, Fill, Float") },
    )
    SmartZoomKeycap(
        mode = params.smartZoomMode,
        autoFollowing = params.smartZoomAutoFollowing,
        onToggle = {
            params.onSelectSmartZoomMode(
                if (params.smartZoomMode == SmartZoomMode.OFF) SmartZoomMode.SMART else SmartZoomMode.OFF,
            )
        },
        onSelectMode = params.onSelectSmartZoomMode,
    )
}

@Composable
private fun MirrorControlShelfScrollGroup(params: MirrorControlShelfParams) {
    KeycapButton(
        icon = Icons.Filled.ExpandLess,
        selected = false,
        label = "Up",
        contentDescription = "Scroll up",
        onClick = params.onScrollUp,
        onLongClick = { params.showTooltip("Scroll the Mac up") },
    )
    KeycapButton(
        icon = Icons.Filled.ExpandMore,
        selected = false,
        label = "Down",
        contentDescription = "Scroll down",
        onClick = params.onScrollDown,
        onLongClick = { params.showTooltip("Scroll the Mac down") },
    )
}

@Composable
private fun MirrorControlShelfKeysGroup(params: MirrorControlShelfParams) {
    KeycapButton(
        icon = Icons.Filled.Keyboard,
        selected = params.typingOpen,
        label = "Type",
        contentDescription = "Type on Mac",
        onClick = params.onToggleTyping,
        onLongClick = { params.showTooltip("Open the keyboard and type on the Mac") },
    )
    KeycapButton(
        icon = Icons.Filled.TextFields,
        selected = params.autoKeyboardOnTextFocus,
        label = "Auto",
        contentDescription = "Auto keyboard on text focus",
        onClick = { params.onAutoKeyboardOnTextFocusChange(!params.autoKeyboardOnTextFocus) },
        onLongClick = { params.showTooltip("Open the keyboard automatically when the Mac focuses a text field") },
    )
    KeycapButton(
        icon = Icons.Filled.ContentPaste,
        selected = false,
        label = "To Mac",
        contentDescription = "Paste phone clipboard to Mac",
        onClick = params.onPasteClipboardToMac,
        onLongClick = { params.showTooltip("Send phone clipboard to the Mac active input") },
    )
    KeycapButton(
        icon = Icons.Filled.ContentCopy,
        selected = false,
        label = "From Mac",
        contentDescription = "Copy Mac clipboard to phone",
        onClick = params.onGrabClipboardFromMac,
        onLongClick = { params.showTooltip("Copy the Mac's clipboard to this phone") },
    )
    KeycapButton(
        icon = Icons.Filled.Close,
        selected = false,
        label = "Esc",
        contentDescription = "Escape key",
        onClick = params.onEscape,
        onLongClick = { params.showTooltip("Send the Escape key to the Mac") },
    )
    KeycapButton(
        icon = Icons.AutoMirrored.Filled.KeyboardTab,
        selected = false,
        label = "Cmd Tab",
        contentDescription = "Command Tab",
        onClick = params.onCommandTab,
        onLongClick = { params.showTooltip("Send Command-Tab to switch Mac apps") },
    )
}

@Composable
private fun MirrorControlShelfScreenGroup(params: MirrorControlShelfParams) {
    if (params.availableDisplays.size > 1) {
        val currentIndex = params.availableDisplays.indexOfFirst { it.id == params.activeDisplayId }.coerceAtLeast(0)
        val nextIndex = (currentIndex + 1) % params.availableDisplays.size
        val nextDisplay = params.availableDisplays[nextIndex]
        KeycapButton(
            icon = Icons.Filled.Tv,
            selected = false,
            label = "Display",
            contentDescription = "Switch display",
            onClick = { params.onSelectDisplay(nextDisplay.id) },
            onLongClick = { params.showTooltip("Switch which Mac display you are viewing") },
        )
    }
    KeycapButton(
        icon = Icons.Filled.Speed,
        selected = params.statsVisible,
        label = "Stats",
        contentDescription = "Toggle stream stats",
        onClick = params.onToggleStats,
        onLongClick = { params.showTooltip("Show bitrate and latency stats") },
    )
    KeycapButton(
        icon = Icons.Filled.Refresh,
        selected = false,
        label = "Reconnect",
        contentDescription = "Reconnect mirror",
        onClick = params.onReconnect,
        onLongClick = { params.showTooltip("Reconnect the mirror stream") },
    )
    KeycapButton(
        icon = Icons.Filled.Computer,
        selected = false,
        label = "PiP",
        contentDescription = "Enter Picture in Picture",
        onClick = params.onEnterPictureInPicture,
        onLongClick = { params.showTooltip("Shrink the mirror into a floating window") },
    )
}

@Composable
private fun MirrorControlShelfScreenExtras(params: MirrorControlShelfParams) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "Tray size",
            color = Color.White.copy(alpha = 0.76f),
            style = AuroraType.caption.copy(fontSize = 12.sp),
            modifier = Modifier.weight(1f),
        )
        Slider(
            value = params.trayScale,
            onValueChange = params.onTrayScaleChange,
            valueRange = 0.5f..1.2f,
            modifier = Modifier.weight(2f).height(30.dp),
        )
    }
    if (params.availableDisplays.isNotEmpty()) {
        params.availableDisplays.forEach { display ->
            val isSelected = display.id == params.activeDisplayId
            Row(
                modifier = Modifier.fillMaxWidth().clickable { params.onSelectDisplay(display.id) }.padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    display.name,
                    color = if (isSelected) AuroraColors.hermesMercury else Color.White.copy(alpha = 0.8f),
                    style =
                    AuroraType.caption.copy(
                        fontSize = 12.sp,
                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                    ),
                )
                if (isSelected) {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = "Selected",
                        tint = AuroraColors.hermesMercury,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}

@Composable
internal fun RemoteKeyboardCaptureField(modifier: Modifier = Modifier, onText: (String) -> Unit, onKey: (String) -> Unit, onDismiss: () -> Unit) {
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
        modifier =
        modifier
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

@Composable
internal fun StatusChip(label: String, scale: Float) {
    Row(
        modifier =
        Modifier
            .clip(CircleShape)
            .background(
                if (label == "Live") {
                    AuroraColors.successDark.copy(alpha = 0.22f)
                } else {
                    Color.White.copy(alpha = 0.12f)
                },
            )
            .padding(horizontal = (10 * scale).dp, vertical = (7 * scale).dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy((7 * scale).dp),
    ) {
        Box(
            modifier =
            Modifier
                .size((7 * scale).dp)
                .clip(CircleShape)
                .background(if (label == "Live") AuroraColors.successDark else AuroraColors.amber),
        )
        Text(
            text = label,
            color = Color.White,
            style =
            AuroraType.monoTiny.copy(
                fontWeight = FontWeight.Bold,
                fontSize = (9 * scale).sp,
            ),
        )
    }
}

@Composable
internal fun CompactStatsChip(roundTripMillis: Int, bitrateMbps: Float) {
    Row(
        modifier =
        Modifier
            .height(42.dp)
            .background(Color.White.copy(alpha = 0.10f), CircleShape)
            .border(0.5.dp, Color.White.copy(alpha = 0.15f), CircleShape)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "%.2f Mbps".format(bitrateMbps),
            color = Color.White.copy(alpha = 0.86f),
            style = AuroraType.monoTiny.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold),
        )
        Text(
            text = "RTT $roundTripMillis ms",
            color = Color.White.copy(alpha = 0.86f),
            style = AuroraType.monoTiny.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold),
        )
    }
}

@Composable
internal fun Modifier.mirrorKeycapChrome(selected: Boolean, shape: Shape = RoundedCornerShape(12.dp)): Modifier {
    val fill = mirrorKeycapFillBrush(selected)
    val stroke = mirrorKeycapStrokeBrush(selected)
    val keycap = mirrorKeycapShadowLayer(selected = selected, shape = shape)
    return keycap.clip(shape).background(fill, shape).border(if (selected) 1.5.dp else 1.dp, stroke, shape)
}

private fun mirrorKeycapFillBrush(selected: Boolean): Brush =
    if (selected) {
        Brush.linearGradient(
            colors =
            listOf(
                screenShareControlGradientColors.first().copy(alpha = 0.30f),
                screenShareControlGradientColors.last().copy(alpha = 0.22f),
            ),
            start = Offset.Zero,
            end = Offset(220f, 220f),
        )
    } else {
        Brush.verticalGradient(
            colors = listOf(Color.White.copy(alpha = 0.11f), Color.White.copy(alpha = 0.045f)),
        )
    }

private fun mirrorKeycapStrokeBrush(selected: Boolean): Brush =
    if (selected) {
        Brush.linearGradient(colors = screenShareControlGradientColors, start = Offset.Zero, end = Offset(160f, 160f))
    } else {
        Brush.linearGradient(
            colors = listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.055f)),
            start = Offset.Zero,
            end = Offset(120f, 120f),
        )
    }

private fun Modifier.mirrorKeycapShadowLayer(selected: Boolean, shape: Shape): Modifier =
    if (selected) {
        shadow(
            elevation = 7.dp,
            shape = shape,
            clip = false,
            spotColor = screenShareControlGradientColors.first().copy(alpha = 0.42f),
            ambientColor = screenShareControlGradientColors.last().copy(alpha = 0.22f),
        )
    } else {
        shadow(
            elevation = 2.dp,
            shape = shape,
            clip = false,
            spotColor = Color.Black.copy(alpha = 0.18f),
            ambientColor = Color.Black.copy(alpha = 0.12f),
        )
    }

@Composable
internal fun ControlModeKeycap(mode: ScreenMirrorControlMode, selected: Boolean, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    KeycapButton(
        icon = screenMirrorControlIcon(mode),
        selected = selected,
        label = screenMirrorControlLabel(mode),
        contentDescription = screenMirrorControlContentDescription(mode),
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = Modifier.width(screenMirrorControlWidth(mode)),
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun KeycapButton(
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    label: String? = null,
    contentDescription: String? = null,
    onLongClick: (() -> Unit)? = null,
) {
    val semanticModifier =
        if (contentDescription != null) {
            modifier.semantics { this.contentDescription = contentDescription }
        } else {
            modifier
        }
    val clickModifier =
        if (onLongClick != null) {
            Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick)
        } else {
            Modifier.clickable { onClick() }
        }
    Box(
        modifier =
        semanticModifier
            .height(if (label == null) 42.dp else 54.dp)
            .widthIn(min = if (label == null) 42.dp else 56.dp)
            .mirrorKeycapChrome(selected = selected)
            .then(clickModifier),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) Color.White else Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(if (label == null) 20.dp else 19.dp),
            )
            label?.let {
                Text(
                    text = it,
                    color = if (selected) Color.White else Color.White.copy(alpha = 0.76f),
                    style =
                    AuroraType.monoTiny.copy(
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
internal fun SmartZoomKeycap(
    mode: SmartZoomMode,
    autoFollowing: Boolean,
    onToggle: () -> Unit,
    onSelectMode: (SmartZoomMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val selected = mode != SmartZoomMode.OFF
    val accessibilityLabel = "Smart Zoom: ${mode.label}" + if (autoFollowing) ", auto-following" else ""
    Box(
        modifier =
        modifier
            .size(42.dp)
            .semantics { contentDescription = accessibilityLabel }
            .mirrorKeycapChrome(selected = selected)
            .combinedClickable(onClick = onToggle, onLongClick = { menuOpen = true }),
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = smartZoomModeIcon(mode),
                contentDescription = null,
                tint = if (selected) Color.White else Color.White.copy(alpha = 0.85f),
                modifier = Modifier.size(20.dp),
            )
        }
        if (autoFollowing) {
            SmartZoomAutoFollowBadge(modifier = Modifier.align(Alignment.TopEnd))
        }
        SmartZoomModeDropdownMenu(
            expanded = menuOpen,
            selectedMode = mode,
            onDismiss = { menuOpen = false },
            onSelectMode = { selectedMode ->
                onSelectMode(selectedMode)
                menuOpen = false
            },
        )
    }
}

@Composable
private fun SmartZoomAutoFollowBadge(modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .padding(2.dp)
            .clip(CircleShape)
            .background(Brush.linearGradient(colors = listOf(Color(0xFF2BCAB9), Color(0xFF8E80D8))))
            .size(8.dp),
    )
}

@Composable
private fun SmartZoomModeDropdownMenu(
    expanded: Boolean,
    selectedMode: SmartZoomMode,
    onDismiss: () -> Unit,
    onSelectMode: (SmartZoomMode) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        SmartZoomMode.entries.forEach { entry ->
            DropdownMenuItem(
                text = {
                    Text(
                        text = entry.label + if (entry == selectedMode) " ·" else "",
                        color = Color.White,
                        fontSize = 13.sp,
                    )
                },
                onClick = { onSelectMode(entry) },
                leadingIcon = {
                    Icon(
                        imageVector = smartZoomModeIcon(entry),
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(18.dp),
                    )
                },
            )
        }
    }
}

private fun smartZoomModeIcon(mode: SmartZoomMode): ImageVector =
    when (mode) {
        SmartZoomMode.OFF -> Icons.Filled.CropFree
        SmartZoomMode.SMART -> Icons.Filled.AutoAwesome
        SmartZoomMode.TEXT -> Icons.Filled.TextFields
        SmartZoomMode.WINDOW -> Icons.Filled.HighlightAlt
        SmartZoomMode.CURSOR -> Icons.Filled.NorthWest
    }

@Composable
internal fun CoPilotTargetOverlay(
    coPilotTarget: Pair<Double, Double>,
    coPilotRuntime: String,
    activeDisplayId: String?,
    onRuntimeChange: (String) -> Unit,
    onClearTarget: () -> Unit,
    onAgentContextTargetNormalized: (Double, Double, String, String, String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    var inputInstruction by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current
    LaunchedEffect(coPilotTarget) { focusRequester.requestFocus() }
    val submitInstruction = {
        val instr = inputInstruction.trim()
        if (instr.isNotEmpty()) {
            onAgentContextTargetNormalized(
                coPilotTarget.first,
                coPilotTarget.second,
                instr,
                coPilotRuntime,
                activeDisplayId,
            )
            onClearTarget()
            keyboardController?.hide()
        }
    }
    Box(
        modifier =
        modifier
            .padding(start = 16.dp, end = 16.dp, bottom = 120.dp)
            .widthIn(max = 420.dp)
            .fillMaxWidth()
            .auroraGlass(cornerRadius = 24.dp, tintAlpha = 0.38f, shadow = AuroraShadows.large)
            .padding(18.dp)
            .pointerInput(Unit) {},
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            CoPilotTargetOverlayHeader(onClearTarget = onClearTarget)
            CoPilotRuntimeSelector(selectedRuntime = coPilotRuntime, onRuntimeChange = onRuntimeChange)
            CoPilotInstructionField(
                inputInstruction = inputInstruction,
                onInputChange = { inputInstruction = it },
                focusRequester = focusRequester,
                onSubmit = submitInstruction,
            )
        }
    }
}

@Composable
private fun CoPilotTargetOverlayHeader(onClearTarget: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Canvas(modifier = Modifier.size(8.dp)) { drawCircle(Color.Red) }
            Text(
                text = "Agent Co-Pilot Target Locked",
                color = Color.White,
                style = AuroraType.body.copy(fontWeight = FontWeight.Bold),
            )
        }
        IconButton(onClick = onClearTarget, modifier = Modifier.size(24.dp)) {
            Icon(Icons.Filled.Close, contentDescription = "Clear target", tint = Color.White.copy(alpha = 0.5f))
        }
    }
}

@Composable
private fun CoPilotRuntimeSelector(selectedRuntime: String, onRuntimeChange: (String) -> Unit) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.06f), RoundedCornerShape(8.dp))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf("hermes", "pi", "codex", "claude", "openclaw").forEach { runtimeOption ->
            val isSelected = selectedRuntime == runtimeOption
            Box(
                modifier =
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (isSelected) Color.White.copy(alpha = 0.12f) else Color.Transparent)
                    .clickable { onRuntimeChange(runtimeOption) }
                    .padding(vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = runtimeOption.replaceFirstChar { it.uppercase() },
                    color = if (isSelected) Color.White else Color.White.copy(alpha = 0.6f),
                    style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
                )
            }
        }
    }
}

@Composable
private fun CoPilotInstructionField(
    inputInstruction: String,
    onInputChange: (String) -> Unit,
    focusRequester: FocusRequester,
    onSubmit: () -> Unit,
) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicTextField(
            value = inputInstruction,
            onValueChange = onInputChange,
            modifier = Modifier.weight(1f).focusRequester(focusRequester),
            textStyle = AuroraType.body.copy(color = Color.White),
            cursorBrush = SolidColor(Color.White),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { onSubmit() }),
            decorationBox = { innerTextField ->
                if (inputInstruction.isEmpty()) {
                    Text(
                        text = "Enter instruction (e.g. 'click here')",
                        color = Color.White.copy(alpha = 0.4f),
                        style = AuroraType.body,
                    )
                }
                innerTextField()
            },
        )
        IconButton(onClick = onSubmit, enabled = inputInstruction.trim().isNotEmpty()) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = "Submit instruction",
                tint = if (inputInstruction.trim().isNotEmpty()) Color.Red else Color.White.copy(alpha = 0.3f),
            )
        }
    }
}

@Composable
internal fun RemoteUnlockStatusPanel(
    state: HermesRealtimeRelayRemoteUnlockState,
    modifier: Modifier = Modifier,
    savedCredentialAvailable: Boolean,
    callbacks: RemoteUnlockCallbacks,
) {
    var password by rememberSaveable { mutableStateOf("") }
    val ready = state.capabilities.enabled && state.capabilities.allowsCredentialPaste
    val savedReady = ready && state.capabilities.allowsSavedCredentialUnlock
    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .widthIn(max = 520.dp)
            .auroraGlass(cornerRadius = 20.dp, tintAlpha = 0.38f, shadow = AuroraShadows.large)
            .padding(16.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            RemoteUnlockStatusHeader(state = state, ready = ready, callbacks = callbacks)
            Text(
                text = remoteUnlockDetailText(state, ready),
                color = Color.White.copy(alpha = 0.82f),
                style = AuroraType.caption,
            )
            if (ready) {
                RemoteUnlockSavedCredentialRow(
                    visible = savedCredentialAvailable && savedReady,
                    callbacks = callbacks,
                )
                RemoteUnlockPasswordRow(
                    password = password,
                    onPasswordChange = { password = it },
                    onSendPassword = { sent ->
                        password = ""
                        callbacks.onSendPassword(sent)
                    },
                )
                RemoteUnlockSaveCredentialButton(
                    visible = savedReady,
                    password = password,
                    onSavePassword = callbacks.onSavePassword,
                )
            }
        }
    }
}

private fun remoteUnlockTitle(state: HermesRealtimeRelayRemoteUnlockState): String =
    when (state.lockState) {
        HermesRealtimeRelayMacLockState.LOGIN_WINDOW,
        HermesRealtimeRelayMacLockState.REBOOT_LOGIN_WINDOW,
        -> "Mac Login Window"
        HermesRealtimeRelayMacLockState.SECURITY_AGENT -> "Mac Authentication Prompt"
        HermesRealtimeRelayMacLockState.SCREEN_SAVER,
        HermesRealtimeRelayMacLockState.SCREEN_LOCKED,
        -> "Mac Locked"
        HermesRealtimeRelayMacLockState.DISPLAY_SLEEPING -> "Mac Display Sleeping"
        HermesRealtimeRelayMacLockState.FAST_USER_SWITCHING -> "Fast User Switching"
        HermesRealtimeRelayMacLockState.FILEVAULT_PREBOOT -> "FileVault Preboot"
        HermesRealtimeRelayMacLockState.REMOTE_DESKTOP_CURTAIN -> "Remote Desktop Curtain"
        HermesRealtimeRelayMacLockState.UNKNOWN -> "Mac Lock State Unknown"
        HermesRealtimeRelayMacLockState.UNLOCKED -> "Mac Unlocked"
    }

private fun remoteUnlockDetailText(state: HermesRealtimeRelayRemoteUnlockState, ready: Boolean): String =
    if (ready) {
        if (state.capabilities.certificationStatus.name == "CERTIFIED") {
            "Remote Unlock is certified on this Mac. Normal Mac control is paused while locked."
        } else {
            "Remote Unlock is ready on this Mac. The first successful locked unlock records hardware certification."
        }
    } else {
        val blocker = state.capabilities.blockers.firstOrNull() ?: "remote_unlock_not_certified"
        "Remote Unlock is unavailable on this Mac: $blocker. Normal Mac control is paused while locked."
    }

@Composable
private fun RemoteUnlockStatusHeader(
    state: HermesRealtimeRelayRemoteUnlockState,
    ready: Boolean,
    callbacks: RemoteUnlockCallbacks,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Filled.VerifiedUser,
            contentDescription = null,
            tint = if (ready) AuroraColors.successDark else AuroraColors.amber,
            modifier = Modifier.size(30.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = remoteUnlockTitle(state),
                color = Color.White,
                style = AuroraType.body.copy(fontWeight = FontWeight.Bold),
            )
            Text(
                text = state.backend.name.lowercase().replace('_', ' '),
                color = Color.White.copy(alpha = 0.62f),
                style = AuroraType.caption,
            )
        }
        IconButton(onClick = callbacks.onReconnect) {
            Icon(Icons.Filled.Refresh, contentDescription = "Reconnect", tint = Color.White)
        }
        IconButton(onClick = callbacks.onClose) {
            Icon(Icons.Filled.Close, contentDescription = "Close", tint = Color.White)
        }
    }
}

@Composable
private fun RemoteUnlockSavedCredentialRow(visible: Boolean, callbacks: RemoteUnlockCallbacks) {
    if (!visible) return
    var sendingSaved by remember { mutableStateOf(false) }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Button(
            enabled = !sendingSaved,
            onClick = {
                sendingSaved = true
                callbacks.onSendSavedPassword()
            },
            colors =
            ButtonDefaults.buttonColors(
                containerColor = AuroraColors.success,
                contentColor = Color.Black,
                disabledContainerColor = AuroraColors.success.copy(alpha = 0.42f),
                disabledContentColor = Color.Black.copy(alpha = 0.55f),
            ),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.height(46.dp).weight(1f),
        ) {
            Icon(imageVector = Icons.Filled.LockOpen, contentDescription = "One-tap unlock")
            Spacer(modifier = Modifier.width(8.dp))
            Text("One-tap unlock")
        }
        IconButton(onClick = callbacks.onDeleteSavedPassword) {
            Icon(Icons.Filled.Delete, contentDescription = "Delete saved Remote Unlock credential", tint = Color.White)
        }
    }
    LaunchedEffect(sendingSaved) {
        if (sendingSaved) {
            delay(1000)
            sendingSaved = false
        }
    }
}

@Composable
private fun RemoteUnlockPasswordRow(
    password: String,
    onPasswordChange: (String) -> Unit,
    onSendPassword: (String) -> Unit,
) {
    var sending by remember { mutableStateOf(false) }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChange,
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            label = { Text("Mac password") },
            colors =
            OutlinedTextFieldDefaults.colors(
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White,
                focusedLabelColor = Color.White.copy(alpha = 0.78f),
                unfocusedLabelColor = Color.White.copy(alpha = 0.58f),
                focusedBorderColor = Color.White.copy(alpha = 0.62f),
                unfocusedBorderColor = Color.White.copy(alpha = 0.24f),
                cursorColor = Color.White,
            ),
            modifier = Modifier.weight(1f),
        )
        Button(
            enabled = password.isNotEmpty() && !sending,
            onClick = {
                val credential = password
                sending = true
                onSendPassword(credential)
            },
            colors =
            ButtonDefaults.buttonColors(
                containerColor = Color.White,
                contentColor = Color.Black,
                disabledContainerColor = Color.White.copy(alpha = 0.38f),
                disabledContentColor = Color.Black.copy(alpha = 0.55f),
            ),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.height(52.dp),
        ) {
            Icon(imageVector = Icons.Filled.LockOpen, contentDescription = "Send Mac password")
        }
    }
    LaunchedEffect(sending) {
        if (sending) {
            delay(1000)
            sending = false
        }
    }
}

@Composable
private fun RemoteUnlockSaveCredentialButton(
    visible: Boolean,
    password: String,
    onSavePassword: (String) -> Unit,
) {
    if (!visible) return
    var saving by remember { mutableStateOf(false) }
    Button(
        enabled = password.isNotEmpty() && !saving,
        onClick = {
            saving = true
            onSavePassword(password)
        },
        colors =
        ButtonDefaults.buttonColors(
            containerColor = Color.White.copy(alpha = 0.18f),
            contentColor = Color.White,
            disabledContainerColor = Color.White.copy(alpha = 0.08f),
            disabledContentColor = Color.White.copy(alpha = 0.42f),
        ),
        shape = RoundedCornerShape(14.dp),
        modifier = Modifier.fillMaxWidth().height(44.dp),
    ) {
        Icon(imageVector = Icons.Filled.Key, contentDescription = "Save for one-tap unlock")
        Spacer(modifier = Modifier.width(8.dp))
        Text("Save for one-tap unlock")
    }
    LaunchedEffect(saving) {
        if (saving) {
            delay(1000)
            saving = false
        }
    }
}

@Composable
internal fun FrostedGlassStatusPanel(message: String, modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .width(280.dp)
            .auroraGlass(cornerRadius = 20.dp, tintAlpha = 0.35f, shadow = AuroraShadows.large)
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val isLoading = message.contains("Preparing") || message.contains("Waiting")
            if (isLoading) {
                // Beautiful rotating golden loader ring
                val infiniteTransition = rememberInfiniteTransition(label = "loader")
                val rotation by infiniteTransition.animateFloat(
                    initialValue = 0f,
                    targetValue = 360f,
                    animationSpec =
                    infiniteRepeatable(
                        animation = tween(1000, easing = LinearEasing),
                        repeatMode = RepeatMode.Restart,
                    ),
                    label = "rotation",
                )
                Canvas(modifier = Modifier.size(36.dp).graphicsLayer { rotationZ = rotation }) {
                    drawArc(
                        color = AuroraColors.amber,
                        startAngle = 0f,
                        sweepAngle = 270f,
                        useCenter = false,
                        style =
                        androidx.compose.ui.graphics.drawscope.Stroke(
                            width = 3.dp.toPx(),
                            cap = androidx.compose.ui.graphics.StrokeCap.Round,
                        ),
                    )
                }
            } else {
                // Connection/stopped icon
                Icon(
                    imageVector = Icons.Filled.Computer,
                    contentDescription = null,
                    tint = if (message.contains("unavailable")) AuroraColors.errorDark else AuroraColors.hermesMercury,
                    modifier = Modifier.size(36.dp),
                )
            }
            Text(
                text = message,
                color = Color.White,
                style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
internal fun DiagnosticStatsHud(stats: VideoReceivePipeline.Stats, modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .width(200.dp)
            .auroraGlass(cornerRadius = 12.dp, tintAlpha = 0.35f, shadow = AuroraShadows.subtle)
            .padding(12.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                text = "MERCURY STREAM STATS",
                color = AuroraColors.hermesMercury,
                style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold, letterSpacing = 1.sp),
            )
            Spacer(
                modifier = Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.15f)),
            )
            DiagnosticStatRow(label = "RESOLUTION", value = "${stats.widthPx}×${stats.heightPx}")
            DiagnosticStatRow(label = "CODEC", value = stats.codecName.uppercase())
            DiagnosticStatRow(
                label = "BITRATE",
                value = "%.2f Mbps".format(stats.bitsPerSecond / 1_000_000.0),
                valueColor = AuroraColors.successDark,
            )
            DiagnosticStatRow(label = "FRAMES", value = "${stats.queuedFrameCount}")
            DiagnosticStatRow(
                label = "LATENCY",
                value = "${stats.roundTripMillis} ms",
                valueColor = if (stats.roundTripMillis > 150) AuroraColors.errorDark else AuroraColors.successDark,
            )
        }
    }
}

@Composable
private fun DiagnosticStatRow(label: String, value: String, valueColor: Color = Color.White) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = AuroraType.monoTiny.copy(color = Color.White.copy(0.4f)))
        Text(value, style = AuroraType.monoTiny.copy(color = valueColor, fontWeight = FontWeight.Bold))
    }
}

internal data class TrackpadPointerLoopHooks(
    val onMove: (Offset) -> Unit,
    val onClick: (Int) -> Unit,
    val onTouchLocationChange: (Offset?) -> Unit,
)

internal data class TrackpadPointerMutableState(
    val readTouchHistory: () -> List<Offset>,
    val onTouchHistoryChange: (List<Offset>) -> Unit,
    val readLastPosition: () -> Offset?,
    val writeLastPosition: (Offset?) -> Unit,
    val readPressStartedAt: () -> Long,
    val writePressStartedAt: (Long) -> Unit,
    val readTravelDistance: () -> Float,
    val writeTravelDistance: (Float) -> Unit,
)

private suspend fun PointerInputScope.trackpadPointerLoop(
    hooks: TrackpadPointerLoopHooks,
    mutableState: TrackpadPointerMutableState,
) {
    awaitPointerEventScope {
        while (true) {
            val event = awaitPointerEvent()
            val down = event.changes.firstOrNull { it.pressed && !it.previousPressed }
            if (down != null) {
                event.changes.forEach { it.consume() }
                mutableState.writePressStartedAt(System.currentTimeMillis())
                mutableState.writeTravelDistance(0f)
                mutableState.writeLastPosition(down.position)
                hooks.onTouchLocationChange(down.position)
                mutableState.onTouchHistoryChange(listOf(down.position))
            }

            val move = event.changes.firstOrNull { it.pressed && it.previousPressed }
            if (move != null) {
                event.changes.forEach { it.consume() }
                val last = mutableState.readLastPosition()
                val current = move.position
                if (last != null) {
                    val delta = current - last
                    if (abs(delta.x) > 0.5f || abs(delta.y) > 0.5f) {
                        hooks.onMove(delta)
                        mutableState.writeTravelDistance(
                            mutableState.readTravelDistance() + hypot(delta.x, delta.y),
                        )
                    }
                }
                mutableState.writeLastPosition(current)
                hooks.onTouchLocationChange(current)
                mutableState.onTouchHistoryChange((mutableState.readTouchHistory() + current).takeLast(4))
            }

            val up = event.changes.firstOrNull { !it.pressed && it.previousPressed }
            if (up != null) {
                event.changes.forEach { it.consume() }
                ScreenMirrorInputPolicy.trackpadClickMouseButton(
                    heldMillis = System.currentTimeMillis() - mutableState.readPressStartedAt(),
                    travelDistancePx = mutableState.readTravelDistance(),
                )?.let(hooks.onClick)
                hooks.onTouchLocationChange(null)
                mutableState.onTouchHistoryChange(emptyList())
                mutableState.writeLastPosition(null)
                mutableState.writeTravelDistance(0f)
            }
        }
    }
}
