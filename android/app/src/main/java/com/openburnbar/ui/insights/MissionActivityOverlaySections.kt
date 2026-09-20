// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import android.content.Context
import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.TextSnippet
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Handyman
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.components.liquidGlassInteractive
import com.openburnbar.ui.components.liquidGlassSurface
import com.openburnbar.ui.media.SkillRunPiPActivity
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraShadowSpec
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

private data class MissionLiveOrbGestureState(
    val orbOffset: IntOffset,
    val onDismiss: () -> Unit,
    val onOrbOffsetChange: (IntOffset) -> Unit,
    val onDraggingChange: (Boolean) -> Unit,
    val onTooltipDismiss: () -> Unit,
    val onLongPress: () -> Unit,
    val onClick: () -> Unit,
)

private data class MissionOverlayInteraction(
    val isDismissed: Boolean,
    val dismissedSkillRunKeys: Map<String, String>,
    val onDismissedChange: (Boolean) -> Unit,
    val onDismissedSkillRunKeysChange: (Map<String, String>) -> Unit,
)

private data class MissionOverlayActions(
    val onOpenDetail: () -> Unit,
    val onApprove: (String) -> Unit,
    val onReject: (String) -> Unit,
    val onPiP: (String) -> Unit,
)

@Composable
fun MissionActivityOverlay(modifier: Modifier = Modifier, viewModel: MissionActivityViewModel = viewModel()) {
    val status by viewModel.status.collectAsState()
    val context = LocalContext.current
    var showMissionDetail by remember { mutableStateOf(false) }
    var isDismissed by remember { mutableStateOf(true) }
    var dismissedSkillRunKeys by remember { mutableStateOf(emptyMap<String, String>()) }

    LaunchedEffect(Unit) { viewModel.start() }

    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
        MissionActivityOverlayBody(
            status = status,
            interaction = MissionOverlayInteraction(
                isDismissed = isDismissed,
                dismissedSkillRunKeys = dismissedSkillRunKeys,
                onDismissedChange = { isDismissed = it },
                onDismissedSkillRunKeysChange = { dismissedSkillRunKeys = it },
            ),
            actions = MissionOverlayActions(
                onOpenDetail = { showMissionDetail = true },
                onApprove = { viewModel.respondToMissionApproval(it, true) },
                onReject = { viewModel.respondToMissionApproval(it, false) },
                onPiP = { openSkillRunPiP(context, it) },
            ),
        )
    }

    if (showMissionDetail) {
        MissionDetailSheet(
            status = status,
            onApprovalResponse = { requestID, approve ->
                viewModel.respondToMissionApproval(requestID, approve)
            },
            onFloat = { mission ->
                if (mission.skillRunID != null) {
                    dismissedSkillRunKeys = dismissedSkillRunKeys - mission.id
                    isDismissed = false
                }
            },
            onPictureInPicture = { mission ->
                if (mission.skillRunID != null) {
                    openSkillRunPiP(context, mission.id)
                }
            },
            onDismiss = { showMissionDetail = false },
        )
    }
}

@Composable
private fun MissionActivityOverlayBody(status: InsightsViewModel.MissionStatus, interaction: MissionOverlayInteraction, actions: MissionOverlayActions) {
    when (val current = status) {
        InsightsViewModel.MissionStatus.Idle -> Unit
        is InsightsViewModel.MissionStatus.Tracking ->
            MissionTrackingOverlayContent(
                mission = current.mission,
                interaction = interaction,
                actions = actions,
            )
        is InsightsViewModel.MissionStatus.Failed ->
            MissionFailedOverlayContent(
                isDismissed = interaction.isDismissed,
                onDismissedChange = interaction.onDismissedChange,
                onOpenDetail = actions.onOpenDetail,
            )
        is InsightsViewModel.MissionStatus.Dispatched -> Unit
    }
}

