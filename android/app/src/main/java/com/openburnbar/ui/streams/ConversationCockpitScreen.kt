package com.openburnbar.ui.streams

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.firebase.ConversationQueryAggregates
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.stores.CockpitConversationRow
import com.openburnbar.data.stores.ConversationCockpitStore
import com.openburnbar.data.stores.ConversationSortDirection
import com.openburnbar.data.stores.ConversationSortField
import com.openburnbar.data.stores.SavedConversationQuery
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.components.ShimmerCard
import com.openburnbar.ui.pro.LockedFeatureVeil
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.util.Formatting
import kotlinx.coroutines.launch

// ── Conversation Cockpit ──
//
// Transforms Streams into a faceted database over every backed-up agent
// conversation. KPI header (server aggregates) → facet bar (providers, model,
// sort, saved queries) → dense decrypted result list → full-transcript reader.
// Gated behind Cloud entitlement with a teaser veil for free users so the value
// is visible before purchase. Mirrors the iOS cockpit in StreamsView.swift.

@Composable
fun ConversationCockpitSection(
    isEntitled: Boolean,
    onOpenCloudStore: () -> Unit,
    modifier: Modifier = Modifier,
    store: ConversationCockpitStore = viewModel()
) {
    if (!isEntitled) {
        Box(modifier = modifier.fillMaxSize()) {
            LockedFeatureVeil(
                headline = "Every conversation, queryable.",
                detail = "A private cockpit over every Codex, Claude, Droid, and CLI-agent session — faceted search, cost and token rollups, and full encrypted transcripts. Included with OpenBurnBar Cloud.",
                onCta = onOpenCloudStore,
                ctaLabel = "Open Cloud"
            ) {
                CockpitTeaserBackground()
            }
        }
        return
    }
    EntitledCockpit(store = store, modifier = modifier)
}

