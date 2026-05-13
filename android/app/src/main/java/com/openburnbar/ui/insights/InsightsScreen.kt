package com.openburnbar.ui.insights

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
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
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightTimeWindow
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
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "Insights",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = "Analysis by ${selectedModel.displayName}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Icon(
                            imageVector = Icons.Filled.AutoAwesome,
                            contentDescription = "Insights",
                            tint = AuroraColors.purple,
                            modifier = Modifier.size(22.dp)
                        )
                    }
                }

                item {
                    ModelPicker(
                        selectedModel = selectedModel,
                        modelOptions = modelOptions,
                        localOnlyMode = localOnlyMode,
                        onModelSelected = { viewModel.selectModel(it) },
                        onLocalOnlyChanged = { viewModel.setLocalOnlyMode(it) }
                    )
                }

                item {
                    ThemePicker(
                        currentTheme = canvas?.theme ?: InsightTheme.AURORA,
                        onThemeChange = { viewModel.changeTheme(it) }
                    )
                }

                analysis?.let { result ->
                    item {
                        AnalysisBrief(result)
                    }
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
                                onCitationTap = { }
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
        }
    }
}

@Composable
private fun ModelPicker(
    selectedModel: InsightModelTag,
    modelOptions: List<InsightModelTag>,
    localOnlyMode: Boolean,
    onModelSelected: (InsightModelTag) -> Unit,
    onLocalOnlyChanged: (Boolean) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Insights model",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "Local only",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Switch(checked = localOnlyMode, onCheckedChange = onLocalOnlyChanged)
            }
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(modelOptions.filter { !localOnlyMode || it.egressTier == InsightEgressTier.LOCAL_ONLY }) { model ->
                FilterChip(
                    selected = model.providerKey == selectedModel.providerKey && model.modelID == selectedModel.modelID,
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
    }
}

@Composable
private fun AnalysisBrief(result: InsightAnalysisResult) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        shape = RoundedCornerShape(8.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)
        ),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Filled.AutoAwesome,
                        contentDescription = null,
                        tint = AuroraColors.purple,
                        modifier = Modifier.size(18.dp)
                    )
                    Text(
                        text = "Intelligence Brief",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
                Text(
                    text = result.modelTag.displayName,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Text(
                text = result.executiveSummary,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                lineHeight = MaterialTheme.typography.bodyMedium.lineHeight
            )

            result.findings.take(3).forEach { finding ->
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        text = finding.title,
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = finding.recommendedAction,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = briefWindowLabel(result.timeWindow),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraColors.purple
                )
                Text(
                    text = "${result.contextBudget.estimatedPromptTokens} context tokens",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private fun briefWindowLabel(window: InsightTimeWindow): String = when (window) {
    InsightTimeWindow.Today -> "Today"
    InsightTimeWindow.Last24h -> "Last 24 hours"
    InsightTimeWindow.Last7d -> "Last 7 days"
    InsightTimeWindow.Last30d -> "Last 30 days"
    InsightTimeWindow.Last90d -> "Last 90 days"
    InsightTimeWindow.Last365d -> "Last 365 days"
    InsightTimeWindow.AllTime -> "All time"
    is InsightTimeWindow.Custom -> "${window.start} - ${window.end}"
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

@Composable
private fun ThemePicker(
    currentTheme: InsightTheme,
    onThemeChange: (InsightTheme) -> Unit
) {
    val themes = InsightTheme.entries
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        items(themes) { theme ->
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

private val InsightTheme.displayName: String
    get() = when (this) {
        InsightTheme.AURORA -> "Aurora"
        InsightTheme.EMBER -> "Ember"
        InsightTheme.MERCURY -> "Mercury"
        InsightTheme.WHIMSY -> "Whimsy"
        InsightTheme.MONO -> "Mono"
        InsightTheme.PRINT -> "Print"
    }
