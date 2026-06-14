// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockReset
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Numbers
import androidx.compose.material.icons.filled.Paid
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SearchOff
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.util.Formatting

internal data class EntitledCockpitListContext(
    val store: ConversationCockpitStore,
    val aggregates: ConversationQueryAggregates?,
    val rows: List<CockpitConversationRow>,
    val filteredRows: List<CockpitConversationRow>,
    val isLoading: Boolean,
    val isPaginating: Boolean,
    val error: String?,
    val vaultLocked: Boolean,
    val hasNarrowingInput: Boolean,
    val sortField: ConversationSortField,
    val sortDirection: ConversationSortDirection,
    val selectedModel: String?,
    val discoveredModels: List<String>,
    val discoveredProviders: List<String>,
    val selectedProviders: Set<String>,
    val savedQueries: List<SavedConversationQuery>,
    val hasActiveFilters: Boolean,
    val onSelectRow: (CockpitConversationRow) -> Unit,
    val onOpenFilters: () -> Unit,
    val onSaveQuery: () -> Unit,
)

internal fun cockpitFilterRows(rows: List<CockpitConversationRow>, search: String): List<CockpitConversationRow> {
    val trimmed = search.trim().lowercase()
    if (trimmed.isEmpty()) return rows
    return rows.filter { row ->
        row.title?.lowercase()?.contains(trimmed) == true ||
            row.preview?.lowercase()?.contains(trimmed) == true ||
            row.model?.lowercase()?.contains(trimmed) == true ||
            row.provider?.lowercase()?.contains(trimmed) == true
    }
}

internal fun cockpitHasActiveFilters(selectedProviders: Set<String>, selectedModel: String?, dateFrom: Long?, dateTo: Long?): Boolean =
    selectedProviders.isNotEmpty() ||
        selectedModel != null ||
        dateFrom != null ||
        dateTo != null

internal fun LazyListScope.entitledCockpitListItems(ctx: EntitledCockpitListContext) {
    item(key = "kpi") { CockpitKpiHeader(aggregates = ctx.aggregates, rows = ctx.rows) }
    item(key = "facets") {
        CockpitFacetBar(
            state =
            CockpitFacetState(
                sortField = ctx.sortField,
                sortDirection = ctx.sortDirection,
                selectedModel = ctx.selectedModel,
                discoveredModels = ctx.discoveredModels,
                discoveredProviders = ctx.discoveredProviders,
                selectedProviders = ctx.selectedProviders,
                savedQueries = ctx.savedQueries,
                hasActiveFilters = ctx.hasActiveFilters,
            ),
            callbacks =
            CockpitFacetCallbacks(
                onSetSort = { f, d -> ctx.store.filters.setSort(f, d) },
                onSetModel = { ctx.store.filters.setModel(it) },
                onToggleProvider = { ctx.store.filters.toggleProvider(it) },
                onOpenFilters = ctx.onOpenFilters,
                onSaveQuery = ctx.onSaveQuery,
                onClearFilters = { ctx.store.filters.clearFilters() },
                onApplySaved = { ctx.store.filters.applySavedQuery(it) },
                onDeleteSaved = { ctx.store.filters.deleteSavedQuery(it) },
            ),
        )
    }
    if (ctx.vaultLocked) {
        item(key = "vault") { CockpitVaultNotice() }
    }
    entitledCockpitResultItems(ctx)
}

