package com.openburnbar.ui.burn

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.UserStore

internal data class BurnViewStoreState(
    val visibleSnapshots: List<ProviderQuotaSnapshot>,
    val accounts: List<ProviderAccount>,
    val isLoading: Boolean,
    val error: String?,
    val snapshotsEmpty: Boolean,
    val demoIsSeeding: Boolean,
    val demoMessage: String?,
    val demoError: String?,
    val signedInEmail: String?,
    val isSignedIn: Boolean,
    val burnStyle: BurnViewStyle,
    val hiddenBuckets: Set<String>,
    val bucketOrders: Map<String, List<String>>,
    val percentageDisplayMode: String,
    val rollups: UsageRollups?,
    val recentUsages: List<TokenUsage>,
    val quotaPrefs: QuotaPreferences,
    val ringItems: List<QuotaRingItem>,
)

internal data class BurnViewUiBindings(
    val displayMode: UsageDisplayMode,
    val onDisplayModeChange: (UsageDisplayMode) -> Unit,
    val selectedPeriod: Int,
    val periods: List<String>,
    val onSelectedPeriodChange: (Int) -> Unit,
    val openProvider: (String) -> Unit,
    val onProviderSnapshotClick: (ProviderQuotaSnapshot) -> Unit,
)

internal data class BurnViewStoreActions(
    val onRetryQuotaLoad: () -> Unit,
    val onLoadDemoData: () -> Unit,
    val onDismissDemoStatus: () -> Unit,
    val onBurnStyleChange: (BurnViewStyle) -> Unit,
)

internal data class QuotaBucketDisplayPrefs(
    val hiddenBuckets: Set<String>,
    val bucketOrders: Map<String, List<String>>,
    val percentageDisplayMode: String,
)

internal fun filterVisibleSnapshots(
    snapshots: List<ProviderQuotaSnapshot>,
    providerOrder: List<AgentProvider>,
    visibleProviders: Set<AgentProvider>,
): List<ProviderQuotaSnapshot> =
    snapshots
        .filter { snapshot ->
            val prov = AgentProvider.fromKey(snapshot.provider)
            prov != null && prov in visibleProviders
        }
        .sortedWith { lhs, rhs ->
            val lhsProv = AgentProvider.fromKey(lhs.provider)
            val rhsProv = AgentProvider.fromKey(rhs.provider)
            val lhsIdx = if (lhsProv != null) providerOrder.indexOf(lhsProv) else -1
            val rhsIdx = if (rhsProv != null) providerOrder.indexOf(rhsProv) else -1
            val lhsVal = if (lhsIdx >= 0) lhsIdx else Int.MAX_VALUE
            val rhsVal = if (rhsIdx >= 0) rhsIdx else Int.MAX_VALUE
            lhsVal.compareTo(rhsVal)
        }

@Composable
internal fun rememberBurnViewStoreState(
    quotaStore: QuotaStore,
    demoDataStore: DemoDataStore,
    dashboardStore: DashboardStore,
    activityStore: ActivityStore,
): BurnViewStoreState {
    val snapshots by quotaStore.snapshots.collectAsState()
    val accounts by quotaStore.accounts.collectAsState()
    val isLoading by quotaStore.isLoading.collectAsState()
    val error by quotaStore.error.collectAsState()
    val demoIsSeeding by demoDataStore.isSeeding.collectAsState()
    val demoMessage by demoDataStore.message.collectAsState()
    val demoError by demoDataStore.error.collectAsState()
    val userStore: UserStore = viewModel()
    val currentUser by userStore.user.collectAsState()

    val context = LocalContext.current
    val quotaPrefs = remember(context) { QuotaPreferences.get(context) }
    val providerOrder by quotaPrefs.providerOrder.collectAsState()
    val visibleProviders by quotaPrefs.visibleProviders.collectAsState()
    val hiddenBuckets by quotaPrefs.hiddenBuckets.collectAsState()
    val bucketOrders by quotaPrefs.bucketOrders.collectAsState()
    val percentageDisplayMode by quotaPrefs.percentageDisplayMode.collectAsState()
    val burnStyle = BurnViewStyle.fromKey(quotaPrefs.burnViewStyle.collectAsState().value)
    val rollups by dashboardStore.rollups.collectAsState()
    val recentUsages by activityStore.usages.collectAsState()

    val visibleSnapshots =
        remember(snapshots, providerOrder, visibleProviders) {
            filterVisibleSnapshots(snapshots, providerOrder, visibleProviders)
        }
    val ringItems = remember(visibleSnapshots) { buildQuotaRingItems(visibleSnapshots) }

    return BurnViewStoreState(
        visibleSnapshots = visibleSnapshots,
        accounts = accounts,
        isLoading = isLoading,
        error = error,
        snapshotsEmpty = snapshots.isEmpty(),
        demoIsSeeding = demoIsSeeding,
        demoMessage = demoMessage,
        demoError = demoError,
        signedInEmail = currentUser.email,
        isSignedIn = currentUser.isSignedIn,
        burnStyle = burnStyle,
        hiddenBuckets = hiddenBuckets,
        bucketOrders = bucketOrders,
        percentageDisplayMode = percentageDisplayMode,
        rollups = rollups,
        recentUsages = recentUsages,
        quotaPrefs = quotaPrefs,
        ringItems = ringItems,
    )
}