@Composable
private fun EntitledCockpit(store: ConversationCockpitStore, modifier: Modifier) {
    val rows by store.rows.collectAsState()
    val aggregates by store.aggregates.collectAsState()
    val isLoading by store.isLoading.collectAsState()
    val isPaginating by store.isPaginating.collectAsState()
    val error by store.error.collectAsState()
    val vaultLocked by store.vaultLocked.collectAsState()
    val hasMore by store.hasMore.collectAsState()
    val signature by store.signature.collectAsState()
    val savedQueries by store.savedQueries.collectAsState()
    val discoveredProviders by store.discoveredProviders.collectAsState()
    val discoveredModels by store.discoveredModels.collectAsState()
    val selectedProviders by store.selectedProviders.collectAsState()
    val selectedModel by store.selectedModel.collectAsState()
    val sortField by store.sortField.collectAsState()
    val sortDirection by store.sortDirection.collectAsState()
    val dateFrom by store.dateFromMs.collectAsState()
    val dateTo by store.dateToMs.collectAsState()
    val projectQuery by store.projectQuery.collectAsState()

    var search by remember { mutableStateOf("") }
    var selectedRow by remember { mutableStateOf<CockpitConversationRow?>(null) }
    var showFilters by remember { mutableStateOf(false) }
    var showSaveQuery by remember { mutableStateOf(false) }

    val listState = rememberLazyListState()

    LaunchedEffect(signature) { store.runQuery(reset = true) }

    val reachedBottom by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 2 && listState.layoutInfo.totalItemsCount > 0
        }
    }
    LaunchedEffect(reachedBottom) {
        if (reachedBottom && hasMore && !isPaginating && !isLoading) store.loadNextPage()
    }

    val hasActiveFilters = selectedProviders.isNotEmpty() ||
        selectedModel != null ||
        projectQuery.isNotEmpty() ||
        dateFrom != null ||
        dateTo != null

    val trimmed = search.trim().lowercase()
    val filteredRows = if (trimmed.isEmpty()) rows else rows.filter { row ->
        (row.title?.lowercase()?.contains(trimmed) == true) ||
            (row.preview?.lowercase()?.contains(trimmed) == true) ||
            (row.projectName?.lowercase()?.contains(trimmed) == true) ||
            (row.model?.lowercase()?.contains(trimmed) == true) ||
            (row.provider?.lowercase()?.contains(trimmed) == true) ||
            (row.workingDirectory?.lowercase()?.contains(trimmed) == true)
    }
    val hasNarrowingInput = hasActiveFilters || trimmed.isNotEmpty()

    Column(modifier = modifier.fillMaxSize()) {
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.md.dp),
            placeholder = { Text("Filter loaded conversations…") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            singleLine = true,
            shape = MaterialTheme.shapes.medium
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().padding(horizontal = AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            contentPadding = PaddingValues(bottom = AuroraSpacing.xxl.dp)
        ) {
            item(key = "kpi") { CockpitKpiHeader(aggregates = aggregates, rows = rows) }
            item(key = "facets") {
                CockpitFacetBar(
                    sortField = sortField,
                    sortDirection = sortDirection,
                    selectedModel = selectedModel,
                    discoveredModels = discoveredModels,
                    discoveredProviders = discoveredProviders,
                    selectedProviders = selectedProviders,
                    savedQueries = savedQueries,
                    hasActiveFilters = hasActiveFilters,
                    onSetSort = { f, d -> store.setSort(f, d) },
                    onSetModel = { store.setModel(it) },
                    onToggleProvider = { store.toggleProvider(it) },
                    onOpenFilters = { showFilters = true },
                    onSaveQuery = { showSaveQuery = true },
                    onClearFilters = { store.clearFilters() },
                    onApplySaved = { store.applySavedQuery(it) },
                    onDeleteSaved = { store.deleteSavedQuery(it) }
                )
            }
            if (vaultLocked) {
                item(key = "vault") { VaultNotice() }
            }

            when {
                isLoading && rows.isEmpty() -> {
                    items(6) { ShimmerCard(height = 86) }
                }
                error != null && rows.isEmpty() -> {
                    item {
                        ErrorStateView(
                            icon = Icons.Filled.Error,
                            title = "Query failed",
                            message = error ?: "",
                            onRetry = { store.runQuery(reset = true) }
                        )
                    }
                }
                filteredRows.isEmpty() -> {
                    item {
                        EmptyStateView(
                            icon = if (hasNarrowingInput) Icons.Filled.SearchOff else Icons.Filled.GridView,
                            title = if (hasNarrowingInput) "No matches" else "No conversations yet",
                            message = if (hasNarrowingInput)
                                "Adjust or clear the filters to widen your search."
                            else
                                "Turn on conversation backup on your Mac and every session will appear here — fully searchable, end-to-end encrypted."
                        )
                    }
                }
                else -> {
                    items(filteredRows, key = { it.id }) { row ->
                        CockpitConversationRowView(row = row, onClick = { selectedRow = row })
                    }
                    if (isPaginating) {
                        item(key = "paginating") {
                            Box(modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = AuroraColors.ember, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                            }
                        }
                    }
                }
            }
        }
    }

    selectedRow?.let { row ->
        CockpitConversationDetailSheet(store = store, row = row, onDismiss = { selectedRow = null })
    }
    if (showFilters) {
        CockpitFilterSheet(
            projectQuery = projectQuery,
            dateFrom = dateFrom,
            dateTo = dateTo,
            onApply = { project, from, to ->
                store.setProjectQuery(project)
                store.setDateRange(from, to)
                showFilters = false
            },
            onReset = {
                store.clearFilters()
                showFilters = false
            },
            onDismiss = { showFilters = false }
        )
    }
    if (showSaveQuery) {
        SaveQueryDialog(
            onSave = { store.saveCurrentQuery(it) },
            onDismiss = { showSaveQuery = false }
        )
    }
}

// ── KPI Header ──