internal fun LazyListScope.entitledCockpitResultItems(ctx: EntitledCockpitListContext) {
    when {
        ctx.isLoading && ctx.rows.isEmpty() -> items(6) { ShimmerCard(height = 86) }
        ctx.error != null && ctx.rows.isEmpty() -> {
            item {
                ErrorStateView(
                    icon = Icons.Filled.Error,
                    title = "Query failed",
                    message = ctx.error ?: "",
                    onRetry = { ctx.store.queries.runQuery(reset = true) },
                )
            }
        }
        ctx.filteredRows.isEmpty() -> {
            item {
                EmptyStateView(
                    icon = if (ctx.hasNarrowingInput) Icons.Filled.SearchOff else Icons.Filled.GridView,
                    title = if (ctx.hasNarrowingInput) "No matches" else "No conversations yet",
                    message =
                    if (ctx.hasNarrowingInput) {
                        "Adjust or clear the filters to widen your search."
                    } else {
                        "Turn on conversation backup on your Mac and every session will appear here — fully searchable, end-to-end encrypted."
                    },
                )
            }
        }
        else -> {
            items(ctx.filteredRows, key = { it.id }) { row ->
                CockpitConversationRowView(row = row, onClick = { ctx.onSelectRow(row) })
            }
            if (ctx.isPaginating) {
                item(key = "paginating") { CockpitPaginatingIndicator() }
            }
        }
    }
}

@Composable
internal fun EntitledCockpitPaginationEffect(
    listState: LazyListState,
    hasMore: Boolean,
    isPaginating: Boolean,
    isLoading: Boolean,
    store: ConversationCockpitStore,
) {
    val reachedBottom by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= listState.layoutInfo.totalItemsCount - 2 && listState.layoutInfo.totalItemsCount > 0
        }
    }
    LaunchedEffect(reachedBottom, hasMore, isPaginating, isLoading) {
        val shouldLoadNextPage = reachedBottom && hasMore && !isPaginating && !isLoading
        if (shouldLoadNextPage) {
            store.queries.loadNextPage()
        }
    }
}

@Composable
internal fun EntitledCockpitSearchField(search: String, onSearchChange: (String) -> Unit) {
    OutlinedTextField(
        value = search,
        onValueChange = onSearchChange,
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.MD.dp),
        placeholder = { Text("Filter loaded conversations…") },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        singleLine = true,
        shape = MaterialTheme.shapes.medium,
    )
}

internal data class EntitledCockpitStoreSnapshot(
    val rows: List<CockpitConversationRow>,
    val aggregates: ConversationQueryAggregates?,
    val isLoading: Boolean,
    val isPaginating: Boolean,
    val error: String?,
    val vaultLocked: Boolean,
    val hasMore: Boolean,
    val signature: String,
    val savedQueries: List<SavedConversationQuery>,
    val discoveredProviders: List<String>,
    val discoveredModels: List<String>,
    val selectedProviders: Set<String>,
    val selectedModel: String?,
    val sortField: ConversationSortField,
    val sortDirection: ConversationSortDirection,
    val dateFrom: Long?,
    val dateTo: Long?,
)

@Composable
internal fun rememberEntitledCockpitStoreSnapshot(store: ConversationCockpitStore): EntitledCockpitStoreSnapshot {
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
    return EntitledCockpitStoreSnapshot(
        rows = rows,
        aggregates = aggregates,
        isLoading = isLoading,
        isPaginating = isPaginating,
        error = error,
        vaultLocked = vaultLocked,
        hasMore = hasMore,
        signature = signature,
        savedQueries = savedQueries,
        discoveredProviders = discoveredProviders,
        discoveredModels = discoveredModels,
        selectedProviders = selectedProviders,
        selectedModel = selectedModel,
        sortField = sortField,
        sortDirection = sortDirection,
        dateFrom = dateFrom,
        dateTo = dateTo,
    )
}

@Composable
internal fun EntitledCockpit(store: ConversationCockpitStore, modifier: Modifier) {
    val snapshot = rememberEntitledCockpitStoreSnapshot(store)
    EntitledCockpitBody(store = store, snapshot = snapshot, modifier = modifier)
}

