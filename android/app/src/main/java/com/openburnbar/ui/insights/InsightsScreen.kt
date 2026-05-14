package com.openburnbar.ui.insights

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Top-level Insights screen. Shows the canvas library (list of saved canvases)
 * and a default "Today" canvas built by the local rule engine on first launch.
 */
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

    LaunchedEffect(Unit) {
        viewModel.load()
    }

    val density = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, fontScale = density.fontScale.coerceAtMost(1.15f))
    ) {
        Surface(
            modifier = Modifier
                .then(modifier)
                .fillMaxSize(),
            color = MaterialTheme.colorScheme.background
        ) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = AuroraSpacing.lg.dp,
                    end = AuroraSpacing.lg.dp,
                    top = AuroraSpacing.md.dp,
                    bottom = AuroraSpacing.xxl.dp
                ),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
            ) {
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "Insights",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.weight(1f)
                        )
                        // Brief-options inspector — mirrors iOS toolbar
                        // `slider.horizontal.3`. All model / privacy /
                        // theme controls live behind this single gear so
                        // the editorial brief is uncluttered.
                        IconButton(onClick = { showInspector = true }) {
                            Icon(
                                imageVector = Icons.Filled.Tune,
                                contentDescription = "Brief options",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(22.dp)
                            )
                        }
                    }
                }

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

                item {
                    MissionStatusBanner(
                        status = missionStatus,
                        onDismiss = { viewModel.dismissMissionStatus() },
                    )
                }

                item {
                    AnimatedVisibility(
                        visible = isLoading,
                        enter = fadeIn(animationSpec = spring()),
                        exit = fadeOut()
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(240.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                CircularProgressIndicator(color = AuroraColors.purple)
                                Spacer(modifier = Modifier.height(16.dp))
                                Text(
                                    "Building your canvas...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }

                item {
                    AnimatedVisibility(
                        visible = !isLoading && canvas != null,
                        enter = fadeIn(animationSpec = spring()),
                        exit = fadeOut()
                    ) {
                        canvas?.let {
                            InsightsCanvasGrid(
                                canvas = it,
                                selectedWidgetId = selectedWidgetId,
                                onSelect = { id -> viewModel.selectWidget(id) },
                                onMove = { _, _, _ -> },
                                onConfigure = { id -> viewModel.selectWidget(id) },
                                onCitationTap = { viewModel.ask(citationPrompt(it)) }
                            )
                        }
                    }
                }

                item {
                    AnimatedVisibility(
                        visible = !isLoading && canvas == null,
                        enter = fadeIn(),
                        exit = fadeOut()
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(240.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                error ?: "No synced rollup data yet.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                }

                error?.let { errorMessage ->
                    item {
                        Text(
                            text = errorMessage,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                }

                item {
                    InsightsComposer(
                        isLoading = isLoading,
                        onAsk = { viewModel.ask(it) }
                    )
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
                    onDismiss = { showInspector = false }
                )
            }
        }
    }
}

@Composable
private fun MissionStatusBanner(
    status: InsightsViewModel.MissionStatus,
    onDismiss: () -> Unit,
) {
    when (status) {
        InsightsViewModel.MissionStatus.Idle -> Unit
        is InsightsViewModel.MissionStatus.Dispatched -> {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
                tonalElevation = 1.dp,
            ) {
                Row(
                    modifier = Modifier.padding(AuroraSpacing.md.dp),
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Send, contentDescription = null, tint = InsightsColors.kpiPositive)
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Mission dispatched to ${status.runtime}", style = MaterialTheme.typography.labelLarge)
                        Text(
                            "${status.title}. Open the matching assistant tile to watch the Mac-run transcript sync back.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    TextButton(onClick = onDismiss) { Text("Dismiss") }
                }
            }
        }
        is InsightsViewModel.MissionStatus.Failed -> {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surfaceVariant,
                tonalElevation = 1.dp,
            ) {
                Row(
                    modifier = Modifier.padding(AuroraSpacing.md.dp),
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Mission was not dispatched", style = MaterialTheme.typography.labelLarge)
                        Text("${status.title}: ${status.message}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TextButton(onClick = onDismiss) { Text("Dismiss") }
                }
            }
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
 * Brief options inspector — Android parity for the iOS
 * `InsightsMobileInspectorView` modal. Hosts the controls that used to
 * clutter the brief header (Insights model, Local-only privacy toggle,
 * Theme picker) behind a single gear so the editorial brief itself stays
 * uncluttered. Opens as a Material 3 `ModalBottomSheet` from the gear
 * icon in the Insights header.
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
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = AuroraSpacing.lg.dp,
                    end = AuroraSpacing.lg.dp,
                    bottom = AuroraSpacing.xl.dp
                ),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
        ) {
            Text(
                text = "Brief options",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )

            // ─── Model & privacy ────────────────────────────────────
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                SectionHeader(text = "Model & privacy")
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Local-only models",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            text = "Restrict to engines that never leave this device",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
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
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        )
                    }
                }
                Text(
                    text = "Currently running on ${selectedModel.displayName} · ${selectedModel.egressTier.displayLabel}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // ─── Theme ───────────────────────────────────────────────
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                SectionHeader(text = "Theme")
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(InsightTheme.entries.toList()) { theme ->
                        FilterChip(
                            selected = theme == currentTheme,
                            onClick = { onThemeChange(theme) },
                            label = {
                                Text(
                                    text = theme.displayName,
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun InsightsComposer(
    isLoading: Boolean,
    onAsk: (String) -> Unit
) {
    var prompt by remember { mutableStateOf("") }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        OutlinedTextField(
            value = prompt,
            onValueChange = { prompt = it },
            modifier = Modifier.weight(1f),
            singleLine = true,
            label = { Text("Ask Insights") }
        )
        Button(
            enabled = prompt.isNotBlank() && !isLoading,
            onClick = {
                val question = prompt
                prompt = ""
                onAsk(question)
            }
        ) {
            Icon(Icons.Filled.Send, contentDescription = "Ask")
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
