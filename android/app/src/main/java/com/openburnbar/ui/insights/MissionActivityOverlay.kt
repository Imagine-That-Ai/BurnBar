package com.openburnbar.ui.insights

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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.hypot
import kotlin.math.roundToInt
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import kotlinx.coroutines.Job
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

// ── Small Elegant Mission Orb ──
//
// A 56dp living orb. Circular, compact, beautiful. When idle: quiet
// compass-like icon. When live: soft radial glow + icon + one-word label.
// Color shifts by activity type. Detail lives in the sheet, not on the orb.

@Composable
fun MissionActivityOverlay(
    modifier: Modifier = Modifier,
    viewModel: MissionActivityViewModel = viewModel(),
) {
    val status by viewModel.status.collectAsState()
    var showMissionDetail by remember { mutableStateOf(false) }
    var isDismissed by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { viewModel.start() }

    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
        when (val current = status) {
            InsightsViewModel.MissionStatus.Idle -> Unit
            is InsightsViewModel.MissionStatus.Tracking -> {
                val mission = current.mission
                if (!isDismissed) {
                    if (mission.isTerminal) {
                        MissionDoneOrb(
                            onClick = { showMissionDetail = true },
                            onDismiss = { isDismissed = true }
                        )
                    } else {
                        MissionLiveOrb(
                            mission = mission,
                            onClick = { showMissionDetail = true },
                            onDismiss = { isDismissed = true }
                        )
                    }
                } else {
                    val accent = if (mission.isTerminal) AuroraColors.success
                        else missionAccentColor(mission)
                    RestoreDot(
                        accent = accent,
                        onRestore = { isDismissed = false }
                    )
                }
            }
            is InsightsViewModel.MissionStatus.Failed -> {
                if (!isDismissed) {
                    MissionAlertOrb(
                        onClick = { showMissionDetail = true },
                        onDismiss = { isDismissed = true }
                    )
                } else {
                    RestoreDot(
                        accent = MaterialTheme.colorScheme.error,
                        onRestore = { isDismissed = false }
                    )
                }
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
private fun MissionLiveOrb(
    mission: CLIAgentMissionSnapshot,
    onClick: () -> Unit,
    onDismiss: () -> Unit,
) {
    val accent = missionAccentColor(mission)
    val state = rememberOrbState(mission)
    val isActive = !mission.isTerminal

    var showTooltip by remember { mutableStateOf(false) }
    var tooltipTask by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    var orbOffset by remember { mutableStateOf(IntOffset.Zero) }
    var isDragging by remember { mutableStateOf(false) }

    val orbSize = 56.dp
    val transition = rememberInfiniteTransition(label = "orb-pulse")
    val glowAlpha by transition.animateFloat(
        initialValue = 0.20f,
        targetValue = 0.40f,
        animationSpec = infiniteRepeatable(
            animation = tween(2000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "orb-glow"
    )

    Box(
        contentAlignment = Alignment.BottomEnd,
        modifier = Modifier.padding(AuroraSpacing.lg.dp)
    ) {
        // Tooltip above the orb
        AnimatedVisibility(
            visible = showTooltip,
            enter = scaleIn() + fadeIn(),
            exit = scaleOut() + fadeOut(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .offset(y = (-44).dp)
        ) {
            TooltipPill()
        }

        // The orb with drag + tap
        Surface(
            shape = CircleShape,
            color = Color.Transparent,
            shadowElevation = 0.dp,
            modifier = Modifier
                .offset { orbOffset }
                .pointerInput(Unit) {
                    detectDragGestures(
                        onDragStart = {
                            isDragging = true
                            showTooltip = false
                            tooltipTask?.cancel()
                        },
                        onDragEnd = {
                            isDragging = false
                            // Check for flick dismiss
                            val flickThreshold = 600f
                            val velocity = hypot(
                                orbOffset.x.toFloat(),
                                orbOffset.y.toFloat()
                            )
                            if (velocity > flickThreshold) {
                                onDismiss()
                            } else {
                                orbOffset = IntOffset.Zero
                            }
                        },
                        onDragCancel = {
                            isDragging = false
                            orbOffset = IntOffset.Zero
                        }
                    ) { change, dragAmount ->
                        change.consume()
                        orbOffset += IntOffset(dragAmount.x.roundToInt(), dragAmount.y.roundToInt())
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onLongPress = {
                            showTooltip = true
                            tooltipTask?.cancel()
                            tooltipTask = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                                kotlinx.coroutines.delay(2500)
                                showTooltip = false
                            }
                        },
                        onTap = { onClick() }
                    )
                }
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.size(orbSize)
            ) {
                // Soft glow when active
                if (isActive) {
                    Box(
                        modifier = Modifier
                            .size(72.dp)
                            .background(
                                Brush.radialGradient(
                                    colors = listOf(
                                        accent.copy(alpha = glowAlpha),
                                        Color.Transparent
                                    )
                                ),
                                CircleShape
                            )
                            .blur(6.dp)
                    )
                }

                // Material disc
                Box(
                    modifier = Modifier
                        .size(orbSize)
                        .background(
                            MaterialTheme.colorScheme.surface.copy(alpha = 0.9f),
                            CircleShape
                        )
                        .border(
                            width = if (isActive) 1.5.dp else 0.8.dp,
                            color = if (isActive) accent.copy(alpha = 0.75f)
                                else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f),
                            shape = CircleShape
                        )
                        .graphicsLayer {
                            scaleX = if (isDragging) 0.92f else 1f
                            scaleY = if (isDragging) 0.92f else 1f
                            alpha = if (isDragging) 0.75f else 1f
                        }
                )

                // Center content
                if (isActive && state.label != null) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(
                            imageVector = state.icon,
                            contentDescription = null,
                            tint = accent,
                            modifier = Modifier.size(18.dp)
                        )
                        Text(
                            text = state.label,
                            style = AuroraType.tiny.copy(
                                fontWeight = FontWeight.Bold,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                            ),
                            color = accent.copy(alpha = 0.92f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                } else {
                    Icon(
                        imageVector = state.icon,
                        contentDescription = null,
                        tint = if (isActive) accent
                            else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                        modifier = Modifier.size(22.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun MissionDoneOrb(
    onClick: () -> Unit,
    onDismiss: () -> Unit,
) {
    val accent = AuroraColors.success
    var orbOffset by remember { mutableStateOf(IntOffset.Zero) }
    var isDragging by remember { mutableStateOf(false) }

    Surface(
        shape = CircleShape,
        color = Color.Transparent,
        shadowElevation = 0.dp,
        modifier = Modifier
            .padding(AuroraSpacing.lg.dp)
            .offset { orbOffset }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { isDragging = true },
                    onDragEnd = {
                        isDragging = false
                        val flickThreshold = 600f
                        val velocity = hypot(
                            orbOffset.x.toFloat(),
                            orbOffset.y.toFloat()
                        )
                        if (velocity > flickThreshold) {
                            onDismiss()
                        } else {
                            orbOffset = IntOffset.Zero
                        }
                    },
                    onDragCancel = {
                        isDragging = false
                        orbOffset = IntOffset.Zero
                    }
                ) { change, dragAmount ->
                    change.consume()
                    orbOffset += IntOffset(dragAmount.x.roundToInt(), dragAmount.y.roundToInt())
                }
            }
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(56.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .background(
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.9f),
                        CircleShape
                    )
                    .border(
                        width = 1.5.dp,
                        color = accent.copy(alpha = 0.6f),
                        shape = CircleShape
                    )
                    .graphicsLayer {
                        scaleX = if (isDragging) 0.92f else 1f
                        scaleY = if (isDragging) 0.92f else 1f
                        alpha = if (isDragging) 0.75f else 1f
                    }
            )
            Icon(
                imageVector = Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

@Composable
private fun MissionAlertOrb(
    onClick: () -> Unit,
    onDismiss: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.error
    var orbOffset by remember { mutableStateOf(IntOffset.Zero) }
    var isDragging by remember { mutableStateOf(false) }

    Surface(
        shape = CircleShape,
        color = Color.Transparent,
        shadowElevation = 0.dp,
        modifier = Modifier
            .padding(AuroraSpacing.lg.dp)
            .offset { orbOffset }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { isDragging = true },
                    onDragEnd = {
                        isDragging = false
                        val flickThreshold = 600f
                        val velocity = hypot(
                            orbOffset.x.toFloat(),
                            orbOffset.y.toFloat()
                        )
                        if (velocity > flickThreshold) {
                            onDismiss()
                        } else {
                            orbOffset = IntOffset.Zero
                        }
                    },
                    onDragCancel = {
                        isDragging = false
                        orbOffset = IntOffset.Zero
                    }
                ) { change, dragAmount ->
                    change.consume()
                    orbOffset += IntOffset(dragAmount.x.roundToInt(), dragAmount.y.roundToInt())
                }
            }
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(56.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .background(
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.9f),
                        CircleShape
                    )
                    .border(
                        width = 1.5.dp,
                        color = accent.copy(alpha = 0.75f),
                        shape = CircleShape
                    )
                    .graphicsLayer {
                        scaleX = if (isDragging) 0.92f else 1f
                        scaleY = if (isDragging) 0.92f else 1f
                        alpha = if (isDragging) 0.75f else 1f
                    }
            )
            Icon(
                imageVector = Icons.Filled.WarningAmber,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

@Composable
private fun TooltipPill() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(
                MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
                CircleShape
            )
            .border(
                width = 0.5.dp,
                color = MaterialTheme.colorScheme.outline.copy(alpha = 0.3f),
                shape = CircleShape
            )
            .padding(horizontal = 10.dp, vertical = 5.dp)
    ) {
        Icon(
            imageVector = Icons.Filled.GraphicEq,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
            modifier = Modifier.size(12.dp)
        )
        Text(
            text = "Drag to move · flick to dismiss",
            style = AuroraType.tiny.copy(
                fontWeight = FontWeight.Medium
            ),
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
            modifier = Modifier.padding(start = 4.dp)
        )
    }
}

@Composable
private fun RestoreDot(
    accent: Color,
    onRestore: () -> Unit,
) {
    val transition = rememberInfiniteTransition(label = "restore-pulse")
    val pulseAlpha by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 0.75f,
        animationSpec = infiniteRepeatable(
            animation = tween(1500, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "restore-alpha"
    )

    IconButton(
        onClick = onRestore,
        modifier = Modifier
            .padding(AuroraSpacing.lg.dp)
            .size(24.dp)
    ) {
        Box(
            modifier = Modifier
                .size(12.dp)
                .background(accent.copy(alpha = pulseAlpha), CircleShape)
        )
    }
}

// ── State ──

private data class OrbState(
    val icon: ImageVector,
    val label: String?,
)

@Composable
private fun rememberOrbState(mission: CLIAgentMissionSnapshot): OrbState {
    val latest = mission.events.lastOrNull()
    return when {
        mission.isTerminal -> OrbState(Icons.Filled.CheckCircle, null)
        latest == null -> OrbState(Icons.Filled.GraphicEq, null)
        latest.isError || latest.kind == "error" ->
            OrbState(Icons.Filled.Error, "Error")
        latest.kind == "approval_request" || latest.phase?.contains("approval") == true ->
            OrbState(Icons.Filled.Gavel, "Approve")
        latest.kind in setOf("tool_call", "tool_result") || latest.phase in setOf("tool_use", "tool_result") -> {
            val name = latest.toolName?.takeIf { it.isNotBlank() } ?: latest.title ?: "Tool"
            OrbState(toolIcon(name), name)
        }
        latest.kind in setOf("llm_response", "assistant_message", "final_answer") ->
            OrbState(Icons.Filled.TextSnippet, "LLM")
        else -> OrbState(Icons.Filled.GraphicEq, null)
    }
}

private fun toolIcon(name: String): ImageVector = when {
    name.contains("read", ignoreCase = true) -> Icons.Filled.TextSnippet
    name.contains("write", ignoreCase = true) -> Icons.Filled.Edit
    name.contains("edit", ignoreCase = true) -> Icons.Filled.Edit
    name.contains("search", ignoreCase = true) -> Icons.Filled.Search
    name.contains("grep", ignoreCase = true) -> Icons.Filled.Search
    name.contains("build", ignoreCase = true) -> Icons.Filled.Build
    name.contains("test", ignoreCase = true) -> Icons.Filled.Handyman
    else -> Icons.Filled.Build
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

private fun missionAccentColor(mission: CLIAgentMissionSnapshot): Color {
    val latest = mission.events.lastOrNull()
    return when {
        latest?.isError == true || latest?.kind == "error" -> AuroraColors.ember
        latest?.kind == "approval_request" || latest?.phase?.contains("approval") == true -> AuroraColors.hermesAureate
        latest?.kind in setOf("tool_call", "tool_result") || latest?.phase in setOf("tool_use", "tool_result") -> AuroraColors.amber
        latest?.kind in setOf("llm_response", "assistant_message") -> AuroraColors.purple
        else -> AuroraColors.amber
    }
}