@Composable
private fun EntitledCockpitBody(store: ConversationCockpitStore, snapshot: EntitledCockpitStoreSnapshot, modifier: Modifier) {
    var search by remember { mutableStateOf("") }
    var selectedRow by remember { mutableStateOf<CockpitConversationRow?>(null) }
    var showFilters by remember { mutableStateOf(false) }
    var showSaveQuery by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()

    LaunchedEffect(snapshot.signature) { store.queries.runQuery(reset = true) }
    EntitledCockpitPaginationEffect(listState, snapshot.hasMore, snapshot.isPaginating, snapshot.isLoading, store)

    val hasActiveFilters = cockpitHasActiveFilters(
        snapshot.selectedProviders,
        snapshot.selectedModel,
        snapshot.dateFrom,
        snapshot.dateTo,
    )
    val filteredRows = cockpitFilterRows(snapshot.rows, search)
    val hasNarrowingInput = hasActiveFilters || search.trim().isNotEmpty()

    EntitledCockpitMainList(
        params =
        EntitledCockpitMainListParams(
            store,
            snapshot,
            listState,
            search,
            filteredRows,
            hasActiveFilters,
            hasNarrowingInput,
            modifier,
        ),
        callbacks =
        EntitledCockpitMainListCallbacks(
            onSearchChange = { search = it },
            onSelectRow = { selectedRow = it },
            onOpenFilters = { showFilters = true },
            onSaveQuery = { showSaveQuery = true },
        ),
    )
    EntitledCockpitOverlays(
        store = store,
        sheetState =
        EntitledCockpitOverlaySheetState(
            selectedRow,
            showFilters,
            showSaveQuery,
            snapshot.dateFrom,
            snapshot.dateTo,
        ),
        callbacks =
        EntitledCockpitOverlaySheetCallbacks(
            onDismissRow = { selectedRow = null },
            onDismissFilters = { showFilters = false },
            onDismissSaveQuery = { showSaveQuery = false },
        ),
    )
}

internal data class EntitledCockpitMainListParams(
    val store: ConversationCockpitStore,
    val snapshot: EntitledCockpitStoreSnapshot,
    val listState: LazyListState,
    val search: String,
    val filteredRows: List<CockpitConversationRow>,
    val hasActiveFilters: Boolean,
    val hasNarrowingInput: Boolean,
    val modifier: Modifier,
)

internal data class EntitledCockpitMainListCallbacks(
    val onSearchChange: (String) -> Unit,
    val onSelectRow: (CockpitConversationRow) -> Unit,
    val onOpenFilters: () -> Unit,
    val onSaveQuery: () -> Unit,
)

@Composable
private fun EntitledCockpitMainList(params: EntitledCockpitMainListParams, callbacks: EntitledCockpitMainListCallbacks) {
    val store = params.store
    val snapshot = params.snapshot
    val listState = params.listState
    val search = params.search
    val filteredRows = params.filteredRows
    val hasActiveFilters = params.hasActiveFilters
    val hasNarrowingInput = params.hasNarrowingInput
    val onSearchChange = callbacks.onSearchChange
    val onSelectRow = callbacks.onSelectRow
    val onOpenFilters = callbacks.onOpenFilters
    val onSaveQuery = callbacks.onSaveQuery
    Column(modifier = params.modifier.fillMaxSize()) {
        EntitledCockpitSearchField(search = search, onSearchChange = onSearchChange)
        Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().padding(horizontal = AuroraSpacing.MD.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
            contentPadding = PaddingValues(bottom = AuroraSpacing.XXL.dp),
        ) {
            entitledCockpitListItems(
                EntitledCockpitListContext(
                    store = store,
                    aggregates = snapshot.aggregates,
                    rows = snapshot.rows,
                    filteredRows = filteredRows,
                    isLoading = snapshot.isLoading,
                    isPaginating = snapshot.isPaginating,
                    error = snapshot.error,
                    vaultLocked = snapshot.vaultLocked,
                    hasNarrowingInput = hasNarrowingInput,
                    sortField = snapshot.sortField,
                    sortDirection = snapshot.sortDirection,
                    selectedModel = snapshot.selectedModel,
                    discoveredModels = snapshot.discoveredModels,
                    discoveredProviders = snapshot.discoveredProviders,
                    selectedProviders = snapshot.selectedProviders,
                    savedQueries = snapshot.savedQueries,
                    hasActiveFilters = hasActiveFilters,
                    onSelectRow = onSelectRow,
                    onOpenFilters = onOpenFilters,
                    onSaveQuery = onSaveQuery,
                ),
            )
        }
    }
}

// ── KPI Header ──

