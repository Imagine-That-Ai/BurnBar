@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tune
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
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.verdict.InsightVerdict
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.settings.rememberWebsiteBackground
import com.openburnbar.ui.theme.AuroraType

internal data class InsightsScreenScaffoldState(
    val modifier: Modifier,
    val useWebsiteBackground: Boolean,
    val canvasTitle: String,
    val isLoading: Boolean,
    val onRefresh: () -> Unit,
    val onShowInspector: () -> Unit,
    val onAsk: (String) -> Unit,
)

internal data class InsightsScreenOverlaysState(
    val showInspector: Boolean,
    val showMissionDetail: Boolean,
    val briefOptions: BriefOptionsState,
    val briefOptionsCallbacks: BriefOptionsCallbacks,
    val missionStatus: InsightsViewModel.MissionStatus,
    val onApprovalResponse: (String, Boolean) -> Unit,
    val onDismissMissionDetail: () -> Unit,
)

internal data class InsightsBriefTabModel(
    val verdict: InsightVerdict?,
    val verdictIsDemo: Boolean,
    val analysis: InsightAnalysisResult?,
    val canvas: InsightCanvas?,
    val isLoading: Boolean,
    val error: String?,
    val missionStatus: InsightsViewModel.MissionStatus,
    val selectedWidgetId: String?,
    val theme: InsightTheme,
)

internal data class InsightsBriefTabActions(
    val onRefresh: () -> Unit,
    val onAsk: (String) -> Unit,
    val onLaunchMission: (MissionLaunchAction, MissionLaunchOptions) -> Unit,
    val onDismissMissionStatus: () -> Unit,
    val onSelectWidget: (String) -> Unit,
)

internal data class BriefOptionsState(
    val selectedModel: InsightModelTag,
    val modelOptions: List<InsightModelTag>,
    val localOnlyMode: Boolean,
    val currentTheme: InsightTheme,
)

internal data class BriefOptionsCallbacks(
    val onModelSelected: (InsightModelTag) -> Unit,
    val onLocalOnlyChanged: (Boolean) -> Unit,
    val onThemeChange: (InsightTheme) -> Unit,
    val onDismiss: () -> Unit,
)

internal data class InsightsScreenViewSnapshot(
    val useWebsiteBackground: Boolean,
    val canvasTitle: String,
    val isLoading: Boolean,
    val theme: InsightTheme,
    val briefTabModel: InsightsBriefTabModel,
    val selectedModel: InsightModelTag,
    val modelOptions: List<InsightModelTag>,
    val localOnlyMode: Boolean,
    val missionStatus: InsightsViewModel.MissionStatus,
)

@Composable
private fun collectInsightsScreenViewSnapshot(viewModel: InsightsViewModel): InsightsScreenViewSnapshot {
    val useWebsiteBackground by rememberWebsiteBackground()
    val canvas by viewModel.canvas.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val error by viewModel.error.collectAsState()
    val selectedWidgetId by viewModel.selectedWidgetId.collectAsState()
    val analysis by viewModel.analysis.collectAsState()
    val verdict by viewModel.verdict.collectAsState()
    val verdictIsDemo by viewModel.verdictIsDemo.collectAsState()
    val selectedModel by viewModel.selectedModel.collectAsState()
    val modelOptions by viewModel.modelOptions.collectAsState()
    val localOnlyMode by viewModel.localOnlyMode.collectAsState()
    val missionStatus by viewModel.missionStatus.collectAsState()
    val theme = canvas?.theme ?: InsightTheme.AURORA

    return InsightsScreenViewSnapshot(
        useWebsiteBackground = useWebsiteBackground,
        canvasTitle = canvas?.title ?: "Insights",
        isLoading = isLoading,
        theme = theme,
        briefTabModel =
        InsightsBriefTabModel(
            verdict = verdict,
            verdictIsDemo = verdictIsDemo,
            analysis = analysis,
            canvas = canvas,
            isLoading = isLoading,
            error = error,
            missionStatus = missionStatus,
            selectedWidgetId = selectedWidgetId,
            theme = theme,
        ),
        selectedModel = selectedModel,
        modelOptions = modelOptions,
        localOnlyMode = localOnlyMode,
        missionStatus = missionStatus,
    )
}

