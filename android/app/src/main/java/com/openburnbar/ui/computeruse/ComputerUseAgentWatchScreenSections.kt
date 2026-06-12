// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AssignmentTurnedIn
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.computeruse.ComputerUseActionLogEntry
import com.openburnbar.data.computeruse.ComputerUseActionStatus
import com.openburnbar.data.computeruse.ComputerUseApprovalRequest
import com.openburnbar.data.computeruse.ComputerUseTrustMode
import com.openburnbar.data.computeruse.ComputerUseWatchState
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesConnectionRecord
import com.openburnbar.ui.components.liquidGlassSurface
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
internal fun ComputerUseAgentWatchContent(
    state: ComputerUseWatchState,
    selectedConnection: HermesConnectionRecord,
    suggestedRelay: HermesConnectionRecord?,
    callbacks: AgentWatchCallbacks,
    modifier: Modifier = Modifier,
) {
    val hasLiveMirror = state.currentFrame != null
    val hasLiveSession = hasLiveMirror || state.sessionId != null

    if (!hasLiveSession) {
        WatchPlaceholder(
            state = state,
            selectedConnection = selectedConnection,
            suggestedRelay = suggestedRelay,
            onOpenHermes = callbacks.onOpenHermes,
            onUseSuggestedRelay = callbacks.onUseSuggestedRelay,
            onOpenSettings = callbacks.onOpenSettings,
            modifier = modifier.fillMaxSize(),
        )
        return
    }

    AgentWatchLiveSession(
        state = state,
        hasLiveMirror = hasLiveMirror,
        callbacks = callbacks,
        modifier = modifier,
    )
}

@Composable
private fun AgentWatchLiveSession(
    state: ComputerUseWatchState,
    hasLiveMirror: Boolean,
    callbacks: AgentWatchCallbacks,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier =
        modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(Unit) {
                detectTapGestures(onLongPress = { callbacks.onPanic() })
            },
    ) {
        if (!hasLiveMirror) {
            DialingPlaceholder(modifier = Modifier.fillMaxSize())
        }

        Column(
            modifier =
            Modifier
                .align(Alignment.TopStart)
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusStrip(state = state, onDowngrade = callbacks.onDowngrade)
            state.deniedReason?.let { reason ->
                Text(
                    text = "Denied: $reason",
                    color = AuroraColors.blaze,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                )
            }
        }

        state.currentFrame?.cursor?.let { cursor ->
            CursorDot(
                xFraction = (cursor.x.toFloat() / 1920f).coerceIn(0f, 1f),
                yFraction = (cursor.y.toFloat() / 1080f).coerceIn(0f, 1f),
                modifier = Modifier.fillMaxSize(),
            )
        }

        Column(
            modifier =
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            TimelinePreview(entries = state.actionTimeline.takeLast(3))
            state.pendingApproval?.let { request ->
                ApprovalRow(
                    request = request,
                    onApprove = callbacks.onApprove,
                    onReject = callbacks.onReject,
                    onRejectAndHalt = callbacks.onRejectAndHalt,
                )
            }
        }
    }
}

@Composable
private fun DialingPlaceholder(modifier: Modifier = Modifier) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "Connecting to Mac mirror…",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = "Waiting for the first frame",
                color = Color.White.copy(alpha = 0.55f),
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun WatchPlaceholder(
    state: ComputerUseWatchState,
    selectedConnection: HermesConnectionRecord,
    suggestedRelay: HermesConnectionRecord?,
    onOpenHermes: () -> Unit,
    onUseSuggestedRelay: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val hasRelaySelected =
        selectedConnection.mode == HermesConnectionMode.RELAY_LINK &&
            selectedConnection.id != HermesConnectionRecord.localDefault.id
    val hasLiveSession = state.sessionId != null || state.currentFrame != null
    val isSignedIn =
        remember {
            runCatching {
                com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid?.isNotBlank() == true
            }.getOrDefault(false)
        }
    val stepIndex =
        when {
            !isSignedIn -> 1
            !hasRelaySelected -> 2
            else -> 3
        }

    Box(
        modifier = modifier.background(Color(0xFF050505)),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            modifier =
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .widthIn(max = 560.dp)
                .padding(horizontal = 20.dp, vertical = 88.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            HeroCard(phaseLabel = phaseLabel(state, hasRelaySelected, isSignedIn))
            SetupChecklist(
                model =
                SetupChecklistModel(
                    isSignedIn = isSignedIn,
                    hasRelaySelected = hasRelaySelected,
                    hasLiveSession = hasLiveSession,
                    selectedConnection = selectedConnection,
                    suggestedRelay = suggestedRelay,
                ),
                actions =
                SetupChecklistActions(
                    onOpenSettings = onOpenSettings,
                    onOpenHermes = onOpenHermes,
                    onUseSuggestedRelay = onUseSuggestedRelay,
                ),
            )
            HowItWorksCard(activeStep = stepIndex)
            CapabilityStrip()
            PermissionsFooter()
        }
    }
}