@Composable
internal fun CockpitKpiHeader(aggregates: ConversationQueryAggregates?, rows: List<CockpitConversationRow>) {
    val conversations = aggregates?.count ?: rows.size
    val cost = aggregates?.totalCostUSD ?: rows.sumOf { it.costUSD }
    val tokens = aggregates?.totalTokens ?: rows.sumOf { it.totalTokens.toLong() }
    val providerMix =
        remember(rows) {
            rows.asSequence()
                .filter { !it.provider.isNullOrBlank() }
                .groupBy { it.provider!! }
                .mapValues { entry -> entry.value.sumOf { it.totalTokens.toLong() } }
                .entries.sortedByDescending { it.value }
                .take(6)
        }
    val maxTokens = providerMix.maxOfOrNull { it.value }?.coerceAtLeast(1L) ?: 1L

    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        CockpitKpiTilesRow(conversations = conversations, cost = cost, tokens = tokens)
        if (providerMix.size > 1) {
            CockpitKpiProviderMixCard(providerMix = providerMix, maxTokens = maxTokens)
        }
    }
}

@Composable
private fun CockpitKpiTilesRow(conversations: Int, cost: Double, tokens: Long) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        CockpitKpiTile(
            title = "Conversations",
            value = conversations.toString(),
            icon = Icons.Filled.Forum,
            tint = AuroraColors.ember,
            modifier = Modifier.weight(1f),
        )
        CockpitKpiTile(
            title = "Total cost",
            value = Formatting.formatCurrency(cost),
            icon = Icons.Filled.Paid,
            tint = AuroraColors.teal,
            modifier = Modifier.weight(1f),
        )
        CockpitKpiTile(
            title = "Tokens",
            value = Formatting.formatTokens(tokens),
            icon = Icons.Filled.Numbers,
            tint = AuroraColors.purple,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun CockpitKpiProviderMixCard(providerMix: List<Map.Entry<String, Long>>, maxTokens: Long) {
    AuroraGlassCard(cornerRadius = AuroraRadius.LG) {
        Text(
            "TOKEN MIX · LOADED",
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.1.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
        providerMix.forEach { entry ->
            CockpitKpiProviderMixRow(entry = entry, maxTokens = maxTokens)
        }
    }
}

@Composable
private fun CockpitKpiProviderMixRow(entry: Map.Entry<String, Long>, maxTokens: Long) {
    val provider = AgentProvider.fromKey(entry.key)
    val label = provider?.displayName ?: entry.key.replaceFirstChar { it.uppercase() }
    val barColor = provider?.let { Color(it.brandColor) } ?: AuroraColors.ember
    Column(modifier = Modifier.padding(vertical = 3.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                label,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(Formatting.formatTokens(entry.value), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(modifier = Modifier.height(3.dp))
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .height(6.dp)
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), RoundedCornerShape(3.dp)),
        ) {
            Box(
                modifier =
                Modifier
                    .fillMaxWidth(fraction = (entry.value.toFloat() / maxTokens.toFloat()).coerceIn(0.02f, 1f))
                    .height(6.dp)
                    .background(barColor, RoundedCornerShape(3.dp)),
            )
        }
    }
}

@Composable
internal fun CockpitKpiTile(title: String, value: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, modifier: Modifier = Modifier) {
    AuroraGlassCard(modifier = modifier, cornerRadius = AuroraRadius.LG, contentPadding = AuroraSpacing.MD.dp) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Spacer(modifier = Modifier.height(AuroraSpacing.XS.dp))
        Text(
            value,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(title, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// ── Facet Bar ──

internal data class CockpitFacetState(
    val sortField: ConversationSortField,
    val sortDirection: ConversationSortDirection,
    val selectedModel: String?,
    val discoveredModels: List<String>,
    val discoveredProviders: List<String>,
    val selectedProviders: Set<String>,
    val savedQueries: List<SavedConversationQuery>,
    val hasActiveFilters: Boolean,
)

internal data class CockpitFacetCallbacks(
    val onSetSort: (ConversationSortField, ConversationSortDirection) -> Unit,
    val onSetModel: (String?) -> Unit,
    val onToggleProvider: (String) -> Unit,
    val onOpenFilters: () -> Unit,
    val onSaveQuery: () -> Unit,
    val onClearFilters: () -> Unit,
    val onApplySaved: (SavedConversationQuery) -> Unit,
    val onDeleteSaved: (SavedConversationQuery) -> Unit,
)

@Composable
internal fun CockpitFacetBar(state: CockpitFacetState, callbacks: CockpitFacetCallbacks) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        CockpitFacetPrimaryRow(state = state, callbacks = callbacks)
        CockpitFacetProviderChips(state = state, callbacks = callbacks)
        CockpitFacetSavedQueries(state = state, callbacks = callbacks)
    }
}

@Composable
private fun CockpitFacetPrimaryRow(state: CockpitFacetState, callbacks: CockpitFacetCallbacks) {
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        CockpitSortMenuChip(
            sortField = state.sortField,
            sortDirection = state.sortDirection,
            onSetSort = callbacks.onSetSort,
        )
        CockpitModelMenuChip(
            selectedModel = state.selectedModel,
            discoveredModels = state.discoveredModels,
            onSetModel = callbacks.onSetModel,
        )
        CockpitFacetChip(
            label = "Filters",
            icon = Icons.Filled.Tune,
            active = state.hasActiveFilters,
            onClick = callbacks.onOpenFilters,
        )
        CockpitFacetChip(label = "Save", icon = Icons.Filled.BookmarkAdd, active = false, onClick = callbacks.onSaveQuery)
        if (state.hasActiveFilters) {
            CockpitFacetChip(label = "Clear", icon = Icons.Filled.Cancel, active = false, onClick = callbacks.onClearFilters)
        }
    }
}

@Composable
private fun CockpitFacetProviderChips(state: CockpitFacetState, callbacks: CockpitFacetCallbacks) {
    if (state.discoveredProviders.isEmpty()) return
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        state.discoveredProviders.forEach { provider ->
            val active = state.selectedProviders.contains(provider)
            val enumProvider = AgentProvider.fromKey(provider)
            val dotColor = enumProvider?.let { Color(it.brandColor) }
            FilterChip(
                selected = active,
                onClick = { callbacks.onToggleProvider(provider) },
                label = {
                    Text(
                        enumProvider?.displayName ?: provider.replaceFirstChar { it.uppercase() },
                        fontSize = 11.sp,
                        maxLines = 1,
                    )
                },
                leadingIcon =
                dotColor?.let {
                    {
                        Box(
                            modifier =
                            Modifier
                                .size(8.dp)
                                .background(it, RoundedCornerShape(4.dp)),
                        )
                    }
                },
            )
        }
    }
}

