package com.openburnbar.ui.insights

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.with
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Gavel
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Handyman
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.TextSnippet
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionEvent
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

class MissionActivityViewModel : ViewModel() {
    private val auth = FirebaseAuth.getInstance()
    private val firestore = FirebaseFirestore.getInstance()
    private val dispatcher = CLIAgentMissionDispatcher(auth, firestore)
    private val dismissedMissionIDs = mutableSetOf<String>()

    private var listRegistration: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private var observedMissionID: String? = null
    private var observationJob: Job? = null

    private val _status = MutableStateFlow<InsightsViewModel.MissionStatus>(InsightsViewModel.MissionStatus.Idle)
    val status = _status.asStateFlow()

    fun start() {
        if (authListener != null) return
        authListener = FirebaseAuth.AuthStateListener { restartListListener(it.currentUser?.uid) }
        auth.addAuthStateListener(authListener!!)
        restartListListener(auth.currentUser?.uid)
    }

    fun dismissCurrent() {
        val current = _status.value
        if (current is InsightsViewModel.MissionStatus.Tracking) {
            dismissedMissionIDs += current.mission.id
        }
        observationJob?.cancel()
        observationJob = null
        observedMissionID = null
        _status.value = InsightsViewModel.MissionStatus.Idle
    }

    fun respondToMissionApproval(requestID: String, approve: Boolean) {
        viewModelScope.launch {
            try {
                dispatcher.respondToApproval(requestID, approve)
            } catch (e: Exception) {
                _status.value = InsightsViewModel.MissionStatus.Failed(
                    "Mission approval",
                    e.message ?: "Mission approval response failed.",
                )
            }
        }
    }

    private fun restartListListener(uid: String?) {
        listRegistration?.remove()
        listRegistration = null
        observationJob?.cancel()
        observationJob = null
        observedMissionID = null
        if (uid == null) {
            _status.value = InsightsViewModel.MissionStatus.Idle
            return
        }
        listRegistration = firestore.collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .orderBy("createdAt", Query.Direction.DESCENDING)
            .limit(6)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    _status.value = InsightsViewModel.MissionStatus.Failed(
                        "Mission listener",
                        error.message ?: "Mission listener failed.",
                    )
                    return@addSnapshotListener
                }
                val selected = snapshot?.documents.orEmpty()
                    .filterNot { it.id in dismissedMissionIDs }
                    .firstOrNull { doc -> doc.getString("status") !in TERMINAL_STATUSES }
                    ?: snapshot?.documents.orEmpty().firstOrNull { it.id !in dismissedMissionIDs }
                if (selected == null) {
                    _status.value = InsightsViewModel.MissionStatus.Idle
                    return@addSnapshotListener
                }
                observeMission(selected.id)
            }
    }

    private fun observeMission(requestID: String) {
        if (requestID == observedMissionID) return
        observedMissionID = requestID
        observationJob?.cancel()
        observationJob = viewModelScope.launch {
            dispatcher.observe(requestID)
                .catch { e ->
                    _status.value = InsightsViewModel.MissionStatus.Failed(
                        "Mission listener",
                        e.message ?: "Mission listener failed.",
                    )
                }
                .collect { snapshot ->
                    _status.value = InsightsViewModel.MissionStatus.Tracking(snapshot)
                }
        }
    }

    override fun onCleared() {
        authListener?.let(auth::removeAuthStateListener)
        listRegistration?.remove()
        observationJob?.cancel()
        super.onCleared()
    }

    companion object {
        private val TERMINAL_STATUSES = setOf(
            "completed",
            "failed",
            "canceled",
            "cancelled",
            "unauthorized",
            "agent_launch_failed",
        )
    }
}

// ── Honest Mission Live Capsule ──
//
// Replaces the generic ExtendedFloatingActionButton with a custom animated
// pill that shows actual tools, file paths, and LLM response snippets.
//
// Design:
//   • Left: runtime call-sign badge in provider color
//   • Center: tool/LLM icon + honest mono text (cross-fades on new events)
//   • Right: mini progress ring or status dot
//   • Background: Surface with ultra-thin material + animated gradient border
//   • Motion: breathing scale pulse on new events, spring expand/collapse,
//     text slides vertically with fade on content change.

@Composable
fun MissionActivityOverlay(
    modifier: Modifier = Modifier,
    viewModel: MissionActivityViewModel = viewModel(),
) {
    val status by viewModel.status.collectAsState()
    var showMissionDetail by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.start() }

    Box(modifier = modifier, contentAlignment = Alignment.BottomEnd) {
        when (val current = status) {
            InsightsViewModel.MissionStatus.Idle -> Unit
            is InsightsViewModel.MissionStatus.Tracking -> {
                val mission = current.mission
                if (mission.isTerminal) {
                    MissionDoneCapsule(
                        mission = mission,
                        onClick = { showMissionDetail = true }
                    )
                } else {
                    MissionLiveCapsule(
                        mission = mission,
                        onClick = { showMissionDetail = true }
                    )
                }
            }
            is InsightsViewModel.MissionStatus.Failed -> {
                MissionAlertCapsule(
                    onClick = { showMissionDetail = true }
                )
            }
            is InsightsViewModel.MissionStatus.Dispatched -> Unit
        }
    }

    if (showMissionDetail) {
        MissionDetailSheet(
            status = status,
            onApprovalResponse = { requestID, approve ->
                viewModel.respondToMissionApproval(requestID, approve)
            },
            onDismiss = { showMissionDetail = false },
        )
    }
}