@Composable
private fun CockpitKpiHeader(aggregates: ConversationQueryAggregates?, rows: List<CockpitConversationRow>) {
    val conversations = aggregates?.count ?: rows.size
    val cost = aggregates?.totalCostUSD ?: rows.sumOf { it.costUSD }
    val tokens = aggregates?.totalTokens ?: rows.sumOf { it.totalTokens.toLong() }

    val providerMix = remember(rows) {
        rows.asSequence()
            .filter { !it.provider.isNullOrBlank() }
            .groupBy { it.provider!! }
            .mapValues { entry -> entry.value.sumOf { it.totalTokens.toLong() } }
            .entries.sortedByDescending { it.value }
            .take(6)
    }
    val maxTokens = providerMix.maxOfOrNull { it.value }?.coerceAtLeast(1L) ?: 1L

    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            KpiTile(
                title = "Conversations",
                value = conversations.toString(),
                icon = Icons.Filled.Forum,
                tint = AuroraColors.ember,
                modifier = Modifier.weight(1f)
            )
            KpiTile(
                title = "Total cost",
                value = Formatting.formatCurrency(cost),
                icon = Icons.Filled.Paid,
                tint = AuroraColors.teal,
                modifier = Modifier.weight(1f)
            )
            KpiTile(
                title = "Tokens",
                value = Formatting.formatTokens(tokens),
                icon = Icons.Filled.Numbers,
                tint = AuroraColors.purple,
                modifier = Modifier.weight(1f)
            )
        }
        if (providerMix.size > 1) {
            AuroraGlassCard(cornerRadius = AuroraRadius.lg) {
                Text(
                    "TOKEN MIX · LOADED",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.1.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                providerMix.forEach { entry ->
                    val provider = AgentProvider.fromKey(entry.key)
                    val label = provider?.displayName ?: entry.key.replaceFirstChar { it.uppercase() }
                    val barColor = provider?.let { Color(it.brandColor) } ?: AuroraColors.ember
                    Column(modifier = Modifier.padding(vertical = 3.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text(label, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Text(Formatting.formatTokens(entry.value), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Spacer(modifier = Modifier.height(3.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), RoundedCornerShape(3.dp))
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(fraction = (entry.value.toFloat() / maxTokens.toFloat()).coerceIn(0.02f, 1f))
                                    .height(6.dp)
                                    .background(barColor, RoundedCornerShape(3.dp))
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun KpiTile(
    title: String,
    value: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    modifier: Modifier = Modifier
) {
    AuroraGlassCard(modifier = modifier, cornerRadius = AuroraRadius.lg, contentPadding = AuroraSpacing.md.dp) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Text(
            value,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        Text(title, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// ── Facet Bar ──

@Composable
private fun CockpitFacetBar(
    sortField: ConversationSortField,
    sortDirection: ConversationSortDirection,
    selectedModel: String?,
    discoveredModels: List<String>,
    discoveredProviders: List<String>,
    selectedProviders: Set<String>,
    savedQueries: List<SavedConversationQuery>,
    hasActiveFilters: Boolean,
    onSetSort: (ConversationSortField, ConversationSortDirection) -> Unit,
    onSetModel: (String?) -> Unit,
    onToggleProvider: (String) -> Unit,
    onOpenFilters: () -> Unit,
    onSaveQuery: () -> Unit,
    onClearFilters: () -> Unit,
    onApplySaved: (SavedConversationQuery) -> Unit,
    onDeleteSaved: (SavedConversationQuery) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
        ) {
            SortMenuChip(sortField = sortField, sortDirection = sortDirection, onSetSort = onSetSort)
            ModelMenuChip(selectedModel = selectedModel, discoveredModels = discoveredModels, onSetModel = onSetModel)
            FacetChip(label = "Filters", icon = Icons.Filled.Tune, active = hasActiveFilters, onClick = onOpenFilters)
            FacetChip(label = "Save", icon = Icons.Filled.BookmarkAdd, active = false, onClick = onSaveQuery)
            if (hasActiveFilters) {
                FacetChip(label = "Clear", icon = Icons.Filled.Cancel, active = false, onClick = onClearFilters)
            }
        }

        if (discoveredProviders.isNotEmpty()) {
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                discoveredProviders.forEach { provider ->
                    val active = selectedProviders.contains(provider)
                    val enumProvider = AgentProvider.fromKey(provider)
                    val dotColor = enumProvider?.let { Color(it.brandColor) }
                    FilterChip(
                        selected = active,
                        onClick = { onToggleProvider(provider) },
                        label = {
                            Text(
                                enumProvider?.displayName ?: provider.replaceFirstChar { it.uppercase() },
                                fontSize = 11.sp,
                                maxLines = 1
                            )
                        },
                        leadingIcon = dotColor?.let {
                            {
                                Box(
                                    modifier = Modifier
                                        .size(8.dp)
                                        .background(it, RoundedCornerShape(4.dp))
                                )
                            }
                        }
                    )
                }
            }
        }

        if (savedQueries.isNotEmpty()) {
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                savedQueries.forEach { query ->
                    InputChip(
                        selected = false,
                        onClick = { onApplySaved(query) },
                        label = { Text(query.name, fontSize = 11.sp, maxLines = 1) },
                        leadingIcon = { Icon(Icons.Filled.Bookmark, contentDescription = null, modifier = Modifier.size(14.dp)) },
                        trailingIcon = {
                            Icon(
                                Icons.Filled.Close,
                                contentDescription = "Delete saved query",
                                modifier = Modifier
                                    .size(16.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickableNoRipple { onDeleteSaved(query) }
                            )
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun SortMenuChip(
    sortField: ConversationSortField,
    sortDirection: ConversationSortDirection,
    onSetSort: (ConversationSortField, ConversationSortDirection) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        FacetChip(
            label = sortField.label,
            icon = Icons.Filled.SwapVert,
            trailingIcon = if (sortDirection == ConversationSortDirection.DESC) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward,
            active = true,
            onClick = { expanded = true }
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            ConversationSortField.entries.forEach { field ->
                DropdownMenuItem(
                    text = { Text(field.label) },
                    leadingIcon = {
                        if (field == sortField) Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    },
                    onClick = {
                        onSetSort(field, sortDirection)
                        expanded = false
                    }
                )
            }
            HorizontalDivider()
            ConversationSortDirection.entries.forEach { dir ->
                DropdownMenuItem(
                    text = { Text(dir.label) },
                    leadingIcon = {
                        if (dir == sortDirection) Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    },
                    onClick = {
                        onSetSort(sortField, dir)
                        expanded = false
                    }
                )
            }
        }
    }
}

@Composable
private fun ModelMenuChip(
    selectedModel: String?,
    discoveredModels: List<String>,
    onSetModel: (String?) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        FacetChip(
            label = selectedModel ?: "Model",
            icon = Icons.Filled.Memory,
            active = selectedModel != null,
            enabled = discoveredModels.isNotEmpty(),
            onClick = { expanded = true }
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text("Any model") },
                leadingIcon = {
                    if (selectedModel == null) Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                },
                onClick = {
                    onSetModel(null)
                    expanded = false
                }
            )
            discoveredModels.forEach { model ->
                DropdownMenuItem(
                    text = { Text(model) },
                    leadingIcon = {
                        if (model == selectedModel) Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    },
                    onClick = {
                        onSetModel(model)
                        expanded = false
                    }
                )
            }
        }
    }
}

@Composable
private fun FacetChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    active: Boolean,
    onClick: () -> Unit,
    trailingIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    enabled: Boolean = true
) {
    val contentColor = when {
        !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
        active -> AuroraColors.ember
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    val containerColor = if (active) AuroraColors.ember.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    val borderColor = if (active) AuroraColors.ember.copy(alpha = 0.5f) else MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .background(containerColor)
            .border(0.75.dp, borderColor, RoundedCornerShape(AuroraRadius.full.dp))
            .then(if (enabled) Modifier.clickableNoRipple(onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 7.dp)
    ) {
        Icon(icon, contentDescription = null, tint = contentColor, modifier = Modifier.size(13.dp))
        Text(label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = contentColor, maxLines = 1)
        if (trailingIcon != null) {
            Icon(trailingIcon, contentDescription = null, tint = contentColor, modifier = Modifier.size(11.dp))
        }
    }
}

// ── Vault notice ──

@Composable
private fun VaultNotice() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(AuroraColors.warning.copy(alpha = 0.12f))
            .border(0.75.dp, AuroraColors.warning.copy(alpha = 0.35f), RoundedCornerShape(AuroraRadius.md.dp))
            .padding(11.dp)
    ) {
        Icon(Icons.Filled.LockReset, contentDescription = null, tint = AuroraColors.warning, modifier = Modifier.size(15.dp))
        Text(
            "Titles stay sealed until this device receives the vault key — facets, filters, and totals still work.",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// ── Row ──

@Composable
private fun CockpitConversationRowView(row: CockpitConversationRow, onClick: () -> Unit) {
    AuroraGlassCard(cornerRadius = AuroraRadius.lg, interactive = true, onClick = onClick) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            val provider = row.providerEnum
            if (provider != null) {
                ProviderAvatar(providerKey = provider.key, size = 36)
            } else {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(AuroraColors.ember.copy(alpha = 0.16f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Filled.Lock, contentDescription = null, tint = AuroraColors.ember, modifier = Modifier.size(16.dp))
                }
            }
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (!row.hasDecryptedTitle) {
                        Icon(Icons.Filled.Lock, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(10.dp))
                    }
                    Text(
                        row.displayTitle,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(
                    rowSubtitle(row),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(Formatting.formatCurrency(row.costUSD), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                Text(Formatting.formatTokens(row.totalTokens.toLong()), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!row.preview.isNullOrBlank()) {
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Text(
                row.preview!!,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
        val tags = row.toolTags.take(3)
        if (row.messageCount > 0 || (row.durationSeconds ?: 0) > 0 || tags.isNotEmpty()) {
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (row.messageCount > 0) {
                    MetaLabel(icon = Icons.Filled.ChatBubbleOutline, text = "${row.messageCount}")
                }
                row.durationSeconds?.takeIf { it > 0 }?.let {
                    MetaLabel(icon = Icons.Filled.Schedule, text = formatDuration(it))
                }
                tags.forEach { tag ->
                    Text(
                        tag,
                        fontSize = 10.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .clip(RoundedCornerShape(AuroraRadius.full.dp))
                            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.7f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                        maxLines = 1
                    )
                }
            }
        }
    }
}

@Composable
private fun MetaLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(11.dp))
        Text(text, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun rowSubtitle(row: CockpitConversationRow): String {
    val parts = mutableListOf<String>()
    row.projectName?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    row.model?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    row.activityDateMs.takeIf { it > 0 }?.let { parts.add(Formatting.formatRelativeTime(it)) }
    return parts.joinToString(" · ")
}

// ── Detail sheet ──

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CockpitConversationDetailSheet(
    store: ConversationCockpitStore,
    row: CockpitConversationRow,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var transcript by remember(row.id) { mutableStateOf<String?>(null) }
    var loadError by remember(row.id) { mutableStateOf<String?>(null) }
    var isLoading by remember(row.id) { mutableStateOf(true) }

    LaunchedEffect(row.id) {
        isLoading = true
        loadError = null
        try {
            transcript = store.loadTranscript(row)
        } catch (e: Exception) {
            loadError = e.localizedMessage ?: "Could not open transcript."
        } finally {
            isLoading = false
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.lg.dp)
                .padding(bottom = AuroraSpacing.xl.dp)
                .verticalScroll(rememberScrollState())
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                row.providerEnum?.let { ProviderAvatar(providerKey = it.key, size = 40) }
                Column(modifier = Modifier.weight(1f)) {
                    Text(row.displayTitle, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                    row.projectName?.takeIf { it.isNotBlank() }?.let {
                        Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                transcript?.takeIf { it.isNotBlank() }?.let { body ->
                    IconButton(onClick = {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/markdown"
                            putExtra(Intent.EXTRA_TEXT, buildShareMarkdown(row, body))
                            putExtra(Intent.EXTRA_SUBJECT, row.displayTitle)
                        }
                        context.startActivity(Intent.createChooser(intent, "Share conversation"))
                    }) {
                        Icon(Icons.Filled.Share, contentDescription = "Share transcript")
                    }
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

            val facets = buildList {
                add("Cost" to Formatting.formatCurrency(row.costUSD))
                add("Tokens" to Formatting.formatTokens(row.totalTokens.toLong()))
                if (row.inputTokens > 0 || row.outputTokens > 0) {
                    add("In · Out" to "${Formatting.formatTokens(row.inputTokens.toLong())} · ${Formatting.formatTokens(row.outputTokens.toLong())}")
                }
                if (row.messageCount > 0) add("Messages" to row.messageCount.toString())
                row.model?.takeIf { it.isNotBlank() }?.let { add("Model" to it) }
                row.durationSeconds?.takeIf { it > 0 }?.let { add("Duration" to formatDuration(it)) }
                (row.startTimeMs ?: row.updatedAtMs)?.takeIf { it > 0 }?.let { add("Started" to Formatting.formatRelativeTime(it)) }
                row.sourceType?.takeIf { it.isNotBlank() }?.let { add("Source" to it.replaceFirstChar { c -> c.uppercase() }) }
            }
            facets.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp), modifier = Modifier.padding(bottom = AuroraSpacing.sm.dp)) {
                    pair.forEach { (title, value) ->
                        FacetCell(title = title, value = value, modifier = Modifier.weight(1f))
                    }
                    if (pair.size == 1) Spacer(modifier = Modifier.weight(1f))
                }
            }

            row.workingDirectory?.takeIf { it.isNotBlank() }?.let { dir ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(vertical = AuroraSpacing.xs.dp)) {
                    Icon(Icons.Filled.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(13.dp))
                    Text(dir, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp))

            when {
                isLoading -> {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp), modifier = Modifier.padding(vertical = AuroraSpacing.lg.dp)) {
                        CircularProgressIndicator(color = AuroraColors.ember, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                        Text("Opening encrypted transcript…", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                loadError != null -> {
                    ErrorStateView(
                        icon = Icons.Filled.LockOpen,
                        title = "Could not open transcript",
                        message = loadError ?: "",
                        onRetry = {
                            scope.launch {
                                isLoading = true
                                loadError = null
                                try {
                                    transcript = store.loadTranscript(row)
                                } catch (e: Exception) {
                                    loadError = e.localizedMessage ?: "Could not open transcript."
                                } finally {
                                    isLoading = false
                                }
                            }
                        }
                    )
                }
                !transcript.isNullOrBlank() -> {
                    SelectionContainer {
                        Text(
                            transcript!!,
                            fontSize = 12.sp,
                            lineHeight = 17.sp,
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                else -> {
                    Text(
                        row.preview ?: "No transcript available.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun FacetCell(title: String, value: String, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        modifier = modifier
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f), RoundedCornerShape(AuroraRadius.md.dp))
            .padding(10.dp)
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text(value, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

// ── Filter sheet ──

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CockpitFilterSheet(
    projectQuery: String,
    dateFrom: Long?,
    dateTo: Long?,
    onApply: (String, Long?, Long?) -> Unit,
    onReset: () -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var projectDraft by remember { mutableStateOf(projectQuery) }
    var fromDraft by remember { mutableStateOf(dateFrom) }
    var toDraft by remember { mutableStateOf(dateTo) }
    var showRangePicker by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.lg.dp)
                .padding(bottom = AuroraSpacing.xl.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            Text("Cockpit Filters", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)

            OutlinedTextField(
                value = projectDraft,
                onValueChange = { projectDraft = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Project") },
                placeholder = { Text("Any project") },
                singleLine = true
            )

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Start date range", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                    Text(
                        if (fromDraft != null || toDraft != null)
                            "${fromDraft?.let { Formatting.formatRelativeTime(it) } ?: "Any"} → ${toDraft?.let { Formatting.formatRelativeTime(it) } ?: "Now"}"
                        else "Sorting falls back to start time when a range is set.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                TextButton(onClick = { showRangePicker = true }) { Text("Set range") }
                if (fromDraft != null || toDraft != null) {
                    TextButton(onClick = { fromDraft = null; toDraft = null }) { Text("Clear") }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(onClick = onReset, modifier = Modifier.weight(1f)) { Text("Reset") }
                Button(
                    onClick = { onApply(projectDraft.trim(), fromDraft, toDraft) },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember)
                ) { Text("Apply") }
            }
        }
    }

    if (showRangePicker) {
        val rangeState = rememberDateRangePickerState(
            initialSelectedStartDateMillis = fromDraft,
            initialSelectedEndDateMillis = toDraft
        )
        DatePickerDialog(
            onDismissRequest = { showRangePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    fromDraft = rangeState.selectedStartDateMillis
                    toDraft = rangeState.selectedEndDateMillis
                    showRangePicker = false
                }) { Text("Done") }
            },
            dismissButton = { TextButton(onClick = { showRangePicker = false }) { Text("Cancel") } }
        ) {
            DateRangePicker(state = rangeState, modifier = Modifier.heightIn(max = 480.dp))
        }
    }
}

// ── Save query dialog ──

@Composable
private fun SaveQueryDialog(onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Save query") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                Text(
                    "Recall this provider, model, project, and sort combination from the saved-query rail.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Name") },
                    singleLine = true
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank(),
                onClick = {
                    onSave(name)
                    onDismiss()
                }
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

// ── Teaser background (locked state) ──

@Composable
private fun CockpitTeaserBackground() {
    val isDark = isSystemInDarkTheme()
    val base = if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground
    val tile = if (isDark) AuroraColors.darkSurface else AuroraColors.lightSurface
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(base)
            .padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            repeat(3) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(76.dp)
                        .clip(RoundedCornerShape(AuroraRadius.lg.dp))
                        .background(tile)
                )
            }
        }
        repeat(5) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(70.dp)
                    .clip(RoundedCornerShape(AuroraRadius.lg.dp))
                    .background(tile.copy(alpha = 0.7f))
            )
        }
    }
}

// ── helpers ──

private fun formatDuration(seconds: Int): String {
    if (seconds < 60) return "${seconds}s"
    val minutes = seconds / 60
    if (minutes < 60) return "${minutes}m"
    val hours = minutes / 60
    val rem = minutes % 60
    return if (rem == 0) "${hours}h" else "${hours}h ${rem}m"
}

// Builds a shareable Markdown document (metadata header + transcript) that
// matches the iOS share sheet and the Mac bundle export.
private fun buildShareMarkdown(row: CockpitConversationRow, body: String): String = buildString {
    appendLine("# ${row.displayTitle}")
    appendLine()
    appendLine("| Property | Value |")
    appendLine("|----------|-------|")
    appendLine("| Provider | ${row.providerEnum?.displayName ?: row.provider ?: "—"} |")
    row.model?.takeIf { it.isNotBlank() }?.let { appendLine("| Model | $it |") }
    row.projectName?.takeIf { it.isNotBlank() }?.let { appendLine("| Project | $it |") }
    (row.startTimeMs ?: row.updatedAtMs)?.takeIf { it > 0 }?.let {
        appendLine("| Started | ${Formatting.formatRelativeTime(it)} |")
    }
    if (row.messageCount > 0) appendLine("| Messages | ${row.messageCount} |")
    if (row.totalTokens > 0) appendLine("| Tokens | ${Formatting.formatTokens(row.totalTokens.toLong())} |")
    if (row.costUSD > 0) appendLine("| Cost | ${Formatting.formatCurrency(row.costUSD)} |")
    row.workingDirectory?.takeIf { it.isNotBlank() }?.let { appendLine("| Working dir | `$it` |") }
    appendLine()
    appendLine("## Transcript")
    appendLine()
    append(if (body.isBlank()) "_No transcript body was available._" else body)
}

private fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier = this.then(
    Modifier.clickable(
        interactionSource = androidx.compose.foundation.interaction.MutableInteractionSource(),
        indication = null,
        onClick = onClick
    )
)