@Composable
private fun CockpitFacetSavedQueries(state: CockpitFacetState, callbacks: CockpitFacetCallbacks) {
    if (state.savedQueries.isEmpty()) return
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        state.savedQueries.forEach { query ->
            InputChip(
                selected = false,
                onClick = { callbacks.onApplySaved(query) },
                label = { Text(query.name, fontSize = 11.sp, maxLines = 1) },
                leadingIcon = { Icon(Icons.Filled.Bookmark, contentDescription = null, modifier = Modifier.size(14.dp)) },
                trailingIcon = {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Delete saved query",
                        modifier =
                        Modifier
                            .size(16.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .cockpitClickableNoRipple { callbacks.onDeleteSaved(query) },
                    )
                },
            )
        }
    }
}

@Composable
internal fun CockpitSortMenuChip(
    sortField: ConversationSortField,
    sortDirection: ConversationSortDirection,
    onSetSort: (ConversationSortField, ConversationSortDirection) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        CockpitFacetChip(
            label = sortField.label,
            icon = Icons.Filled.SwapVert,
            trailingIcon = if (sortDirection == ConversationSortDirection.DESC) Icons.Filled.ArrowDownward else Icons.Filled.ArrowUpward,
            active = true,
            onClick = { expanded = true },
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
                    },
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
                    },
                )
            }
        }
    }
}