private fun phaseLabel(state: ComputerUseWatchState, hasRelaySelected: Boolean, isSignedIn: Boolean): String = when {
    state.currentFrame != null -> "LIVE"
    state.sessionId != null -> "DIALING"
    !isSignedIn -> "STANDBY"
    !hasRelaySelected -> "AWAITING RELAY"
    else -> "STANDBY"
}

@Composable
internal fun HeroCard(phaseLabel: String) {
    Surface(
        color = AuroraColors.darkBackground.copy(alpha = 0.94f),
        shape = RoundedCornerShape(20.dp),
        border =
        BorderStroke(
            1.dp,
            Brush.linearGradient(
                colors =
                listOf(
                    AuroraColors.hermesMercury.copy(alpha = 0.85f),
                    AuroraColors.hermesAureate.copy(alpha = 0.7f),
                    AuroraColors.hermesMercury.copy(alpha = 0.85f),
                ),
            ),
        ),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            HeroCardHeader(phaseLabel = phaseLabel)
            Text(
                "Let the agent drive your Mac",
                color = Color.White,
                fontSize = 24.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                "Watch every click live. Tap the mirror to grab the wheel. Three-finger long-press halts everything.",
                color = Color.White.copy(alpha = 0.72f),
                fontSize = 14.sp,
            )
            Spacer(modifier = Modifier.height(2.dp))
            HeroCardDivider()
        }
    }
}

@Composable
private fun HeroCardHeader(phaseLabel: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Filled.Computer,
            contentDescription = null,
            tint = AuroraColors.hermesMercury,
            modifier = Modifier.size(16.dp),
        )
        Text(
            "COMPUTER USE",
            color = AuroraColors.hermesMercury,
            fontWeight = FontWeight.SemiBold,
            fontSize = 10.sp,
            letterSpacing = 1.6.sp,
        )
        Spacer(modifier = Modifier.width(8.dp))
        Surface(
            color = AuroraColors.hermesAureate.copy(alpha = 0.16f),
            shape = RoundedCornerShape(50),
            border = BorderStroke(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.5f)),
        ) {
            Text(
                phaseLabel,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                color = AuroraColors.hermesAureate,
                fontWeight = FontWeight.SemiBold,
                fontSize = 9.sp,
                letterSpacing = 1.2.sp,
            )
        }
    }
}

@Composable
private fun HeroCardDivider() {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(
                Brush.linearGradient(
                    colors =
                    listOf(
                        AuroraColors.hermesMercury.copy(alpha = 0.85f),
                        AuroraColors.hermesAureate.copy(alpha = 0.7f),
                        AuroraColors.hermesMercury.copy(alpha = 0.85f),
                    ),
                ),
            ),
    )
}

private data class SetupChecklistModel(
    val isSignedIn: Boolean,
    val hasRelaySelected: Boolean,
    val hasLiveSession: Boolean,
    val selectedConnection: HermesConnectionRecord,
    val suggestedRelay: HermesConnectionRecord?,
)

private data class SetupChecklistActions(
    val onOpenSettings: () -> Unit,
    val onOpenHermes: () -> Unit,
    val onUseSuggestedRelay: () -> Unit,
)

@Composable
private fun SetupChecklist(model: SetupChecklistModel, actions: SetupChecklistActions) {
    Surface(
        color = AuroraColors.darkBackground.copy(alpha = 0.85f),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(0.5.dp, Color.White.copy(alpha = 0.12f)),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionHeader("SETUP CHECKLIST")
            ChecklistRow(
                title = "Signed in to OpenBurnBar",
                detail = if (model.isSignedIn) "Account ready." else "Sign in on this device to share encrypted control with your Mac.",
                isDone = model.isSignedIn,
                actionLabel = if (model.isSignedIn) null else "Open Settings",
                onAction = actions.onOpenSettings,
            )
            ChecklistRow(
                title = "Hermes Remote Relay selected",
                detail = relayChecklistDetail(model),
                isDone = model.hasRelaySelected,
                actionLabel = relayChecklistActionLabel(model),
                onAction = {
                    if (model.suggestedRelay != null) actions.onUseSuggestedRelay() else actions.onOpenHermes()
                },
            )
            ChecklistRow(
                title = "Live Computer Use session",
                detail = if (model.hasLiveSession) "Streaming — the mirror will appear above." else "Ask the agent on your Mac to do something. The mirror auto-opens here.",
                isDone = model.hasLiveSession,
                actionLabel = null,
                onAction = {},
            )
        }
    }
}