@Composable
private fun MissionLiveCapsule(
    mission: CLIAgentMissionSnapshot,
    onClick: () -> Unit,
) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val accent = missionAccentColor(mission, isDark)
    val frame = rememberLiveFrame(mission)

    // Breathing animation triggered by event count changes
    val eventCount = mission.events.size
    var lastEventCount by remember { mutableIntStateOf(eventCount) }
    var breath by remember { mutableStateOf(false) }
    LaunchedEffect(eventCount) {
        if (eventCount > lastEventCount) {
            breath = true
            delay(300)
            breath = false
        }
        lastEventCount = eventCount
    }

    val transition = rememberInfiniteTransition(label = "capsule-glow")
    val glowAlpha by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 0.65f,
        animationSpec = infiniteRepeatable(
            animation = tween(2000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "glow-alpha"
    )

    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
        tonalElevation = 2.dp,
        shadowElevation = 6.dp,
        modifier = Modifier
            .padding(AuroraSpacing.lg.dp)
            .graphicsLayer {
                scaleX = if (breath) 1.02f else 1f
                scaleY = if (breath) 1.02f else 1f
            }
    ) {
        Box(
            modifier = Modifier
                .background(
                    Brush.horizontalGradient(
                        colors = listOf(
                            accent.copy(alpha = glowAlpha * 0.3f),
                            Color.Transparent,
                            accent.copy(alpha = glowAlpha * 0.15f)
                        )
                    )
                )
                .padding(horizontal = 14.dp, vertical = 11.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.height(IntrinsicSize.Min)
            ) {
                // Runtime call-sign badge
                val callSign = runtimeCallSign(mission)
                RuntimeBadge(callSign = callSign, accent = accent)

                // Divider
                Box(
                    modifier = Modifier
                        .fillMaxHeight(0.65f)
                        .width(1.dp)
                        .background(accent.copy(alpha = 0.25f))
                )

                // Honest icon + text with cross-fade
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Icon(
                        imageVector = frame.icon,
                        contentDescription = null,
                        tint = accent,
                        modifier = Modifier.size(16.dp)
                    )

                    AnimatedContent(
                        targetState = frame.text,
                        transitionSpec = {
                            (slideInVertically { it / 4 } + fadeIn())
                                .togetherWith(slideOutVertically { -it / 4 } + fadeOut())
                        },
                        label = "honest-text"
                    ) { text ->
                        Text(
                            text = text,
                            style = AuroraType.tiny.copy(
                                fontWeight = FontWeight.Medium,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                            ),
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }

                Spacer(modifier = Modifier.weight(1f, fill = false))

                // Mini progress ring
                MiniProgressRing(
                    progress = frame.progress,
                    color = accent,
                    size = 18.dp
                )
            }
        }
    }
}

