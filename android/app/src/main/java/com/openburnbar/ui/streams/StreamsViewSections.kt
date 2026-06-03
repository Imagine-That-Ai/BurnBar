@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.StreamsSegment
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.CookingLoaderStyle
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.components.ModeAwareLoader
import com.openburnbar.ui.components.ModelLogo
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.components.ShimmerCard
import com.openburnbar.ui.components.HapticBus
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.util.Formatting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal data class StreamsViewContentState(
    val selectedSegment: StreamsSegment,
    val searchQuery: String,
    val usages: List<TokenUsage>,
    val projects: List<ProjectSummary>,
    val cloudSearchHits: List<CloudConversationSearchRow>,
    val isLoading: Boolean,
    val error: String?,
    val isCloudMember: Boolean,
    val isDark: Boolean,
)

internal data class StreamsViewContentCallbacks(
    val onSelectSegment: (StreamsSegment) -> Unit,
    val onSearchChange: (String) -> Unit,
    val onOpenCloudStore: () -> Unit,
    val onCloudHitSelected: (CloudConversationSearchRow) -> Unit,
    val onAskHermes: (String) -> Unit,
    val onLoadNext: () -> Unit,
)

internal class StreamsCloudDialogState(
    private val activityStore: ActivityStore,
    private val scope: CoroutineScope,
) {
    var selectedHit by mutableStateOf<CloudConversationSearchRow?>(null)
        private set
    var body by mutableStateOf("")
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var isLoading by mutableStateOf(false)
        private set

    fun onHitSelected(hit: CloudConversationSearchRow) {
        selectedHit = hit
        body = ""
        error = null
        isLoading = true
        scope.launch {
            try {
                body = activityStore.loadCloudConversationBody(hit)
            } catch (e: IllegalStateException) {
                error =
                    e.localizedMessage ?: "Could not decrypt this cloud conversation on this device."
            } finally {
                isLoading = false
            }
        }
    }

    fun dismiss() {
        selectedHit = null
        body = ""
        error = null
    }
}

@Composable
internal fun rememberStreamsCloudDialogState(activityStore: ActivityStore): StreamsCloudDialogState {
    val scope = rememberCoroutineScope()
    return remember(activityStore, scope) { StreamsCloudDialogState(activityStore, scope) }
}

@Composable
internal fun StreamsCloudDialogOverlay(state: StreamsCloudDialogState) {
    state.selectedHit?.let { hit ->
        CloudConversationDetailDialog(
            hit = hit,
            body = state.body,
            error = state.error,
            isLoading = state.isLoading,
            onDismiss = state::dismiss,
        )
    }
}

@Composable
internal fun StreamsViewInitialEffects(
    activityStore: ActivityStore,
    searchQuery: String,
    selectedSegment: StreamsSegment,
) {
    LaunchedEffect(Unit) { activityStore.loadInitial() }
    LaunchedEffect(searchQuery, selectedSegment) {
        if (selectedSegment != StreamsSegment.COCKPIT) activityStore.updateSearch(searchQuery)
    }
}

@Composable
internal fun StreamsViewScaffold(
    snackbarHostState: SnackbarHostState,
    state: StreamsViewContentState,
    callbacks: StreamsViewContentCallbacks,
    cloudDialogState: StreamsCloudDialogState,
    activityStore: ActivityStore,
    hermesPendingPrompt: MutableState<String?>?,
) {
    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        containerColor = Color.Transparent,
    ) { paddingValues ->
        Box(modifier = Modifier.padding(paddingValues)) {
            StreamsViewContent(
                state = state,
                callbacks = callbacks,
                activityStore = activityStore,
                hermesPendingPrompt = hermesPendingPrompt,
                modifier = Modifier.fillMaxSize(),
            )
            StreamsCloudDialogOverlay(cloudDialogState)
        }
    }
}