private fun relayChecklistDetail(model: SetupChecklistModel): String = when {
    model.hasRelaySelected -> "${model.selectedConnection.displayName} is paired."
    model.suggestedRelay != null -> "Found ${model.suggestedRelay.displayName} online — one tap to connect."
    else -> "Open Hermes, sign in on the Mac, and enable Remote Relay."
}

private fun relayChecklistActionLabel(model: SetupChecklistModel): String? = when {
    model.hasRelaySelected -> null
    model.suggestedRelay != null -> "Use ${model.suggestedRelay.displayName}"
    else -> "Open Hermes"
}

@Composable
internal fun ChecklistRow(title: String, detail: String, isDone: Boolean, actionLabel: String?, onAction: () -> Unit) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ChecklistStatusIcon(isDone = isDone)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(detail, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
        }
        actionLabel?.let { label ->
            ChecklistActionChip(label = label, onAction = onAction)
        }
    }
}

@Composable
private fun ChecklistStatusIcon(isDone: Boolean) {
    Box(
        modifier =
        Modifier
            .size(24.dp)
            .clip(CircleShape)
            .background(
                if (isDone) {
                    AuroraColors.successDark.copy(alpha = 0.18f)
                } else {
                    AuroraColors.errorDark.copy(alpha = 0.18f)
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isDone) Icons.Filled.Check else Icons.Outlined.Circle,
            contentDescription = if (isDone) "Done" else "Not done",
            tint = if (isDone) AuroraColors.successDark else AuroraColors.errorDark,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun ChecklistActionChip(label: String, onAction: () -> Unit) {
    Surface(
        color = AuroraColors.hermesAureate.copy(alpha = 0.18f),
        shape = RoundedCornerShape(50),
        border = BorderStroke(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.7f)),
        modifier =
        Modifier
            .pointerInput(label) {
                detectTapGestures(onTap = { onAction() })
            }
            .widthIn(min = 80.dp),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            color = AuroraColors.hermesAureate,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun HowItWorksCard(activeStep: Int) {
    Surface(
        color = AuroraColors.darkBackground.copy(alpha = 0.85f),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(0.5.dp, Color.White.copy(alpha = 0.12f)),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            SectionHeader("HOW IT WORKS")
            StepRow(
                ordinal = "01",
                title = "Pair a Mac in Hermes",
                detail = "Run OpenBurnBar on the Mac, sign in with the same account, and turn on Remote Relay.",
                isActive = activeStep == 1,
            )
            StepRow(
                ordinal = "02",
                title = "Pick the Mac's relay connection",
                detail = "Open the Hermes tab, tap the connection name, and choose your Mac.",
                isActive = activeStep == 2,
            )
            StepRow(
                ordinal = "03",
                title = "Start a Computer Use task",
                detail = "Ask the agent on your Mac to do something. The live mirror appears here automatically.",
                isActive = activeStep == 3,
            )
        }
    }
}

@Composable
private fun StepRow(ordinal: String, title: String, detail: String, isActive: Boolean) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Column(
            modifier = Modifier.width(40.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                ordinal,
                color = if (isActive) AuroraColors.hermesAureate else Color.White.copy(alpha = 0.5f),
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp,
            )
            Box(
                modifier =
                Modifier
                    .height(2.dp)
                    .width(20.dp)
                    .background(
                        if (isActive) {
                            AuroraColors.hermesAureate.copy(alpha = 0.9f)
                        } else {
                            Color.White.copy(alpha = 0.18f)
                        },
                    ),
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                title,
                color = if (isActive) Color.White else Color.White.copy(alpha = 0.72f),
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
            )
            Text(detail, color = Color.White.copy(alpha = 0.55f), fontSize = 12.sp)
        }
    }
}

@Composable
private fun CapabilityStrip() {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("WHAT YOU'LL GET")
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CapabilityCard(
                icon = Icons.Filled.Tv,
                title = "Live mirror",
                detail = "See what the agent sees.",
                modifier = Modifier.weight(1f),
            )
            CapabilityCard(
                icon = Icons.Filled.TouchApp,
                title = "Tap to drive",
                detail = "Take over with taps + drags.",
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CapabilityCard(
                icon = Icons.Filled.AssignmentTurnedIn,
                title = "Full audit",
                detail = "Every action is recorded.",
                modifier = Modifier.weight(1f),
            )
            CapabilityCard(
                icon = Icons.Filled.Stop,
                title = "Panic halt",
                detail = "Three-finger long-press.",
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun CapabilityCard(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String, modifier: Modifier = Modifier) {
    Surface(
        color = AuroraColors.darkBackground.copy(alpha = 0.78f),
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(0.5.dp, AuroraColors.hermesMercury.copy(alpha = 0.32f)),
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(icon, contentDescription = null, tint = AuroraColors.hermesMercury, modifier = Modifier.size(18.dp))
            Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Text(detail, color = Color.White.copy(alpha = 0.55f), fontSize = 11.sp)
        }
    }
}

@Composable
private fun PermissionsFooter() {
    Surface(
        color = AuroraColors.darkBackground.copy(alpha = 0.65f),
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(0.5.dp, Color.White.copy(alpha = 0.1f)),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Filled.GppGood, contentDescription = null, tint = AuroraColors.hermesMercury, modifier = Modifier.size(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Mac permissions live on the Mac", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                Text(
                    "Run \"Re-run Mac permissions setup\" from Settings → Computer Use on your Mac to walk the TCC wizard.",
                    color = Color.White.copy(alpha = 0.55f),
                    fontSize = 11.sp,
                )
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        color = Color.White.copy(alpha = 0.55f),
        fontWeight = FontWeight.SemiBold,
        fontSize = 10.sp,
        letterSpacing = 1.4.sp,
    )
}

@Composable
private fun StatusStrip(state: ComputerUseWatchState, onDowngrade: (ComputerUseTrustMode) -> Unit) {
    Surface(
        color = Color.Transparent,
        shape = RoundedCornerShape(18.dp),
        modifier =
        Modifier.liquidGlassSurface(
            shape = RoundedCornerShape(18.dp),
            wash = Color.Black.copy(alpha = 0.45f),
            isDark = true,
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Watching", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Text(state.trustMode.name.lowercase().replaceFirstChar { it.uppercase() }, color = AuroraColors.hermesAureate, fontSize = 12.sp)
            if (state.trustMode != ComputerUseTrustMode.MANUAL) {
                OutlinedButton(onClick = { onDowngrade(ComputerUseTrustMode.MANUAL) }) {
                    Text("Manual")
                }
            }
        }
    }
}

@Composable
private fun CursorDot(xFraction: Float, yFraction: Float, modifier: Modifier = Modifier) {
    Box(modifier = modifier.padding(18.dp)) {
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(
                    start = (xFraction * 300).dp,
                    top = (yFraction * 520).dp,
                ),
        ) {
            Box(
                modifier =
                Modifier
                    .size(14.dp)
                    .clip(CircleShape)
                    .background(AuroraColors.hermesAureate),
            )
        }
    }
}

@Composable
private fun TimelinePreview(entries: List<ComputerUseActionLogEntry>) {
    if (entries.isEmpty()) return
    Surface(
        color = Color.Transparent,
        shape = RoundedCornerShape(18.dp),
        modifier =
        Modifier.liquidGlassSurface(
            shape = RoundedCornerShape(18.dp),
            wash = Color.Black.copy(alpha = 0.5f),
            isDark = true,
        ),
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            entries.forEach { entry ->
                Text(
                    text = "${entry.entryIndex.toString().padStart(2, '0')}  ${entry.status.label()}  ${entry.summary}",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

@Composable
private fun ApprovalRow(request: ComputerUseApprovalRequest, onApprove: () -> Unit, onReject: () -> Unit, onRejectAndHalt: () -> Unit) {
    Surface(
        color = Color.Transparent,
        shape = RoundedCornerShape(20.dp),
        modifier =
        Modifier.liquidGlassSurface(
            shape = RoundedCornerShape(20.dp),
            wash = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
        ),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(request.actionSummary, fontWeight = FontWeight.SemiBold)
            Text(request.toolKind, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onApprove, colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesAureate)) {
                    Text("Approve")
                }
                OutlinedButton(onClick = onReject) {
                    Text("Reject")
                }
                Button(onClick = onRejectAndHalt, colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.blaze)) {
                    Text("Halt")
                }
            }
        }
    }
}

private fun ComputerUseActionStatus.label(): String = when (this) {
    ComputerUseActionStatus.PLANNED -> "planned"
    ComputerUseActionStatus.AWAITING_APPROVAL -> "approval"
    ComputerUseActionStatus.EXECUTING -> "running"
    ComputerUseActionStatus.COMPLETED -> "done"
    ComputerUseActionStatus.REJECTED -> "rejected"
    ComputerUseActionStatus.FAILED -> "failed"
    ComputerUseActionStatus.PANIC_HALTED -> "halted"
}