@Composable
private fun MissionTrackingOverlayContent(mission: CLIAgentMissionSnapshot, interaction: MissionOverlayInteraction, actions: MissionOverlayActions) {
    val isDismissed = interaction.isDismissed
    val dismissedSkillRunKeys = interaction.dismissedSkillRunKeys
    LaunchedEffect(
        mission.id,
        mission.status,
        mission.events.lastOrNull()?.sequence,
        mission.events.lastOrNull()?.eventImportance,
        mission.deliveryMode,
        mission.approvalStatus,
    ) {
        if (mission.skillRunID != null &&
            dismissedSkillRunKeys[mission.id] != skillRunNotificationKey(mission) &&
            shouldAutoOpenSkillRun(mission)
        ) {
            interaction.onDismissedChange(false)
        }
    }
    if (!isDismissed) {
        when {
            mission.skillRunID != null ->
                SkillRunLiveTile(
                    mission = mission,
                    onOpen = actions.onOpenDetail,
                    onPiP = { actions.onPiP(mission.id) },
                    onDismiss = {
                        interaction.onDismissedSkillRunKeysChange(
                            dismissedSkillRunKeys + (mission.id to skillRunNotificationKey(mission)),
                        )
                        interaction.onDismissedChange(true)
                    },
                    onApprove = { actions.onApprove(mission.id) },
                    onReject = { actions.onReject(mission.id) },
                )
            mission.isTerminal ->
                MissionDoneOrb(
                    onClick = actions.onOpenDetail,
                    onDismiss = { interaction.onDismissedChange(true) },
                )
            else ->
                MissionLiveOrb(
                    mission = mission,
                    onClick = actions.onOpenDetail,
                    onDismiss = { interaction.onDismissedChange(true) },
                )
        }
    } else {
        val accent =
            if (mission.isTerminal) {
                AuroraColors.success
            } else {
                missionAccentColor(mission)
            }
        RestoreDot(accent = accent, onRestore = { interaction.onDismissedChange(false) })
    }
}

@Composable
private fun MissionFailedOverlayContent(isDismissed: Boolean, onDismissedChange: (Boolean) -> Unit, onOpenDetail: () -> Unit) {
    if (!isDismissed) {
        MissionAlertOrb(
            onClick = onOpenDetail,
            onDismiss = { onDismissedChange(true) },
        )
    } else {
        RestoreDot(
            accent = MaterialTheme.colorScheme.error,
            onRestore = { onDismissedChange(false) },
        )
    }
}