@Composable
internal fun StreamsViewContent(
    state: StreamsViewContentState,
    callbacks: StreamsViewContentCallbacks,
    activityStore: ActivityStore,
    hermesPendingPrompt: MutableState<String?>?,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()
    val reachedBottom by remember {
        derivedStateOf {
            val lastVisibleItem = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            lastVisibleItem >= listState.layoutInfo.totalItemsCount - 3 && listState.layoutInfo.totalItemsCount > 0
        }
    }
    LaunchedEffect(reachedBottom) {
        if (reachedBottom) callbacks.onLoadNext()
    }

    Box(modifier = modifier.fillMaxSize()) {
        AuroraBackdrop(isDark = state.isDark)
        Column(modifier = Modifier.fillMaxSize()) {
            StreamsSegmentTabs(selectedSegment = state.selectedSegment, onSelectSegment = callbacks.onSelectSegment)
            if (state.selectedSegment == StreamsSegment.COCKPIT) {
                ConversationCockpitSection(
                    isEntitled = state.isCloudMember,
                    onOpenCloudStore = callbacks.onOpenCloudStore,
                    modifier = Modifier.weight(1f),
                )
            } else {
                StreamsSearchField(searchQuery = state.searchQuery, onSearchChange = callbacks.onSearchChange)
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize().padding(horizontal = AuroraSpacing.md.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    contentPadding = PaddingValues(bottom = AuroraSpacing.xxl.dp),
                ) {
                    when (state.selectedSegment) {
                        StreamsSegment.COCKPIT -> {}
                        StreamsSegment.SESSIONS ->
                            streamsSessionsItems(
                                StreamsSessionsListContext(
                                    activityStore = activityStore,
                                    usages = state.usages,
                                    cloudSearchHits = state.cloudSearchHits,
                                    searchQuery = state.searchQuery,
                                    isLoading = state.isLoading,
                                    error = state.error,
                                    onCloudHitSelected = callbacks.onCloudHitSelected,
                                    onAskHermes = { prompt -> hermesPendingPrompt?.value = prompt },
                                ),
                            )
                        StreamsSegment.MODELS -> streamsModelsItems(state.usages, state.isLoading)
                        StreamsSegment.PROJECTS ->
                            streamsProjectsItems(
                                projects = state.projects,
                                isLoading = state.isLoading,
                                error = state.error,
                                onRetry = { activityStore.setSegment(StreamsSegment.PROJECTS) }
                            )
                    }
                }
            }
        }
    }
}

@Composable
private fun CustomMicroChip(text: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f), RoundedCornerShape(4.dp))
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.25f), RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Text(
            text = text,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
internal fun StreamsSegmentTabs(selectedSegment: StreamsSegment, onSelectSegment: (StreamsSegment) -> Unit) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)
            .height(42.dp)
            .clip(RoundedCornerShape(21.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.25f))
            .border(
                width = 0.5.dp,
                color = MaterialTheme.colorScheme.outline.copy(alpha = 0.15f),
                shape = RoundedCornerShape(21.dp)
            )
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StreamsSegment.entries.forEach { segment ->
            val isSelected = selectedSegment == segment
            val bgGradient = if (isSelected) {
                Brush.linearGradient(
                    if (isDark) {
                        listOf(AuroraColors.ember.copy(alpha = 0.25f), AuroraColors.amber.copy(alpha = 0.12f))
                    } else {
                        listOf(AuroraColors.ember.copy(alpha = 0.16f), AuroraColors.amber.copy(alpha = 0.08f))
                    }
                )
            } else {
                Brush.linearGradient(listOf(Color.Transparent, Color.Transparent))
            }
            val borderModifier = if (isSelected) {
                Modifier.border(
                    width = 0.5.dp,
                    color = AuroraColors.ember.copy(alpha = 0.35f),
                    shape = RoundedCornerShape(18.dp)
                )
            } else {
                Modifier
            }

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(18.dp))
                    .background(bgGradient)
                    .then(borderModifier)
                    .clickable {
                        if (!isSelected) {
                            onSelectSegment(segment)
                            HapticBus.tabChange(context)
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = segment.label,
                    fontSize = 12.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
                    color = if (isSelected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                )
            }
        }
    }
}

@Composable
internal fun StreamsSearchField(searchQuery: String, onSearchChange: (String) -> Unit) {
    var inputFocused by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.md.dp)
            .height(48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f))
            .border(
                width = if (inputFocused) 1.dp else 0.5.dp,
                color = if (inputFocused) AuroraColors.ember.copy(alpha = 0.7f) else MaterialTheme.colorScheme.outline.copy(alpha = 0.2f),
                shape = RoundedCornerShape(12.dp),
            )
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(
                imageVector = Icons.Filled.Search,
                contentDescription = null,
                tint = if (inputFocused) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))

            OutlinedTextField(
                value = searchQuery,
                onValueChange = onSearchChange,
                modifier = Modifier
                    .weight(1f)
                    .onFocusChanged { inputFocused = it.isFocused },
                placeholder = {
                    Text(
                        "Search sessions, models, projects...",
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                    )
                },
                singleLine = true,
                textStyle = LocalTextStyle.current.copy(
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurface
                ),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.Transparent,
                    unfocusedBorderColor = Color.Transparent,
                    disabledBorderColor = Color.Transparent,
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    cursorColor = AuroraColors.ember,
                ),
            )

            if (searchQuery.isNotEmpty()) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Clear",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier
                        .size(16.dp)
                        .clickable { onSearchChange("") }
                )
            }
        }
    }
}

