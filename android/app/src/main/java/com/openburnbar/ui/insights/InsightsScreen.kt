package com.openburnbar.ui.insights

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.assistants.CLIAgentMissionEvent
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Top-level Insights screen. Visual parity target: iOS
 * `InsightsRootView` + `IntelligenceBriefView`.
 *
 * Chrome layout (top → bottom):
 *  • CenterAlignedTopAppBar with canvas title + refresh + brief-options
 *    actions, mirroring the iOS NavigationStack toolbar
 *    (`rectangle.stack`, `arrow.clockwise`, `slider.horizontal.3`).
 *  • Scrolling content: `IntelligenceBriefScreen` (9-section editorial
 *    cascade), followed by mission status banner, canvas grid, error,
 *    and empty state.
 *  • Sticky composer bar pinned to the bottom with a top hairline and
 *    a brand-tinted rounded text field + ember send pill — matches the
 *    iOS `.thinMaterial` composer.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InsightsScreen(
    modifier: Modifier = Modifier,
    viewModel: InsightsViewModel = viewModel()
) {
    val canvas by viewModel.canvas.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val selectedWidgetId by viewModel.selectedWidgetId.collectAsState()
    val analysis by viewModel.analysis.collectAsState()
    val selectedModel by viewModel.selectedModel.collectAsState()
    val modelOptions by viewModel.modelOptions.collectAsState()
    val localOnlyMode by viewModel.localOnlyMode.collectAsState()
    val missionStatus by viewModel.missionStatus.collectAsState()

    var showInspector by remember { mutableStateOf(false) }
    var showMissionDetail by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        viewModel.load()
    }

    val density = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, fontScale = density.fontScale.coerceAtMost(1.15f))
    ) {
        Scaffold(
            modifier = Modifier.then(modifier).fillMaxSize(),
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                CenterAlignedTopAppBar(
                    title = {
                        Text(
                            text = canvas?.title ?: "Insights",
                            style = AuroraType.headline,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    },
                    actions = {
                        IconButton(
                            onClick = { viewModel.refresh() },
                            enabled = !isLoading,
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Refresh,
                                contentDescription = "Refresh brief",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                        IconButton(onClick = { showInspector = true }) {
                            Icon(
                                imageVector = Icons.Filled.Tune,
                                contentDescription = "Brief options",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    },
                    colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                        containerColor = Color.Transparent,
                    ),
                    modifier = Modifier.statusBarsPadding(),
                )
            },
            bottomBar = {
                InsightsComposerBar(
                    isLoading = isLoading,
                    onAsk = { viewModel.ask(it) },
                )
            },
        ) { innerPadding ->
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    top = innerPadding.calculateTopPadding(),
                    bottom = innerPadding.calculateBottomPadding() + AuroraSpacing.lg.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            ) {
                analysis?.let { result ->
                    item {
                        IntelligenceBriefScreen(
                            result = result,
                            theme = canvas?.theme ?: InsightTheme.AURORA,
                            modifier = Modifier.fillMaxWidth(),
                            onCitationTap = { viewModel.ask(citationPrompt(it)) },
                            onFollowUpTap = { viewModel.ask(it.question) },
                            onMissionLaunchTap = { action, runtime ->
                                viewModel.launchMission(
                                    action.title,
                                    action.followUpQuestion().question,
                                    action.tone.firestoreValue(),
                                    runtime.firestoreValue,
                                )
                            },
                        )
                    }
                }

                if (missionStatus !is InsightsViewModel.MissionStatus.Idle) {
                    item {
                        Box(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
                            MissionStatusBanner(
                                status = missionStatus,
                                onDismiss = { viewModel.dismissMissionStatus() },
                                onOpen = { showMissionDetail = true },
                            )
                        }
                    }
                }

                item {
                    AnimatedVisibility(
                        visible = isLoading && analysis == null,
                        enter = fadeIn(animationSpec = spring()),
                        exit = fadeOut(),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(240.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                CircularProgressIndicator(color = AuroraColors.ember)
                                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                                Text(
                                    text = "Building your canvas…",
                                    style = AuroraType.body,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }

                item {
                    AnimatedVisibility(
                        visible = !isLoading && canvas != null,
                        enter = fadeIn(animationSpec = spring()),
                        exit = fadeOut(),
                    ) {
                        canvas?.let {
                            Column(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
                                InsightsCanvasGrid(
                                    canvas = it,
                                    selectedWidgetId = selectedWidgetId,
                                    onSelect = { id -> viewModel.selectWidget(id) },
                                    onMove = { _, _, _ -> },
                                    onConfigure = { id -> viewModel.selectWidget(id) },
                                    onCitationTap = { viewModel.ask(citationPrompt(it)) },
                                )
                            }
                        }
                    }
                }

                item {
                    AnimatedVisibility(
                        visible = !isLoading && canvas == null,
                        enter = fadeIn(),
                        exit = fadeOut(),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(240.dp)
                                .padding(horizontal = AuroraSpacing.lg.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = error ?: "No synced rollup data yet.",
                                style = AuroraType.body,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }

                error?.let { errorMessage ->
                    item {
                        Text(
                            text = errorMessage,
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier
                                .padding(horizontal = AuroraSpacing.lg.dp, vertical = 4.dp),
                        )
                    }
                }
            }

            if (showInspector) {
                BriefOptionsSheet(
                    selectedModel = selectedModel,
                    modelOptions = modelOptions,
                    localOnlyMode = localOnlyMode,
                    currentTheme = canvas?.theme ?: InsightTheme.AURORA,
                    onModelSelected = { viewModel.selectModel(it) },
                    onLocalOnlyChanged = { viewModel.setLocalOnlyMode(it) },
                    onThemeChange = { viewModel.changeTheme(it) },
                    onDismiss = { showInspector = false },
                )
            }

            if (showMissionDetail) {
                MissionDetailSheet(
                    status = missionStatus,
                    onDismiss = { showMissionDetail = false },
                )
            }
        }
    }
}

// ─── Mission Status Banner ────────────────────────────────────────────────
// Glass-card banner mirroring iOS `missionBanner` (thinMaterial backdrop,
// top-aligned tone icon, caption.semibold title, tiny detail, monoTiny
// event feed, dismiss text button).

@Composable
private fun MissionStatusBanner(
    status: InsightsViewModel.MissionStatus,
    onDismiss: () -> Unit,
    onOpen: () -> Unit,
) {
    when (status) {
        InsightsViewModel.MissionStatus.Idle -> Unit
        is InsightsViewModel.MissionStatus.Dispatched -> {
            MissionBanner(
                icon = Icons.Filled.Send,
                tone = InsightsColors.kpiPositive,
                title = "Mission dispatched to ${status.runtime}",
                detail = "${status.title}. Waiting for the Mac agent listener to claim it.",
                feedLines = emptyList(),
                onDismiss = onDismiss,
                onOpen = onOpen,
            )
        }
        is InsightsViewModel.MissionStatus.Tracking -> {
            val mission = status.mission
            val statusText = mission.status.lowercase()
            val isFailed = statusText == "failed"
            val isComplete = statusText == "completed"
            val icon = when {
                isFailed -> Icons.Filled.WarningAmber
                isComplete -> Icons.Filled.CheckCircle
                else -> Icons.Filled.GraphicEq
            }
            val isDark = androidx.compose.foundation.isSystemInDarkTheme()
            val tone = when {
                isFailed -> if (isDark) AuroraColors.warningDark else AuroraColors.warning
                isComplete -> InsightsColors.kpiPositive
                else -> AuroraColors.whimsy(isDark)
            }
            val title = when (statusText) {
                "pending" -> "Mission queued for ${mission.runtimeLabel}"
                "running" -> "Mission running on ${mission.runtimeLabel}"
                "completed" -> "Mission completed on ${mission.runtimeLabel}"
                "failed" -> "Mission failed on ${mission.runtimeLabel}"
                else -> "Mission ${mission.status} on ${mission.runtimeLabel}"
            }
            val detail = when {
                isFailed -> mission.errorMessage?.takeIf { it.isNotBlank() }
                    ?: mission.liveSummary?.takeIf { it.isNotBlank() } ?: mission.title
                isComplete -> mission.resultPreview?.takeIf { it.isNotBlank() }
                    ?: mission.liveSummary?.takeIf { it.isNotBlank() } ?: mission.title
                else -> mission.liveSummary?.takeIf { it.isNotBlank() } ?: mission.title
            }
            MissionBanner(
                icon = icon,
                tone = tone,
                title = title,
                detail = detail,
                feedLines = mission.events.takeLast(4).map { event -> "${event.phase}: ${event.message}" },
                onDismiss = onDismiss,
                onOpen = onOpen,
            )
        }
        is InsightsViewModel.MissionStatus.Failed -> {
            val isDark = androidx.compose.foundation.isSystemInDarkTheme()
            MissionBanner(
                icon = Icons.Filled.WarningAmber,
                tone = if (isDark) AuroraColors.warningDark else AuroraColors.warning,
                title = "Mission was not dispatched",
                detail = "${status.title}: ${status.message}",
                feedLines = emptyList(),
                onDismiss = onDismiss,
                onOpen = onOpen,
            )
        }
    }
}

@Composable
private fun MissionBanner(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tone: Color,
    title: String,
    detail: String,
    feedLines: List<String>,
    onDismiss: () -> Unit,
    onOpen: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen),
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f),
        tonalElevation = 1.dp,
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(
            modifier = Modifier.padding(
                horizontal = AuroraSpacing.md.dp,
                vertical = AuroraSpacing.sm.dp,
            ),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tone,
                modifier = Modifier
                    .padding(top = 2.dp)
                    .size(18.dp),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = title,
                    style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = detail,
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                )
                if (feedLines.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        feedLines.forEach { line ->
                            Text(
                                text = line,
                                style = AuroraType.monoTiny,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                                maxLines = 2,
                            )
                        }
                    }
                }
            }
            TextButton(
                onClick = onOpen,
                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
            ) {
                Text(
                    text = "Open",
                    style = AuroraType.tiny,
                    color = tone,
                )
            }
            TextButton(
                onClick = onDismiss,
                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
            ) {
                Text(
                    text = "Dismiss",
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MissionDetailSheet(
    status: InsightsViewModel.MissionStatus,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
    ) {
        when (status) {
            is InsightsViewModel.MissionStatus.Tracking -> MissionLiveDetailContent(status.mission)
            is InsightsViewModel.MissionStatus.Dispatched -> MissionQueuedDetailContent(
                title = status.title,
                runtime = status.runtime,
                detail = "Waiting for the signed-in Mac agent listener to claim this mission.",
            )
            is InsightsViewModel.MissionStatus.Failed -> MissionQueuedDetailContent(
                title = status.title,
                runtime = "Mac agent fleet",
                detail = status.message,
            )
            InsightsViewModel.MissionStatus.Idle -> Spacer(modifier = Modifier.height(1.dp))
        }
    }
}

@Composable
private fun MissionLiveDetailContent(mission: CLIAgentMissionSnapshot) {
    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp),
        contentPadding = PaddingValues(bottom = AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                Text(
                    text = "Mission Live",
                    style = AuroraType.headline,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = mission.title,
                    style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = mission.liveSummary?.takeIf { it.isNotBlank() } ?: mission.status,
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                item { MissionDetailChip(mission.status.uppercase(), Icons.Filled.GraphicEq) }
                item { MissionDetailChip(mission.runtimeLabel, Icons.Filled.CheckCircle) }
                mission.sessionID?.takeIf { it.isNotBlank() }?.let { session ->
                    item { MissionDetailChip(session, Icons.Filled.AutoAwesome) }
                }
            }
        }

        item {
            MissionDetailSection(title = "Live timeline") {
                if (mission.events.isEmpty()) {
                    Text(
                        text = "Waiting for the Mac agent to report progress.",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        items(mission.events) { event ->
            MissionTimelineRow(event)
        }

        mission.resultPreview?.takeIf { it.isNotBlank() }?.let { result ->
            item {
                MissionDetailSection(title = "Result") {
                    Text(
                        text = result,
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        mission.errorMessage?.takeIf { it.isNotBlank() }?.let { error ->
            item {
                MissionDetailSection(title = "Failure") {
                    Text(
                        text = error,
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}

@Composable
private fun MissionQueuedDetailContent(
    title: String,
    runtime: String,
    detail: String,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        Text(
            text = "Mission Live",
            style = AuroraType.headline,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = title,
            style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        MissionDetailChip(runtime, Icons.Filled.GraphicEq)
        Text(
            text = detail,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))
    }
}

@Composable
private fun MissionDetailChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
) {
    Surface(
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = AuroraSpacing.sm.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = label,
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun MissionDetailSection(
    title: String,
    content: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        Text(
            text = title,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        content()
    }
}

@Composable
private fun MissionTimelineRow(event: CLIAgentMissionEvent) {
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val tone = when (event.phase) {
        "completed" -> InsightsColors.kpiPositive
        "failed" -> if (isDark) AuroraColors.warningDark else AuroraColors.warning
        "tool_use" -> AuroraColors.ember
        else -> AuroraColors.whimsy(isDark)
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = when (event.phase) {
                "completed" -> Icons.Filled.CheckCircle
                "failed" -> Icons.Filled.WarningAmber
                "tool_use" -> Icons.Filled.Tune
                else -> Icons.Filled.GraphicEq
            },
            contentDescription = null,
            tint = tone,
            modifier = Modifier.size(18.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                Text(
                    text = event.phase.replace("_", " ").uppercase(),
                    style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                event.runtime?.takeIf { it.isNotBlank() }?.let { runtime ->
                    Text(
                        text = runtime,
                        style = AuroraType.monoTiny,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    )
                }
            }
            Text(
                text = event.message,
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = event.timestamp,
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.62f),
            )
        }
    }
}

private fun citationPrompt(citation: InsightCitation): String = when (val kind = citation.kind) {
    is InsightCitation.Kind.Session ->
        "Open session ${kind.id}${kind.provider?.let { " ($it)" } ?: ""} and summarize what drove its cost."
    is InsightCitation.Kind.Model ->
        "Drill into ${citation.label} (${kind.id}) — show me cost trend, cache hit rate, benchmark fit, and top sessions."
    is InsightCitation.Kind.Agent ->
        "Break down ${citation.label} (${kind.provider}) usage this window — sessions, cost, and top models."
    is InsightCitation.Kind.Project ->
        "Show me everything from project ${kind.name}: cost, model mix, anomalies, and active sessions."
    is InsightCitation.Kind.Day ->
        "Zoom into ${kind.date} (${citation.label}) — every provider's spend, top sessions, and any anomalies."
    is InsightCitation.Kind.Anomaly ->
        "Investigate anomaly ${kind.id} (${citation.label}) — what triggered it and is it still active?"
    is InsightCitation.Kind.Query ->
        "Re-run the query \"${kind.text}\" behind ${citation.label} and explain the result row by row."
    is InsightCitation.Kind.Quota ->
        "Detail the ${citation.label} quota signal: ${kind.provider} bucket ${kind.bucket} — headroom, refresh cadence, and projected throttling."
    is InsightCitation.Kind.Benchmark ->
        "Explain the ${citation.label} benchmark row: source ${kind.source}, model ${kind.modelID}, task ${kind.taskCategory}. Compare it to the models I actually used, including cost, rank, freshness, and whether switching would make sense."
}

/**
 * Brief options inspector — Android parity for iOS `InsightsMobileInspectorView`.
 * Hosts the model picker, local-only privacy toggle, and theme picker
 * behind the toolbar gear so the editorial brief stays uncluttered.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BriefOptionsSheet(
    selectedModel: InsightModelTag,
    modelOptions: List<InsightModelTag>,
    localOnlyMode: Boolean,
    currentTheme: InsightTheme,
    onModelSelected: (InsightModelTag) -> Unit,
    onLocalOnlyChanged: (Boolean) -> Unit,
    onThemeChange: (InsightTheme) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = AuroraSpacing.lg.dp,
                    end = AuroraSpacing.lg.dp,
                    bottom = AuroraSpacing.xl.dp,
                ),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
        ) {
            Text(
                text = "Brief options",
                style = AuroraType.title,
                color = MaterialTheme.colorScheme.onSurface,
            )

            // ─── Model & privacy ────────────────────────────────────
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                SheetSectionHeader(text = "MODEL & PRIVACY")
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Local-only models",
                            style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = "Restrict to engines that never leave this device",
                            style = AuroraType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(checked = localOnlyMode, onCheckedChange = onLocalOnlyChanged)
                }
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(
                        modelOptions.filter {
                            !localOnlyMode || it.egressTier == InsightEgressTier.LOCAL_ONLY
                        }
                    ) { model ->
                        FilterChip(
                            selected = model.providerKey == selectedModel.providerKey &&
                                model.modelID == selectedModel.modelID,
                            onClick = { onModelSelected(model) },
                            label = {
                                Text(
                                    text = model.displayName,
                                    style = AuroraType.tiny,
                                )
                            },
                        )
                    }
                }
                Text(
                    text = "Currently running on ${selectedModel.displayName} · ${selectedModel.egressTier.displayLabel}",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            // ─── Theme ───────────────────────────────────────────────
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                SheetSectionHeader(text = "THEME")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(InsightTheme.entries.toList()) { theme ->
                        FilterChip(
                            selected = theme == currentTheme,
                            onClick = { onThemeChange(theme) },
                            label = {
                                Text(
                                    text = theme.displayName,
                                    style = AuroraType.tiny,
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SheetSectionHeader(text: String) {
    Text(
        text = text,
        style = AuroraType.caption.copy(letterSpacing = 2.0.sp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

// ─── Composer bar ─────────────────────────────────────────────────────────
// iOS parity: thinMaterial-backed sticky bar with a rounded surface-filled
// text field and an ember filled paperplane send button.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InsightsComposerBar(
    isLoading: Boolean,
    onAsk: (String) -> Unit,
) {
    var prompt by remember { mutableStateOf("") }
    val isDark = androidx.compose.foundation.isSystemInDarkTheme()
    val ember = AuroraColors.ember(isDark)
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.navigationBars),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
        tonalElevation = 6.dp,
    ) {
        Column {
            // Top hairline divider so the brief content above feels
            // separated from the composer surface.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(MaterialTheme.colorScheme.outlineVariant),
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = AuroraSpacing.md.dp,
                        vertical = AuroraSpacing.sm.dp,
                    )
                    .padding(bottom = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it },
                    modifier = Modifier
                        .weight(1f)
                        .border(
                            BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                            RoundedCornerShape(AuroraRadius.md.dp),
                        ),
                    singleLine = true,
                    placeholder = {
                        Text(
                            text = "Ask anything…",
                            style = AuroraType.body,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        )
                    },
                    textStyle = AuroraType.body.copy(color = MaterialTheme.colorScheme.onSurface),
                    shape = RoundedCornerShape(AuroraRadius.md.dp),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = MaterialTheme.colorScheme.surface,
                        unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                        disabledContainerColor = MaterialTheme.colorScheme.surface,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                        cursorColor = ember,
                    ),
                )
                FilledIconButton(
                    enabled = prompt.isNotBlank() && !isLoading,
                    onClick = {
                        val question = prompt
                        prompt = ""
                        onAsk(question)
                    },
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = ember,
                        contentColor = Color.White,
                        disabledContainerColor = ember.copy(alpha = 0.35f),
                        disabledContentColor = Color.White.copy(alpha = 0.7f),
                    ),
                    shape = RoundedCornerShape(AuroraRadius.md.dp),
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            color = Color.White,
                            modifier = Modifier.size(16.dp),
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Filled.Send,
                            contentDescription = "Ask Insights",
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }
    }
}

private val InsightTheme.displayName: String
    get() = when (this) {
        InsightTheme.AURORA -> "Aurora"
        InsightTheme.EMBER -> "Ember"
        InsightTheme.MERCURY -> "Mercury"
        InsightTheme.WHIMSY -> "Whimsy"
        InsightTheme.MONO -> "Mono"
        InsightTheme.PRINT -> "Print"
    }
