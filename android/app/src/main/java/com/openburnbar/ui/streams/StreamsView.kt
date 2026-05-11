package com.openburnbar.ui.streams

import androidx.compose.animation.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.*
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.StreamsSegment
import com.openburnbar.ui.components.*
import com.openburnbar.ui.theme.*
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.util.Formatting

@Composable
fun StreamsView(
    activityStore: ActivityStore = viewModel(),
    hermesPendingPrompt: MutableState<String?>? = null
) {
    val usages by activityStore.usages.collectAsState()
    val projects by activityStore.projects.collectAsState()
    val isLoading by activityStore.isLoading.collectAsState()
    val error by activityStore.error.collectAsState()
    val selectedSegment by activityStore.selectedSegment.collectAsState()
    val hasMore by activityStore.hasMore.collectAsState()
    val isDark = isSystemInDarkTheme()

    val listState = rememberLazyListState()
    var searchQuery by remember { mutableStateOf("") }
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(Unit) { activityStore.loadInitial() }

    // Detect scroll to bottom
    val reachedBottom by remember {
        derivedStateOf {
            val lastVisibleItem = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            lastVisibleItem >= listState.layoutInfo.totalItemsCount - 3 && listState.layoutInfo.totalItemsCount > 0
        }
    }
    LaunchedEffect(reachedBottom) {
        if (reachedBottom && hasMore && !isLoading) activityStore.loadNext()
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        containerColor = Color.Transparent
    ) { paddingValues ->
        Box(modifier = Modifier.fillMaxSize().padding(paddingValues)) {
            AuroraBackdrop(isDark = isDark)

            Column(modifier = Modifier.fillMaxSize()) {
                // Segment tabs
                Row(
                    modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp),
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
                ) {
                    StreamsSegment.entries.forEach { segment ->
                        FilterChip(
                            selected = selectedSegment == segment,
                            onClick = { activityStore.setSegment(segment) },
                            label = { Text(segment.label) }
                        )
                    }
                }

                // Search bar
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.md.dp),
                    placeholder = { Text("Search sessions, models, projects...") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                    shape = MaterialTheme.shapes.medium
                )

                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

                // Content
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize().padding(horizontal = AuroraSpacing.md.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    contentPadding = PaddingValues(bottom = AuroraSpacing.xxl.dp)
                ) {
                    when (selectedSegment) {
                        StreamsSegment.SESSIONS -> {
                            if (isLoading && usages.isEmpty()) {
                                items(5) { ShimmerCard(height = 70) }
                            } else if (error != null && usages.isEmpty()) {
                                item {
                                    ErrorStateView(
                                        icon = Icons.Filled.Error,
                                        title = "Couldn't Load Streams",
                                        message = error ?: "",
                                        onRetry = { activityStore.refresh() }
                                    )
                                }
                            } else if (!isLoading && usages.isEmpty()) {
                                item {
                                    EmptyStateView(
                                        icon = Icons.Filled.Terminal,
                                        title = "No Activity Yet",
                                        message = "Your token usage will appear here once you start using AI."
                                    )
                                }
                            } else {
                                val filtered = if (searchQuery.isNotBlank())
                                    usages.filter {
                                        it.model?.contains(searchQuery, ignoreCase = true) == true ||
                                        it.provider.contains(searchQuery, ignoreCase = true) ||
                                        (it.projectName?.contains(searchQuery, ignoreCase = true) == true)
                                    } else usages

                                items(filtered, key = { it.id }) { usage ->
                                    UsageCard(
                                        usage = usage,
                                        onAskHermes = { prompt ->
                                            hermesPendingPrompt?.value = prompt
                                        }
                                    )
                                }

                                if (isLoading && usages.isNotEmpty()) {
                                    item { LinearProgressIndicator(modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.sm.dp)) }
                                }
                            }
                        }

                        StreamsSegment.MODELS -> {
                            val modelGroups = usages.groupBy { it.model }
                            val modelSummaries = modelGroups.map { (model, usages) ->
                                Triple(model, usages.size, usages.sumOf { it.cost })
                            }.sortedByDescending { it.third }

                            if (modelSummaries.isEmpty() && !isLoading) {
                                item {
                                    EmptyStateView(
                                        icon = Icons.Filled.Code,
                                        title = "No Model Data",
                                        message = "Model-level analytics will appear here."
                                    )
                                }
                            } else {
                                items(modelSummaries) { (model, count, cost) ->
                                    ModelSummaryCard(model = model ?: "unknown", requestCount = count, totalCost = cost)
                                }
                            }
                        }

                        StreamsSegment.PROJECTS -> {
                            if (projects.isEmpty() && !isLoading) {
                                item {
                                    EmptyStateView(icon = Icons.Filled.Folder, title = "No Projects", message = "Projects will appear here as you use AI.")
                                }
                            } else {
                                items(projects) { project ->
                                    ProjectCard(project = project)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ── Usage Card ──
@Composable
fun UsageCard(
    usage: TokenUsage,
    onAskHermes: (String) -> Unit
) {
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ProviderAvatar(providerKey = usage.provider, size = 20)
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text(usage.provider, fontWeight = FontWeight.Bold, fontSize = AuroraTypography.caption.sp)
                    Text(" · ${usage.model}", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(Formatting.formatCurrency(usage.cost), fontWeight = FontWeight.Bold)
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("${usage.inputTokens + usage.outputTokens} tokens", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(Formatting.formatRelativeTime(usage.timestamp), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            TextButton(
                onClick = { onAskHermes("What was this session about?") },
                contentPadding = PaddingValues(0.dp)
            ) {
                Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(14.dp))
                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                Text("Ask Hermes", fontSize = 11.sp)
            }
        }
    }
}

@Composable
fun ModelSummaryCard(model: String, requestCount: Int, totalCost: Double) {
    AuroraGlassCard {
        Row(modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Column {
                Text(model, fontWeight = FontWeight.Bold)
                Text("$requestCount requests", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(Formatting.formatCurrency(totalCost), fontWeight = FontWeight.Bold, color = AuroraColors.burnOrange)
        }
    }
}

@Composable
fun ProjectCard(project: ProjectSummary) {
    AuroraGlassCard {
        Row(modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Column {
                    Text(project.name, fontWeight = FontWeight.Bold)
                    Text("${project.totalSessions} sessions", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(Formatting.formatCurrency(project.totalCost), fontWeight = FontWeight.Bold)
                Text(Formatting.formatTokens(project.totalTokens), fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