internal data class StreamsSessionsListContext(
    val activityStore: ActivityStore,
    val usages: List<TokenUsage>,
    val cloudSearchHits: List<CloudConversationSearchRow>,
    val searchQuery: String,
    val isLoading: Boolean,
    val error: String?,
    val onCloudHitSelected: (CloudConversationSearchRow) -> Unit,
    val onAskHermes: (String) -> Unit,
)

internal fun LazyListScope.streamsSessionsItems(ctx: StreamsSessionsListContext) {
    if (ctx.isLoading && ctx.usages.isEmpty()) {
        items(5) { ShimmerCard(height = 70) }
        return
    }
    if (ctx.error != null && ctx.usages.isEmpty()) {
        item {
            ErrorStateView(
                icon = Icons.Filled.Error,
                title = "Couldn't Load Streams",
                message = ctx.error ?: "",
                onRetry = { ctx.activityStore.refresh() },
            )
        }
        return
    }
    if (!ctx.isLoading && ctx.usages.isEmpty()) {
        item {
            EmptyStateView(
                icon = Icons.Filled.Terminal,
                title = "No Activity Yet",
                message = "Your token usage will appear here once you start using AI.",
            )
        }
        return
    }

    val filtered = streamsFilterUsages(ctx.usages, ctx.searchQuery)
    streamsCloudSearchItems(ctx.cloudSearchHits, ctx.onCloudHitSelected)
    items(filtered, key = { it.id }) { usage ->
        UsageCard(
            usage = usage,
            onAskHermes = ctx.onAskHermes,
        )
    }
    if (ctx.isLoading && ctx.usages.isNotEmpty()) {
        item { LinearProgressIndicator(modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.sm.dp)) }
    }
}

private fun LazyListScope.streamsCloudSearchItems(
    cloudSearchHits: List<CloudConversationSearchRow>,
    onCloudHitSelected: (CloudConversationSearchRow) -> Unit,
) {
    if (cloudSearchHits.isEmpty()) return
    item {
        Text(
            "Cloud conversation matches",
            modifier = Modifier.padding(top = AuroraSpacing.xs.dp, bottom = AuroraSpacing.xxs.dp),
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    items(cloudSearchHits, key = { "cloud-${it.id}" }) { hit ->
        CloudConversationSearchCard(hit = hit, onClick = { onCloudHitSelected(hit) })
    }
}

internal fun LazyListScope.streamsModelsItems(usages: List<TokenUsage>, isLoading: Boolean) {
    val modelSummaries =
        usages.groupBy { it.model }
            .map { (model, rows) -> Triple(model, rows.size, rows.sumOf { it.cost }) }
            .sortedByDescending { it.third }

    if (isLoading && modelSummaries.isEmpty()) {
        items(5) { ShimmerCard(height = 70) }
        return
    }
    if (modelSummaries.isEmpty() && !isLoading) {
        item {
            EmptyStateView(
                icon = Icons.Filled.Code,
                title = "No Model Data",
                message = "Model-level analytics will appear here.",
            )
        }
        return
    }
    items(modelSummaries) { (model, count, cost) ->
        ModelSummaryCard(model = model ?: "unknown", requestCount = count, totalCost = cost)
    }
}

internal fun LazyListScope.streamsProjectsItems(
    projects: List<ProjectSummary>,
    isLoading: Boolean,
    error: String?,
    onRetry: () -> Unit
) {
    if (isLoading && projects.isEmpty()) {
        items(5) { ShimmerCard(height = 70) }
        return
    }
    if (error != null && projects.isEmpty()) {
        item {
            ErrorStateView(
                icon = Icons.Filled.Error,
                title = "Couldn't Load Projects",
                message = error,
                onRetry = onRetry,
            )
        }
        return
    }
    if (projects.isEmpty() && !isLoading) {
        item {
            EmptyStateView(icon = Icons.Filled.Folder, title = "No Projects", message = "Projects will appear here as you use AI.")
        }
        return
    }
    items(projects) { project ->
        ProjectCard(project = project)
    }
}

private fun streamsFilterUsages(usages: List<TokenUsage>, searchQuery: String): List<TokenUsage> {
    if (searchQuery.isBlank()) return usages
    return usages.filter {
        it.model?.contains(searchQuery, ignoreCase = true) == true ||
            it.provider.contains(searchQuery, ignoreCase = true) ||
            it.projectName?.contains(searchQuery, ignoreCase = true) == true
    }
}

@Composable
fun UsageCard(usage: TokenUsage, onAskHermes: (String) -> Unit) {
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ProviderAvatar(providerKey = usage.provider, size = 20)
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text(usage.provider, fontWeight = FontWeight.Bold, fontSize = AuroraTypography.caption.sp)
                    Text(" · ${usage.model}", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text("Cost", fontSize = 9.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                    Text(Formatting.formatCurrency(usage.cost), fontWeight = FontWeight.Bold, color = AuroraColors.burnOrange, fontSize = 14.sp)
                }
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Tokens: ${Formatting.formatTokens(usage.inputTokens.toLong() + usage.outputTokens.toLong())}",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "Started: ${Formatting.formatRelativeTime(usage.timestamp)}",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            Brush.linearGradient(
                                listOf(
                                    AuroraColors.hermesMercury.copy(alpha = 0.15f),
                                    AuroraColors.hermesAureate.copy(alpha = 0.08f)
                                )
                            )
                        )
                        .border(
                            width = 0.5.dp,
                            brush = Brush.linearGradient(AuroraGradients.mercuryGradient),
                            shape = RoundedCornerShape(12.dp)
                        )
                        .clickable { onAskHermes("What was this session about?") }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Filled.AutoAwesome,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                        tint = AuroraColors.hermesAureate
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = "Ask Hermes",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }

                usage.projectName?.takeIf { it.isNotBlank() }?.let { projName ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f), RoundedCornerShape(4.dp))
                            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.25f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 6.dp, vertical = 2.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Folder,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            modifier = Modifier.size(10.dp)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = projName,
                            fontSize = 9.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun CloudConversationSearchCard(hit: CloudConversationSearchRow, onClick: () -> Unit) {
    AuroraGlassCard(interactive = true, onClick = onClick) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Lock, contentDescription = null, modifier = Modifier.size(16.dp), tint = AuroraColors.teal)
                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                Text(
                    hit.title.ifBlank { "Encrypted session" },
                    modifier = Modifier.weight(1f),
                    fontWeight = FontWeight.Bold,
                    fontSize = AuroraTypography.caption.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    Icons.Filled.ChevronRight,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Text(
                hit.snippet,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                hit.provider?.takeIf { it.isNotBlank() }?.let {
                    CustomMicroChip(text = it)
                }
                hit.projectName?.takeIf { it.isNotBlank() }?.let {
                    CustomMicroChip(text = it)
                }
            }
        }
    }
}

