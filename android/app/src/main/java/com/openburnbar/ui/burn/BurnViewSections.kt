package com.openburnbar.ui.burn

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.isDisplayableQuotaSignal
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.ui.components.DemoDataEmptyState
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

/** Redesigned top-level screen driven by state, aligned with iOS layout choices. */
@Composable
internal fun BurnViewContent(quotaStore: QuotaStore, demoDataStore: DemoDataStore, dashboardStore: DashboardStore, activityStore: ActivityStore) {
    val store = rememberBurnViewStoreState(quotaStore, demoDataStore, dashboardStore, activityStore)
    val context = LocalContext.current
    var selectedProvider by remember { mutableStateOf<AgentProvider?>(null) }
    var sortMode by remember { mutableStateOf(QuotaSortMode.URGENCY) }
    var showInactive by remember { mutableStateOf(false) }

    LaunchedEffect(store.isSignedIn) {
        if (store.isSignedIn) {
            quotaStore.load()
            dashboardStore.load()
            activityStore.loadInitial(pageSize = 250)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        when {
            store.isLoading && store.snapshotsEmpty -> BurnViewLoadingShimmer()
            store.error != null && store.snapshotsEmpty ->
                ErrorStateView(
                    icon = Icons.Filled.Warning,
                    title = "Couldn't Load Quota",
                    message = store.error,
                    onRetry = { quotaStore.load() },
                )
            !store.isLoading && store.snapshotsEmpty ->
                DemoDataEmptyState(
                    isLoading = store.demoIsSeeding,
                    message = store.demoMessage,
                    error = store.demoError,
                    onLoadDemoData = { demoDataStore.seed { quotaStore.refresh() } },
                    onDismissStatus = { demoDataStore.clearStatus() },
                )
            else ->
                BurnViewLoadedContent(
                    input = BurnViewLoadedInput(
                        store = store,
                        quotaStore = quotaStore,
                        selectedProvider = selectedProvider,
                        sortMode = sortMode,
                        showInactive = showInactive,
                        context = context,
                    ),
                    selectionCallbacks = BurnViewSelectionCallbacks(
                        onSelectedProviderChange = { selectedProvider = it },
                        onSortModeChange = { sortMode = it },
                        onShowInactiveChange = { showInactive = it },
                    ),
                )
        }
    }
}

private data class BurnViewPresentation(
    val sortedSnapshots: List<ProviderQuotaSnapshot>,
    val filteredSnapshots: List<ProviderQuotaSnapshot>,
    val setupSlots: List<AgentProvider>,
    val totalProviderCount: Int,
    val pinnedKeys: Set<String>,
)

private data class BurnViewLoadedCallbacks(
    val onSelectedProviderChange: (AgentProvider?) -> Unit,
    val onSortModeChange: (QuotaSortMode) -> Unit,
    val onShowInactiveChange: (Boolean) -> Unit,
    val onPinnedKeysChange: (Set<String>) -> Unit,
    val onRefreshAll: () -> Unit,
    val onOpenUrl: (String) -> Unit,
)

private data class BurnViewLoadedInput(
    val store: BurnViewStoreState,
    val quotaStore: QuotaStore,
    val selectedProvider: AgentProvider?,
    val sortMode: QuotaSortMode,
    val showInactive: Boolean,
    val context: Context,
)

private data class BurnViewSelectionCallbacks(
    val onSelectedProviderChange: (AgentProvider?) -> Unit,
    val onSortModeChange: (QuotaSortMode) -> Unit,
    val onShowInactiveChange: (Boolean) -> Unit,
)

private data class BurnViewLoadedColumnState(
    val store: BurnViewStoreState,
    val presentation: BurnViewPresentation,
    val selectedProvider: AgentProvider?,
    val sortMode: QuotaSortMode,
    val showInactive: Boolean,
    val sharedPrefs: android.content.SharedPreferences,
)

@Composable
private fun BurnViewLoadedContent(input: BurnViewLoadedInput, selectionCallbacks: BurnViewSelectionCallbacks) {
    val sharedPrefs = remember { input.context.getSharedPreferences("burnbar_quota_prefs", Context.MODE_PRIVATE) }
    var pinnedKeys by remember { mutableStateOf(sharedPrefs.getStringSet("pinned_quotas", emptySet()) ?: emptySet()) }
    val presentation = rememberBurnViewPresentation(input.store, input.selectedProvider, input.sortMode, input.showInactive, pinnedKeys)
    val callbacks =
        BurnViewLoadedCallbacks(
            onSelectedProviderChange = selectionCallbacks.onSelectedProviderChange,
            onSortModeChange = selectionCallbacks.onSortModeChange,
            onShowInactiveChange = selectionCallbacks.onShowInactiveChange,
            onPinnedKeysChange = { pinnedKeys = it },
            onRefreshAll = { input.quotaStore.refresh() },
            onOpenUrl = { openBurnViewUrl(input.context, it) },
        )

    BurnViewLoadedColumn(
        state = BurnViewLoadedColumnState(
            store = input.store,
            presentation = presentation,
            selectedProvider = input.selectedProvider,
            sortMode = input.sortMode,
            showInactive = input.showInactive,
            sharedPrefs = sharedPrefs,
        ),
        callbacks = callbacks,
    )
}

@Composable
private fun rememberBurnViewPresentation(
    store: BurnViewStoreState,
    selectedProvider: AgentProvider?,
    sortMode: QuotaSortMode,
    showInactive: Boolean,
    pinnedKeys: Set<String>,
): BurnViewPresentation {
    val displayableSnapshots = remember(store.visibleSnapshots, showInactive) {
        store.visibleSnapshots.filter { showInactive || it.buckets.any { bucket -> bucket.isDisplayableQuotaSignal() } }
    }
    val sortedSnapshots = remember(displayableSnapshots, sortMode, store.rollups, pinnedKeys) {
        sortQuotaSnapshots(displayableSnapshots, sortMode, store.rollups, pinnedKeys)
    }
    val filteredSnapshots = remember(sortedSnapshots, selectedProvider) {
        selectedProvider?.let { provider -> sortedSnapshots.filter { AgentProvider.fromKey(it.provider) == provider } } ?: sortedSnapshots
    }
    val setupSlots = rememberBurnViewSetupSlots(store.visibleSnapshots)
    return BurnViewPresentation(
        sortedSnapshots = sortedSnapshots,
        filteredSnapshots = filteredSnapshots,
        setupSlots = setupSlots,
        totalProviderCount = sortedSnapshots.map { it.provider }.distinct().size,
        pinnedKeys = pinnedKeys,
    )
}

@Composable
private fun rememberBurnViewSetupSlots(snapshots: List<ProviderQuotaSnapshot>): List<AgentProvider> {
    val takenProviders = remember(snapshots) { snapshots.mapNotNull { AgentProvider.fromKey(it.provider) }.toSet() }
    return remember(takenProviders) { AgentProvider.entries.filter { !takenProviders.contains(it) } }
}

@Composable
private fun BurnViewLoadedColumn(state: BurnViewLoadedColumnState, callbacks: BurnViewLoadedCallbacks) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.linearGradient(listOf(AuroraColors.ember.copy(alpha = 0.03f), Color.Transparent, AuroraColors.amber.copy(alpha = 0.02f))))
            .verticalScroll(rememberScrollState())
            .padding(bottom = AuroraSpacing.XXL.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        BurnViewHeroSection(state.presentation, state.selectedProvider, callbacks)
        BurnViewFilterSection(state.store, state.sortMode, state.showInactive, callbacks)
        BurnViewFocusBanner(state.presentation, state.selectedProvider, callbacks.onSelectedProviderChange)
        BurnViewQuotaResults(state.store, state.presentation, state.sharedPrefs, callbacks)
        if (state.presentation.filteredSnapshots.isNotEmpty()) QuotaResetAtlas(snapshots = state.presentation.filteredSnapshots)
        if (state.showInactive && state.presentation.setupSlots.isNotEmpty()) {
            QuotaSetupSuggestionsStrip(slots = state.presentation.setupSlots, onConnectClick = { /* Connect action */ })
        }
    }
}