@Composable
internal fun CockpitModelMenuChip(selectedModel: String?, discoveredModels: List<String>, onSetModel: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        CockpitFacetChip(
            label = selectedModel ?: "Model",
            icon = Icons.Filled.Memory,
            active = selectedModel != null,
            enabled = discoveredModels.isNotEmpty(),
            onClick = { expanded = true },
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
                },
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
                    },
                )
            }
        }
    }
}

@Composable
internal fun CockpitFacetChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    active: Boolean,
    onClick: () -> Unit,
    trailingIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    enabled: Boolean = true,
) {
    val contentColor =
        when {
            !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
            active -> AuroraColors.ember
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        }
    val containerColor = if (active) AuroraColors.ember.copy(alpha = 0.16f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    val borderColor = if (active) AuroraColors.ember.copy(alpha = 0.5f) else MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier =
        Modifier
            .clip(RoundedCornerShape(AuroraRadius.FULL.dp))
            .background(containerColor)
            .border(0.75.dp, borderColor, RoundedCornerShape(AuroraRadius.FULL.dp))
            .then(if (enabled) Modifier.cockpitClickableNoRipple(onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 7.dp),
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
internal fun CockpitVaultNotice() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.MD.dp))
            .background(AuroraColors.warning.copy(alpha = 0.12f))
            .border(0.75.dp, AuroraColors.warning.copy(alpha = 0.35f), RoundedCornerShape(AuroraRadius.MD.dp))
            .padding(11.dp),
    ) {
        Icon(Icons.Filled.LockReset, contentDescription = null, tint = AuroraColors.warning, modifier = Modifier.size(15.dp))
        Text(
            "Titles stay sealed until this device receives the vault key — facets, filters, and totals still work.",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ── Row ──

@Composable
internal fun CockpitConversationRowView(row: CockpitConversationRow, onClick: () -> Unit) {
    AuroraGlassCard(cornerRadius = AuroraRadius.LG, interactive = true, onClick = onClick) {
        CockpitConversationRowHeader(row = row)
        if (!row.preview.isNullOrBlank()) {
            Spacer(modifier = Modifier.height(AuroraSpacing.XS.dp))
            Text(
                row.preview!!,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        CockpitConversationRowMeta(row = row)
    }
}

@Composable
private fun CockpitConversationRowHeader(row: CockpitConversationRow) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        val provider = row.providerEnum
        if (provider != null) {
            ProviderAvatar(providerKey = provider.key, size = 36)
        } else {
            Box(
                modifier =
                Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(AuroraColors.ember.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
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
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                cockpitRowSubtitle(row),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(Formatting.formatCurrency(row.costUSD), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Text(Formatting.formatTokens(row.totalTokens.toLong()), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun CockpitConversationRowMeta(row: CockpitConversationRow) {
    val tags = row.toolTags.take(3)
    if (row.messageCount <= 0 && row.durationSeconds ?: 0 <= 0 && tags.isEmpty()) return
    Spacer(modifier = Modifier.height(AuroraSpacing.XS.dp))
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (row.messageCount > 0) {
            CockpitMetaLabel(icon = Icons.Filled.ChatBubbleOutline, text = "${row.messageCount}")
        }
        row.durationSeconds?.takeIf { it > 0 }?.let {
            CockpitMetaLabel(icon = Icons.Filled.Schedule, text = cockpitFormatDuration(it))
        }
        tags.forEach { tag ->
            Text(
                tag,
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier =
                Modifier
                    .clip(RoundedCornerShape(AuroraRadius.FULL.dp))
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.7f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
                maxLines = 1,
            )
        }
    }
}

@Composable
internal fun CockpitMetaLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(11.dp))
        Text(text, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

internal fun cockpitRowSubtitle(row: CockpitConversationRow): String {
    val parts = mutableListOf<String>()
    row.model?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    row.activityDateMs.takeIf { it > 0 }?.let { parts.add(Formatting.formatRelativeTime(it)) }
    return parts.joinToString(" · ")
}