@Composable
internal fun CloudConversationDetailDialog(
    hit: CloudConversationSearchRow,
    body: String,
    error: String?,
    isLoading: Boolean,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Column {
                Text(hit.title.ifBlank { "Encrypted session" }, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text("Decrypted on this device", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        text = {
            when {
                isLoading ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    ) {
                        ModeAwareLoader(style = CookingLoaderStyle.INLINE, strokeWidth = 2.dp)
                        Text("Opening encrypted conversation...")
                    }
                error != null -> Text(error, color = MaterialTheme.colorScheme.error)
                else ->
                    SelectionContainer {
                        Text(
                            body.ifBlank { hit.snippet },
                            modifier = Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                            fontSize = 12.sp,
                            lineHeight = 17.sp,
                        )
                    }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
fun ModelSummaryCard(model: String, requestCount: Int, totalCost: Double) {
    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ModelLogo(modelKey = model, size = 32.dp)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Column {
                    Text(model, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Spacer(modifier = Modifier.height(2.dp))
                    CustomMicroChip(text = "$requestCount requests")
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("Total spend", fontSize = 9.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                Text(Formatting.formatCurrency(totalCost), fontWeight = FontWeight.Bold, color = AuroraColors.burnOrange, fontSize = 14.sp)
            }
        }
    }
}

@Composable
fun ProjectCard(project: ProjectSummary) {
    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.Folder,
                    contentDescription = null,
                    tint = AuroraColors.ember,
                    modifier = Modifier.size(22.dp)
                )
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Column {
                    Text(project.name, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    Spacer(modifier = Modifier.height(2.dp))
                    CustomMicroChip(text = "${project.totalSessions} sessions")
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("Total spend", fontSize = 9.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                Text(Formatting.formatCurrency(project.totalCost), fontWeight = FontWeight.Bold, color = AuroraColors.burnOrange, fontSize = 14.sp)
                Text(
                    "Tokens: ${Formatting.formatTokens(project.totalTokens)}",
                    fontSize = 10.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