@Composable
private fun BurnViewHeroSection(presentation: BurnViewPresentation, selectedProvider: AgentProvider?, callbacks: BurnViewLoadedCallbacks) {
    SubscriptionConstellationHero(
        snapshots = presentation.sortedSnapshots,
        selectedProvider = selectedProvider,
        onOrbTap = { provider -> callbacks.onSelectedProviderChange(if (selectedProvider == provider) null else provider) },
        onClearSelection = { callbacks.onSelectedProviderChange(null) },
    )
}

@Composable
private fun BurnViewFilterSection(store: BurnViewStoreState, sortMode: QuotaSortMode, showInactive: Boolean, callbacks: BurnViewLoadedCallbacks) {
    QuotaFilterRail(
        state = QuotaFilterRailState(
            viewMode = store.burnStyle,
            sort = sortMode,
            showInactive = showInactive,
            isRefreshing = store.isLoading,
        ),
        actions = QuotaFilterRailActions(
            onViewModeChange = { store.quotaPrefs.setBurnViewStyle(it.key) },
            onSortChange = callbacks.onSortModeChange,
            onShowInactiveChange = callbacks.onShowInactiveChange,
            onRefreshAll = callbacks.onRefreshAll,
        ),
    )
}

@Composable
private fun BurnViewFocusBanner(presentation: BurnViewPresentation, selectedProvider: AgentProvider?, onSelectedProviderChange: (AgentProvider?) -> Unit) {
    selectedProvider?.let { focusedProvider ->
        ProviderFocusBanner(
            provider = focusedProvider,
            accountCount = presentation.filteredSnapshots.size,
            totalProviderCount = presentation.totalProviderCount,
            onClearSelection = { onSelectedProviderChange(null) },
        )
    }
}