@Composable
private fun MissionDoneCapsule(
    mission: CLIAgentMissionSnapshot,
    onClick: () -> Unit,
) {
    val accent = AuroraColors.success
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(28.dp),
        color = accent.copy(alpha = 0.12f),
        tonalElevation = 0.dp,
        shadowElevation = 4.dp,
        modifier = Modifier.padding(AuroraSpacing.lg.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = mission.resultPreview?.takeIf { it.isNotBlank() }
                    ?.let { "Done · \${it.take(24)}" }
                    ?: "Mission done",
                style = AuroraType.tiny.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun MissionAlertCapsule(
    onClick: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.error
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(28.dp),
        color = accent.copy(alpha = 0.12f),
        tonalElevation = 0.dp,
        shadowElevation = 4.dp,
        modifier = Modifier.padding(AuroraSpacing.lg.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.WarningAmber,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = "Mission alert",
                style = AuroraType.tiny.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

// ── Helpers ──

@Composable
private fun RuntimeBadge(callSign: String, accent: Color) {
    Text(
        text = callSign,
        style = AuroraType.tiny.copy(
            fontWeight = FontWeight.Bold,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
        ),
        color = accent,
        modifier = Modifier
            .background(accent.copy(alpha = 0.14f), CircleShape)
            .padding(horizontal = 6.dp, vertical = 3.dp)
    )
}

@Composable
private fun MiniProgressRing(
    progress: Float,
    color: Color,
    size: androidx.compose.ui.unit.Dp,
) {
    val lineWidth = size / 8
    Box(contentAlignment = Alignment.Center) {
        androidx.compose.foundation.Canvas(modifier = Modifier.size(size)) {
            drawCircle(
                color = color.copy(alpha = 0.18f),
                radius = (size.toPx() - lineWidth.toPx()) / 2,
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = lineWidth.toPx())
            )
            val sweep = progress * 360f
            drawArc(
                color = color,
                startAngle = -90f,
                sweepAngle = sweep,
                useCenter = false,
                style = androidx.compose.ui.graphics.drawscope.Stroke(
                    width = lineWidth.toPx(),
                    cap = androidx.compose.ui.graphics.StrokeCap.Round
                )
            )
        }
    }
}

private data class LiveFrame(
    val icon: ImageVector,
    val text: String,
    val progress: Float,
)

@Composable
private fun rememberLiveFrame(mission: CLIAgentMissionSnapshot): LiveFrame {
    val latest = mission.events.lastOrNull()
    val progress = when (mission.displayStatus) {
        "queued", "pending" -> 0.05f
        "starting" -> 0.15f
        "running" -> 0.5f
        "waiting_for_approval" -> 0.55f
        "completed" -> 1.0f
        else -> 0.5f
    }

    val frame = when {
        latest == null -> LiveFrame(
            icon = Icons.Filled.GraphicEq,
            text = mission.currentStepLabel,
            progress = progress
        )
        latest.isError || latest.kind == "error" -> LiveFrame(
            icon = Icons.Filled.Error,
            text = "Error · \${latest.message.take(24)}",
            progress = progress
        )
        latest.kind == "tool_call" || latest.phase == "tool_use" -> {
            val name = latest.toolName?.takeIf { it.isNotBlank() } ?: latest.title ?: "Tool"
            val detail = latest.changedFilePath?.split("/")?.last()
                ?: latest.artifactPath?.split("/")?.last()
                ?: latest.message.take(20)
            LiveFrame(
                icon = toolIcon(name),
                text = "$name · $detail",
                progress = progress
            )
        }
        latest.kind == "tool_result" || latest.phase == "tool_result" -> {
            val name = latest.toolName?.takeIf { it.isNotBlank() } ?: "Tool"
            val detail = latest.changedFilePath?.split("/")?.last() ?: "done"
            LiveFrame(
                icon = Icons.Filled.CheckCircle,
                text = "$name · $detail",
                progress = progress
            )
        }
        latest.kind in setOf("llm_response", "assistant_message", "final_answer") -> {
            val preview = latest.message.replace("\n", " ").take(28)
            LiveFrame(
                icon = Icons.Filled.TextSnippet,
                text = "\"$preview\"",
                progress = progress
            )
        }
        latest.kind == "approval_request" || "approval" in latest.phase -> LiveFrame(
            icon = Icons.Filled.Gavel,
            text = "Approval · ${latest.message.take(24)}",
            progress = progress
        )
        latest.kind == "changed_file" || latest.changedFilePath != null -> {
            val file = latest.changedFilePath?.split("/")?.last() ?: "file"
            LiveFrame(
                icon = Icons.Filled.Edit,
                text = "Edited · $file",
                progress = progress
            )
        }
        else -> LiveFrame(
            icon = Icons.Filled.GraphicEq,
            text = mission.currentStepLabel,
            progress = progress
        )
    }
    return frame
}

private fun toolIcon(name: String): ImageVector = when {
    name.contains("read", ignoreCase = true) -> Icons.Filled.TextSnippet
    name.contains("write", ignoreCase = true) -> Icons.Filled.Edit
    name.contains("edit", ignoreCase = true) -> Icons.Filled.Edit
    name.contains("search", ignoreCase = true) -> Icons.Filled.Search
    name.contains("grep", ignoreCase = true) -> Icons.Filled.Search
    name.contains("build", ignoreCase = true) -> Icons.Filled.Build
    name.contains("test", ignoreCase = true) -> Icons.Filled.Handyman
    else -> Icons.Filled.AutoAwesome
}

private fun runtimeCallSign(mission: CLIAgentMissionSnapshot): String {
    val raw = mission.selectedRuntime ?: mission.requestedRuntime
    return when {
        raw == null || raw == "auto" -> "AUTO"
        raw.contains("claude") -> "CLD"
        raw.contains("codex") -> "CDX"
        raw.contains("hermes") -> "HRM"
        raw == "pi" || raw.contains("piagent") -> "PI"
        raw.contains("openclaw") -> "OCL"
        raw.contains("ollama") -> "OLL"
        else -> raw.uppercase().take(3)
    }
}

private fun missionAccentColor(mission: CLIAgentMissionSnapshot, isDark: Boolean): Color {
    val latest = mission.events.lastOrNull()
    return when {
        latest?.isError == true || latest?.kind == "error" ->
            if (isDark) AuroraColors.emberDark else AuroraColors.ember
        latest?.kind == "approval_request" || latest?.phase?.contains("approval") == true ->
            if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
        latest?.kind in setOf("tool_call", "tool_result") || latest?.phase in setOf("tool_use", "tool_result") ->
            if (isDark) AuroraColors.amberDark else AuroraColors.amber
        latest?.kind in setOf("llm_response", "assistant_message") ->
            if (isDark) AuroraColors.tealDark else AuroraColors.teal
        else -> if (isDark) AuroraColors.amberDark else AuroraColors.amber
    }
}