internal fun openSkillRunPiP(context: Context, missionID: String) {
    val intent =
        Intent(context, SkillRunPiPActivity::class.java)
            .putExtra(SkillRunPiPActivity.EXTRA_MISSION_ID, missionID)
            .putExtra(SkillRunPiPActivity.EXTRA_ENTER_PIP, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
}

@Composable
internal fun SkillRunLiveTile(
    mission: CLIAgentMissionSnapshot,
    onOpen: () -> Unit,
    onPiP: () -> Unit,
    onDismiss: () -> Unit,
    onApprove: () -> Unit,
    onReject: () -> Unit,
) {
    val accent = missionAccentColor(mission)
    var tileOffset by remember { mutableStateOf(IntOffset.Zero) }
    var isDragging by remember { mutableStateOf(false) }

    Surface(
        color = Color.Transparent,
        shape = RoundedCornerShape(18.dp),
        shadowElevation = 0.dp,
        modifier =
        Modifier
            .padding(AuroraSpacing.LG.dp)
            .offset { tileOffset }
            .widthIn(max = 360.dp)
            .liquidGlassSurface(
                shape = RoundedCornerShape(18.dp),
                wash = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
                shadow = AuroraShadowSpec(elevation = 14.dp, spotAlpha = 0.18f),
            )
            .border(1.dp, accent.copy(alpha = 0.72f), RoundedCornerShape(18.dp))
            .graphicsLayer {
                scaleX = if (isDragging) 0.97f else 1f
                scaleY = if (isDragging) 0.97f else 1f
                alpha = if (isDragging) 0.82f else 1f
            }
            .skillRunTileDragGesture(
                onDraggingChange = { isDragging = it },
                onDragBy = { tileOffset += it },
                onDragSettled = { tileOffset = IntOffset.Zero },
            )
            .pointerInput(Unit) {
                detectTapGestures(onTap = { onOpen() })
            },
    ) {
        SkillRunLiveTileContent(
            mission = mission,
            accent = accent,
            onPiP = onPiP,
            onDismiss = onDismiss,
            onApprove = onApprove,
            onReject = onReject,
        )
    }
}

private fun Modifier.skillRunTileDragGesture(onDraggingChange: (Boolean) -> Unit, onDragBy: (IntOffset) -> Unit, onDragSettled: () -> Unit): Modifier =
    pointerInput(Unit) {
        detectDragGestures(
            onDragStart = { onDraggingChange(true) },
            onDragEnd = {
                onDraggingChange(false)
                onDragSettled()
            },
            onDragCancel = {
                onDraggingChange(false)
                onDragSettled()
            },
        ) { change, dragAmount ->
            change.consume()
            onDragBy(IntOffset(dragAmount.x.roundToInt(), dragAmount.y.roundToInt()))
        }
    }

@Composable
private fun SkillRunLiveTileContent(
    mission: CLIAgentMissionSnapshot,
    accent: Color,
    onPiP: () -> Unit,
    onDismiss: () -> Unit,
    onApprove: () -> Unit,
    onReject: () -> Unit,
) {
    Column(
        modifier = Modifier.padding(AuroraSpacing.MD.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        SkillRunLiveTileHeader(mission = mission, onPiP = onPiP, onDismiss = onDismiss)
        Text(
            text = mission.title,
            style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text =
            mission.events.lastOrNull()?.fullMessage
                ?: mission.events.lastOrNull()?.message
                ?: mission.displayLiveSummary
                ?: mission.currentStepLabel,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
            SkillRunTilePill(mission.displayStatus.uppercase(), accent)
            SkillRunTilePill(mission.deliveryMode.displayLabel, AuroraColors.whimsy)
        }
        if (mission.isWaitingForApproval) {
            SkillRunApprovalActions(onApprove = onApprove, onReject = onReject)
        }
    }
}

@Composable
private fun SkillRunLiveTileHeader(mission: CLIAgentMissionSnapshot, onPiP: () -> Unit, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Filled.TextSnippet,
            contentDescription = null,
            tint = AuroraColors.amber,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = mission.skillRunID?.displayLabel ?: "Skill Run",
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onPiP, modifier = Modifier.size(34.dp)) {
            Icon(
                imageVector = Icons.Filled.GraphicEq,
                contentDescription = "Open Skill Run in Picture in Picture",
                tint = AuroraColors.amber,
                modifier = Modifier.size(18.dp),
            )
        }
        IconButton(onClick = onDismiss, modifier = Modifier.size(34.dp)) {
            Icon(
                imageVector = Icons.Filled.Error,
                contentDescription = "Dismiss floating Skill Run",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun SkillRunApprovalActions(onApprove: () -> Unit, onReject: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        TextButton(onClick = onApprove) {
            Text(
                text = "Approve",
                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = AuroraColors.success,
            )
        }
        TextButton(onClick = onReject) {
            Text(
                text = "Reject",
                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}

@Composable
private fun SkillRunTilePill(text: String, color: Color) {
    Text(
        text = text,
        style = AuroraType.tiny.copy(fontWeight = FontWeight.Bold),
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier =
        Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(9.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

@Composable
internal fun MissionLiveOrb(mission: CLIAgentMissionSnapshot, onClick: () -> Unit, onDismiss: () -> Unit) {
    val accent = missionAccentColor(mission)
    val state = rememberOrbState(mission)
    val isActive = !mission.isTerminal
    var showTooltip by remember { mutableStateOf(false) }
    var tooltipTask by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var orbOffset by remember { mutableStateOf(IntOffset.Zero) }
    var isDragging by remember { mutableStateOf(false) }
    val glowAlpha = missionLiveOrbGlowAlpha()

    Box(contentAlignment = Alignment.BottomEnd, modifier = Modifier.padding(AuroraSpacing.LG.dp)) {
        AnimatedVisibility(
            visible = showTooltip,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier =
            Modifier
                .align(Alignment.TopCenter)
                .offset(y = (-44).dp),
        ) {
            TooltipPill()
        }
        MissionLiveOrbSurface(
            gesture =
            MissionLiveOrbGestureState(
                orbOffset = orbOffset,
                onDismiss = onDismiss,
                onOrbOffsetChange = { orbOffset = it },
                onDraggingChange = { isDragging = it },
                onTooltipDismiss = {
                    showTooltip = false
                    tooltipTask?.cancel()
                },
                onLongPress = {
                    showTooltip = true
                    tooltipTask?.cancel()
                    tooltipTask =
                        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                            kotlinx.coroutines.delay(2500)
                            showTooltip = false
                        }
                },
                onClick = onClick,
            ),
        ) {
            MissionLiveOrbDisc(
                orbSize = 56.dp,
                accent = accent,
                glowAlpha = glowAlpha,
                isActive = isActive,
                isDragging = isDragging,
                state = state,
            )
        }
    }
}

@Composable
private fun BoxScope.MissionLiveOrbSurface(gesture: MissionLiveOrbGestureState, content: @Composable () -> Unit) {
    Surface(
        shape = CircleShape,
        color = Color.Transparent,
        shadowElevation = 0.dp,
        modifier =
        Modifier
            .offset { gesture.orbOffset }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = {
                        gesture.onDraggingChange(true)
                        gesture.onTooltipDismiss()
                    },
                    onDragEnd = {
                        gesture.onDraggingChange(false)
                        if (hypot(gesture.orbOffset.x.toFloat(), gesture.orbOffset.y.toFloat()) > 600f) {
                            gesture.onDismiss()
                        } else {
                            gesture.onOrbOffsetChange(IntOffset.Zero)
                        }
                    },
                    onDragCancel = {
                        gesture.onDraggingChange(false)
                        gesture.onOrbOffsetChange(IntOffset.Zero)
                    },
                ) { change, dragAmount ->
                    change.consume()
                    gesture.onOrbOffsetChange(
                        gesture.orbOffset + IntOffset(dragAmount.x.roundToInt(), dragAmount.y.roundToInt()),
                    )
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onLongPress = { gesture.onLongPress() }, onTap = { gesture.onClick() })
            },
    ) {
        content()
    }
}

@Composable
private fun missionLiveOrbGlowAlpha(): Float {
    val transition = rememberInfiniteTransition(label = "orb-pulse")
    return transition.animateFloat(
        initialValue = 0.20f,
        targetValue = 0.40f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(2000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "orb-glow",
    ).value
}

@Composable
private fun MissionLiveOrbDisc(
    orbSize: androidx.compose.ui.unit.Dp,
    accent: Color,
    glowAlpha: Float,
    isActive: Boolean,
    isDragging: Boolean,
    state: OrbState,
) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(orbSize)) {
        if (isActive) {
            Box(
                modifier =
                Modifier
                    .size(72.dp)
                    .background(
                        Brush.radialGradient(
                            colors = listOf(accent.copy(alpha = glowAlpha), Color.Transparent),
                        ),
                        CircleShape,
                    )
                    .blur(6.dp),
            )
        }
        Box(
            modifier =
            Modifier
                .size(orbSize)
                .liquidGlassInteractive(shape = CircleShape)
                .border(
                    width = if (isActive) 1.5.dp else 0.8.dp,
                    color =
                    if (isActive) {
                        accent.copy(alpha = 0.75f)
                    } else {
                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
                    },
                    shape = CircleShape,
                )
                .graphicsLayer {
                    scaleX = if (isDragging) 0.92f else 1f
                    scaleY = if (isDragging) 0.92f else 1f
                    alpha = if (isDragging) 0.75f else 1f
                },
        )
        MissionLiveOrbCenterContent(isActive = isActive, accent = accent, state = state)
    }
}

@Composable
private fun MissionLiveOrbCenterContent(isActive: Boolean, accent: Color, state: OrbState) {
    if (isActive && state.label != null) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(imageVector = state.icon, contentDescription = null, tint = accent, modifier = Modifier.size(18.dp))
            Text(
                text = state.label,
                style =
                AuroraType.tiny.copy(
                    fontWeight = FontWeight.Bold,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                ),
                color = accent.copy(alpha = 0.92f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    } else {
        Icon(
            imageVector = state.icon,
            contentDescription = null,
            tint = if (isActive) accent else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
internal fun MissionDoneOrb(onClick: () -> Unit, onDismiss: () -> Unit) {
    MissionTerminalOrb(
        accent = AuroraColors.success,
        icon = Icons.Filled.CheckCircle,
        onClick = onClick,
        onDismiss = onDismiss,
    )
}

@Composable
internal fun MissionAlertOrb(onClick: () -> Unit, onDismiss: () -> Unit) {
    MissionTerminalOrb(
        accent = MaterialTheme.colorScheme.error,
        icon = Icons.Filled.WarningAmber,
        onClick = onClick,
        onDismiss = onDismiss,
    )
}

@Composable
private fun MissionTerminalOrb(accent: Color, icon: ImageVector, onClick: () -> Unit, onDismiss: () -> Unit) {
    var orbOffset by remember { mutableStateOf(IntOffset.Zero) }
    var isDragging by remember { mutableStateOf(false) }

    Surface(
        shape = CircleShape,
        color = Color.Transparent,
        shadowElevation = 0.dp,
        modifier =
        Modifier
            .padding(AuroraSpacing.LG.dp)
            .offset { orbOffset }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { isDragging = true },
                    onDragEnd = {
                        isDragging = false
                        if (hypot(orbOffset.x.toFloat(), orbOffset.y.toFloat()) > 600f) {
                            onDismiss()
                        } else {
                            orbOffset = IntOffset.Zero
                        }
                    },
                    onDragCancel = {
                        isDragging = false
                        orbOffset = IntOffset.Zero
                    },
                ) { change, dragAmount ->
                    change.consume()
                    orbOffset += IntOffset(dragAmount.x.roundToInt(), dragAmount.y.roundToInt())
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onTap = { onClick() })
            },
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(56.dp)) {
            Box(
                modifier =
                Modifier
                    .size(56.dp)
                    .liquidGlassInteractive(shape = CircleShape)
                    .border(width = 1.5.dp, color = accent.copy(alpha = if (icon == Icons.Filled.CheckCircle) 0.6f else 0.75f), shape = CircleShape)
                    .graphicsLayer {
                        scaleX = if (isDragging) 0.92f else 1f
                        scaleY = if (isDragging) 0.92f else 1f
                        alpha = if (isDragging) 0.75f else 1f
                    },
            )
            Icon(imageVector = icon, contentDescription = null, tint = accent, modifier = Modifier.size(22.dp))
        }
    }
}

@Composable
private fun TooltipPill() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .liquidGlassSurface(shape = CircleShape)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.GraphicEq,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
            modifier = Modifier.size(12.dp),
        )
        Text(
            text = "Drag to move · flick to dismiss",
            style = AuroraType.tiny.copy(fontWeight = FontWeight.Medium),
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
            modifier = Modifier.padding(start = 4.dp),
        )
    }
}

@Composable
private fun RestoreDot(accent: Color, onRestore: () -> Unit) {
    val transition = rememberInfiniteTransition(label = "restore-pulse")
    val pulseAlpha by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 0.75f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(1500, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "restore-alpha",
    )

    IconButton(
        onClick = onRestore,
        modifier =
        Modifier
            .padding(AuroraSpacing.LG.dp)
            .size(24.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(12.dp)
                .background(accent.copy(alpha = pulseAlpha), CircleShape),
        )
    }
}

private data class OrbState(val icon: ImageVector, val label: String?)

@Composable
private fun rememberOrbState(mission: CLIAgentMissionSnapshot): OrbState {
    val latest = mission.events.lastOrNull()
    return when {
        mission.isTerminal -> OrbState(Icons.Filled.CheckCircle, null)
        latest == null -> OrbState(Icons.Filled.GraphicEq, null)
        latest.isError || latest.kind == "error" -> OrbState(Icons.Filled.Error, "Error")
        latest.kind == "approval_request" || latest.phase?.contains("approval") == true ->
            OrbState(Icons.Filled.Gavel, "Approve")
        latest.kind in setOf("tool_call", "tool_result") || latest.phase in setOf("tool_use", "tool_result") -> {
            val name = latest.toolName?.takeIf { it.isNotBlank() } ?: latest.title ?: "Tool"
            OrbState(toolIcon(name), name)
        }
        latest.kind in setOf("llm_response", "assistant_message", "final_answer") ->
            OrbState(Icons.AutoMirrored.Filled.TextSnippet, "LLM")
        else -> OrbState(Icons.Filled.GraphicEq, null)
    }
}

private fun toolIcon(name: String): ImageVector = when {
    name.contains("read", ignoreCase = true) -> Icons.AutoMirrored.Filled.TextSnippet
    name.contains("write", ignoreCase = true) -> Icons.Filled.Edit
    name.contains("edit", ignoreCase = true) -> Icons.Filled.Edit
    name.contains("search", ignoreCase = true) -> Icons.Filled.Search
    name.contains("grep", ignoreCase = true) -> Icons.Filled.Search
    name.contains("build", ignoreCase = true) -> Icons.Filled.Build
    name.contains("test", ignoreCase = true) -> Icons.Filled.Handyman
    else -> Icons.Filled.Build
}

internal fun missionAccentColor(mission: CLIAgentMissionSnapshot): Color {
    val latest = mission.events.lastOrNull()
    return when {
        latest?.isError == true || latest?.kind == "error" -> AuroraColors.ember
        latest?.kind == "approval_request" || latest?.phase?.contains("approval") == true -> AuroraColors.hermesAureate
        latest?.kind in setOf("tool_call", "tool_result") || latest?.phase in setOf("tool_use", "tool_result") -> AuroraColors.amber
        latest?.kind in setOf("llm_response", "assistant_message") -> AuroraColors.purple
        else -> AuroraColors.amber
    }
}