@Composable
private fun BurnViewQuotaResults(
    store: BurnViewStoreState,
    presentation: BurnViewPresentation,
    sharedPrefs: android.content.SharedPreferences,
    callbacks: BurnViewLoadedCallbacks,
) {
    when {
        presentation.filteredSnapshots.isEmpty() -> BurnViewEmptyFocus()
        store.burnStyle == BurnViewStyle.LIST -> BurnViewListRows(store, presentation.filteredSnapshots)
        else -> BurnViewCards(store, presentation, sharedPrefs, callbacks)
    }
}

@Composable
private fun BurnViewEmptyFocus() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = AuroraSpacing.XL.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = "No active plans found for focus.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun BurnViewListRows(store: BurnViewStoreState, snapshots: List<ProviderQuotaSnapshot>) {
    Column(
        modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        snapshots.forEach { snapshot ->
            SubscriptionListRow(snapshot = snapshot, accounts = store.accounts)
        }
    }
}

@Composable
private fun BurnViewCards(
    store: BurnViewStoreState,
    presentation: BurnViewPresentation,
    sharedPrefs: android.content.SharedPreferences,
    callbacks: BurnViewLoadedCallbacks,
) {
    Column(
        modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp),
    ) {
        presentation.filteredSnapshots.forEach { snapshot ->
            val snapshotKey = snapshot.quotaSortKey()
            SubscriptionCard(
                state = SubscriptionCardState(
                    snapshot = snapshot,
                    accounts = store.accounts,
                    signedInEmail = store.signedInEmail,
                    isPinned = presentation.pinnedKeys.contains(snapshotKey),
                ),
                actions = SubscriptionCardActions(
                    onRefresh = callbacks.onRefreshAll,
                    onTogglePin = { pin -> callbacks.updatePinnedKeys(sharedPrefs, presentation.pinnedKeys, snapshotKey, pin) },
                    onOpenDetail = { callbacks.onOpenUrl(snapshot.managementUrl ?: "") },
                ),
            )
        }
    }
}

private fun BurnViewLoadedCallbacks.updatePinnedKeys(
    sharedPrefs: android.content.SharedPreferences,
    pinnedKeys: Set<String>,
    snapshotKey: String,
    pin: Boolean,
) {
    val newPinned = if (pin) pinnedKeys + snapshotKey else pinnedKeys - snapshotKey
    sharedPrefs.edit().putStringSet("pinned_quotas", newPinned).apply()
    onPinnedKeysChange(newPinned)
}

private fun openBurnViewUrl(context: Context, url: String) {
    runCatching {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }
}