private fun insightsBriefTabActions(viewModel: InsightsViewModel): InsightsBriefTabActions =
    InsightsBriefTabActions(
        onRefresh = { viewModel.refresh() },
        onAsk = { viewModel.ask(it) },
        onLaunchMission = { action, options ->
            viewModel.launchMission(
                action.title,
                action.followUpQuestion().question,
                action.tone.firestoreValue(),
                options.requestedRuntime,
                options.targetProject,
                options.depth,
                options.approvalMode,
                options.commandsAllowed,
                options.fileEditsAllowed,
            )
        },
        onDismissMissionStatus = { viewModel.dismissMissionStatus() },
        onSelectWidget = { viewModel.selectWidget(it) },
    )

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InsightsScreenRoot(modifier: Modifier, viewModel: InsightsViewModel) {
    val snapshot = collectInsightsScreenViewSnapshot(viewModel)
    val briefTabActions = insightsBriefTabActions(viewModel)

    var showInspector by remember { mutableStateOf(false) }
    var showMissionDetail by remember { mutableStateOf(false) }
    var activeTab by remember { mutableStateOf("brief") }

    InsightsScreenScaffold(
        state =
        InsightsScreenScaffoldState(
            modifier = modifier,
            useWebsiteBackground = snapshot.useWebsiteBackground,
            canvasTitle = snapshot.canvasTitle,
            isLoading = snapshot.isLoading,
            onRefresh = { viewModel.refresh() },
            onShowInspector = { showInspector = true },
            onAsk = { viewModel.ask(it) },
        ),
        activeTabContent = { innerPadding ->
            InsightsScreenTabContent(
                innerPadding = innerPadding,
                activeTab = activeTab,
                onActiveTabChange = { activeTab = it },
                briefTabModel = snapshot.briefTabModel,
                briefTabActions = briefTabActions,
                onMissionOpen = { showMissionDetail = true },
            )
        },
    )

    InsightsScreenOverlays(
        state =
        InsightsScreenOverlaysState(
            showInspector = showInspector,
            showMissionDetail = showMissionDetail,
            briefOptions =
            BriefOptionsState(
                selectedModel = snapshot.selectedModel,
                modelOptions = snapshot.modelOptions,
                localOnlyMode = snapshot.localOnlyMode,
                currentTheme = snapshot.theme,
            ),
            briefOptionsCallbacks =
            BriefOptionsCallbacks(
                onModelSelected = { viewModel.selectModel(it) },
                onLocalOnlyChanged = { viewModel.setLocalOnlyMode(it) },
                onThemeChange = { viewModel.changeTheme(it) },
                onDismiss = { showInspector = false },
            ),
            missionStatus = snapshot.missionStatus,
            onApprovalResponse = { requestID, approve -> viewModel.respondToMissionApproval(requestID, approve) },
            onDismissMissionDetail = { showMissionDetail = false },
        ),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InsightsScreenScaffold(
    state: InsightsScreenScaffoldState,
    activeTabContent: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        modifier = Modifier.then(state.modifier).fillMaxSize(),
        containerColor = if (state.useWebsiteBackground) Color.Transparent else MaterialTheme.colorScheme.background,
        topBar = {
            InsightsScreenTopBar(
                canvasTitle = state.canvasTitle,
                isLoading = state.isLoading,
                onRefresh = state.onRefresh,
                onShowInspector = state.onShowInspector,
            )
        },
        bottomBar = { InsightsComposerBar(isLoading = state.isLoading, onAsk = state.onAsk) },
    ) { innerPadding -> activeTabContent(innerPadding) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InsightsScreenOverlays(state: InsightsScreenOverlaysState) {
    if (state.showInspector) {
        BriefOptionsSheet(state = state.briefOptions, callbacks = state.briefOptionsCallbacks)
    }

    if (state.showMissionDetail) {
        MissionDetailSheet(
            status = state.missionStatus,
            onApprovalResponse = state.onApprovalResponse,
            onDismiss = state.onDismissMissionDetail,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InsightsScreenTopBar(
    canvasTitle: String,
    isLoading: Boolean,
    onRefresh: () -> Unit,
    onShowInspector: () -> Unit,
) {
    CenterAlignedTopAppBar(
        title = {
            Text(
                text = canvasTitle,
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface,
            )
        },
        actions = {
            IconButton(onClick = onRefresh, enabled = !isLoading) {
                Icon(
                    imageVector = Icons.Filled.Refresh,
                    contentDescription = "Refresh brief",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
            IconButton(onClick = onShowInspector) {
                Icon(
                    imageVector = Icons.Filled.Tune,
                    contentDescription = "Brief options",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        },
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color.Transparent),
        modifier = Modifier.statusBarsPadding(),
    )
}

@Composable
internal fun InsightsScreenTabContent(
    innerPadding: PaddingValues,
    activeTab: String,
    onActiveTabChange: (String) -> Unit,
    briefTabModel: InsightsBriefTabModel,
    briefTabActions: InsightsBriefTabActions,
    onMissionOpen: () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .padding(
                top = innerPadding.calculateTopPadding(),
                bottom = innerPadding.calculateBottomPadding(),
            ),
    ) {
        InsightsScreenTabRow(activeTab = activeTab, onActiveTabChange = onActiveTabChange)
        if (activeTab == "brief") {
            InsightsBriefTabContent(model = briefTabModel, actions = briefTabActions, onMissionOpen = onMissionOpen)
        } else {
            OrgRollupView(modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun InsightsScreenTabRow(activeTab: String, onActiveTabChange: (String) -> Unit) {
    TabRow(
        selectedTabIndex = if (activeTab == "brief") 0 else 1,
        containerColor = Color.Transparent,
        contentColor = MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.xs.dp),
    ) {
        Tab(
            selected = activeTab == "brief",
            onClick = { onActiveTabChange("brief") },
            text = { Text("Brief", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold) },
        )
        Tab(
            selected = activeTab == "rollup",
            onClick = { onActiveTabChange("rollup") },
            text = { Text("Org Spend", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold) },
        )
    }
}

@Composable
internal fun InsightsBriefTabContent(
    model: InsightsBriefTabModel,
    actions: InsightsBriefTabActions,
    onMissionOpen: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        insightsBriefVerdictItem(model, actions)
        insightsBriefAnalysisItem(model, actions)
        insightsBriefMissionBannerItem(model, actions, onMissionOpen)
        item { InsightsBriefLoadingState(visible = model.isLoading && model.analysis == null) }
        item { InsightsBriefCanvasGrid(model, actions) }
        item { InsightsBriefEmptyState(model) }
        model.error?.let { insightsBriefErrorItem(it) }
    }
}

private fun LazyListScope.insightsBriefVerdictItem(model: InsightsBriefTabModel, actions: InsightsBriefTabActions) {
    model.verdict?.let { v ->
        item {
            Box(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
                com.openburnbar.ui.insights.verdict.VerdictHeroSection(
                    verdict = v,
                    isStale = false,
                    isDemo = model.verdictIsDemo,
                    onRefresh = actions.onRefresh,
                    onCitationTap = { actions.onAsk(citationPrompt(it)) },
                    onAcceptAction = { action ->
                        actions.onAsk(
                            "Run the recommended action: ${action.label} (intent: ${action.intent.name}).",
                        )
                    },
                    onFollowUpTap = actions.onAsk,
                    onTraceTap = { sessionID ->
                        actions.onAsk("Show me the full trace for session $sessionID.")
                    },
                )
            }
        }
    }
}

private fun LazyListScope.insightsBriefAnalysisItem(model: InsightsBriefTabModel, actions: InsightsBriefTabActions) {
    model.analysis?.let { result ->
        item {
            IntelligenceBriefScreen(
                result = result,
                theme = model.theme,
                modifier = Modifier.fillMaxWidth(),
                onCitationTap = { actions.onAsk(citationPrompt(it)) },
                onFollowUpTap = { actions.onAsk(it.question) },
                onMissionLaunchTap = actions.onLaunchMission,
            )
        }
    }
}

private fun LazyListScope.insightsBriefMissionBannerItem(
    model: InsightsBriefTabModel,
    actions: InsightsBriefTabActions,
    onMissionOpen: () -> Unit,
) {
    if (model.missionStatus !is InsightsViewModel.MissionStatus.Idle) {
        item {
            Box(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
                MissionStatusBanner(
                    status = model.missionStatus,
                    onDismiss = actions.onDismissMissionStatus,
                    onOpen = onMissionOpen,
                )
            }
        }
    }
}

private fun LazyListScope.insightsBriefErrorItem(message: String) {
    item {
        Text(
            text = message,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun InsightsBriefLoadingState(visible: Boolean) {
    AnimatedVisibility(visible = visible, enter = fadeIn(animationSpec = spring()), exit = fadeOut()) {
        Box(
            modifier = Modifier.fillMaxWidth().height(240.dp),
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

@Composable
private fun InsightsBriefCanvasGrid(model: InsightsBriefTabModel, actions: InsightsBriefTabActions) {
    AnimatedVisibility(
        visible = !model.isLoading && model.canvas != null,
        enter = fadeIn(animationSpec = spring()),
        exit = fadeOut(),
    ) {
        model.canvas?.let { canvas ->
            Column(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
                InsightsCanvasGrid(
                    canvas = canvas,
                    selectedWidgetId = model.selectedWidgetId,
                    onSelect = actions.onSelectWidget,
                    onMove = { _, _, _ -> },
                    onConfigure = actions.onSelectWidget,
                    onCitationTap = { actions.onAsk(citationPrompt(it)) },
                )
            }
        }
    }
}

@Composable
private fun InsightsBriefEmptyState(model: InsightsBriefTabModel) {
    AnimatedVisibility(visible = !model.isLoading && model.canvas == null, enter = fadeIn(), exit = fadeOut()) {
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .height(240.dp)
                .padding(horizontal = AuroraSpacing.lg.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = model.error ?: "No synced rollup data yet.",
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}


internal fun citationPrompt(citation: InsightCitation): String = when (val kind = citation.kind) {
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
        "Explain the ${citation.label} benchmark row: source ${kind.source}, model ${kind.modelID}, " +
            "task ${kind.taskCategory}. Compare it to the models I actually used, including cost, rank, " +
            "freshness, and whether switching would make sense."
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BriefOptionsSheet(state: BriefOptionsState, callbacks: BriefOptionsCallbacks) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = callbacks.onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier =
            Modifier
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
            BriefOptionsModelPrivacySection(state = state, callbacks = callbacks)
            BriefOptionsThemeSection(state = state, callbacks = callbacks)
        }
    }
}

@Composable
private fun BriefOptionsModelPrivacySection(state: BriefOptionsState, callbacks: BriefOptionsCallbacks) {
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
            Switch(checked = state.localOnlyMode, onCheckedChange = callbacks.onLocalOnlyChanged)
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(
                state.modelOptions.filter {
                    !state.localOnlyMode || it.egressTier == InsightEgressTier.LOCAL_ONLY
                },
            ) { model ->
                FilterChip(
                    selected =
                    model.providerKey == state.selectedModel.providerKey &&
                        model.modelID == state.selectedModel.modelID,
                    onClick = { callbacks.onModelSelected(model) },
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
            text = "Currently running on ${state.selectedModel.displayName} · ${state.selectedModel.egressTier.displayLabel}",
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun BriefOptionsThemeSection(state: BriefOptionsState, callbacks: BriefOptionsCallbacks) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        SheetSectionHeader(text = "THEME")
        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(InsightTheme.entries.toList()) { theme ->
                FilterChip(
                    selected = theme == state.currentTheme,
                    onClick = { callbacks.onThemeChange(theme) },
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

@Composable
private fun SheetSectionHeader(text: String) {
    Text(
        text = text,
        style = AuroraType.caption.copy(letterSpacing = 2.0.sp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InsightsComposerBar(isLoading: Boolean, onAsk: (String) -> Unit) {
    var prompt by remember { mutableStateOf("") }
    val isDark = isSystemInDarkTheme()
    val ember = AuroraColors.ember(isDark)
    Surface(
        modifier =
        Modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.navigationBars),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
        tonalElevation = 6.dp,
    ) {
        Column {
            Box(
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(MaterialTheme.colorScheme.outlineVariant),
            )
            InsightsComposerInputRow(
                prompt = prompt,
                isLoading = isLoading,
                ember = ember,
                onPromptChange = { prompt = it },
                onSubmit = {
                    val question = prompt
                    prompt = ""
                    onAsk(question)
                },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InsightsComposerInputRow(
    prompt: String,
    isLoading: Boolean,
    ember: Color,
    onPromptChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(
                horizontal = AuroraSpacing.md.dp,
                vertical = AuroraSpacing.sm.dp,
            )
            .padding(bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        InsightsComposerTextField(
            prompt = prompt,
            ember = ember,
            onPromptChange = onPromptChange,
        )
        InsightsComposerSendButton(
            enabled = prompt.isNotBlank() && !isLoading,
            isLoading = isLoading,
            ember = ember,
            onSubmit = onSubmit,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RowScope.InsightsComposerTextField(
    prompt: String,
    ember: Color,
    onPromptChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = prompt,
        onValueChange = onPromptChange,
        modifier =
        Modifier
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
        colors =
        TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surface,
            unfocusedContainerColor = MaterialTheme.colorScheme.surface,
            disabledContainerColor = MaterialTheme.colorScheme.surface,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            cursorColor = ember,
        ),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InsightsComposerSendButton(
    enabled: Boolean,
    isLoading: Boolean,
    ember: Color,
    onSubmit: () -> Unit,
) {
    FilledIconButton(
        enabled = enabled,
        onClick = onSubmit,
        colors =
        IconButtonDefaults.filledIconButtonColors(
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
                imageVector = Icons.AutoMirrored.Filled.Send,
                contentDescription = "Ask Insights",
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

private val InsightTheme.displayName: String
    get() =
        when (this) {
            InsightTheme.AURORA -> "Aurora"
            InsightTheme.EMBER -> "Ember"
            InsightTheme.MERCURY -> "Mercury"
            InsightTheme.WHIMSY -> "Whimsy"
            InsightTheme.MONO -> "Mono"
            InsightTheme.PRINT -> "Print"
        }
