@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.burn

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.ProviderQuotaUnit
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.models.customizedBuckets
import com.openburnbar.data.models.displayRemainingPercent
import com.openburnbar.data.models.isStale
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.data.stores.rememberQuotaDefaultWindow
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ChipSelector
import com.openburnbar.ui.components.DemoDataEmptyState
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.components.ShimmerCard
import com.openburnbar.ui.components.StaggeredEntrance
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting
import kotlin.math.roundToInt

@Composable
internal fun BurnViewContent(
    quotaStore: QuotaStore,
    demoDataStore: DemoDataStore,
    dashboardStore: DashboardStore,
    activityStore: ActivityStore,
) {
    val store = rememberBurnViewStoreState(quotaStore, demoDataStore, dashboardStore, activityStore)
    var detailSnapshot by remember { mutableStateOf<ProviderQuotaSnapshot?>(null) }
    var displayMode by remember { mutableStateOf(UsageDisplayMode.CURRENCY) }
    var selectedPeriod by remember { mutableIntStateOf(0) }
    val periods = listOf("Today", "Week", "Month")
    val ui =
        BurnViewUiBindings(
            displayMode = displayMode,
            onDisplayModeChange = { displayMode = it },
            selectedPeriod = selectedPeriod,
            periods = periods,
            onSelectedPeriodChange = { selectedPeriod = it },
            openProvider = { key ->
                detailSnapshot =
                    store.visibleSnapshots.firstOrNull { snap ->
                        snap.provider == key || AgentProvider.fromKey(snap.provider) == AgentProvider.fromKey(key)
                    }
            },
            onProviderSnapshotClick = { detailSnapshot = it },
        )
    val actions =
        BurnViewStoreActions(
            onRetryQuotaLoad = { quotaStore.load() },
            onLoadDemoData = { demoDataStore.seed { quotaStore.refresh() } },
            onDismissDemoStatus = { demoDataStore.clearStatus() },
            onBurnStyleChange = { store.quotaPrefs.setBurnViewStyle(it.key) },
        )

    LaunchedEffect(store.isSignedIn) {
        if (store.isSignedIn) {
            quotaStore.load()
            dashboardStore.load()
            activityStore.loadInitial(pageSize = 250)
        }
    }

    detailSnapshot?.let { snapshot ->
        ProviderDetailDialog(
            snapshot = snapshot,
            accounts = matchingQuotaAccounts(snapshot, store.accounts),
            signedInEmail = store.signedInEmail,
            onDismiss = { detailSnapshot = null },
        )
    }

    BurnViewScreen(store = store, ui = ui, actions = actions)
}

@Composable
internal fun BurnViewScreen(
    store: BurnViewStoreState,
    ui: BurnViewUiBindings,
    actions: BurnViewStoreActions,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        when {
            store.isLoading && store.snapshotsEmpty -> BurnViewLoadingShimmer()
            store.error != null && store.snapshotsEmpty ->
                ErrorStateView(
                    icon = Icons.Filled.Error,
                    title = "Couldn't Load Quota",
                    message = store.error,
                    onRetry = actions.onRetryQuotaLoad,
                )
            !store.isLoading && store.snapshotsEmpty ->
                DemoDataEmptyState(
                    isLoading = store.demoIsSeeding,
                    message = store.demoMessage,
                    error = store.demoError,
                    onLoadDemoData = actions.onLoadDemoData,
                    onDismissStatus = actions.onDismissDemoStatus,
                )
            else -> BurnViewScrollContent(store = store, ui = ui, actions = actions)
        }
    }
}

@Composable
private fun BurnViewLoadingShimmer() {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        ShimmerCard(height = 220)
        ShimmerCard(height = 100)
        repeat(3) { ShimmerCard(height = 80) }
    }
}

@Composable
private fun BurnViewScrollContent(
    store: BurnViewStoreState,
    ui: BurnViewUiBindings,
    actions: BurnViewStoreActions,
) {
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = AuroraSpacing.xxl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        BurnViewHeroSection(
            visibleSnapshots = store.visibleSnapshots,
            displayMode = ui.displayMode,
            onDisplayModeChange = ui.onDisplayModeChange,
            onProviderSnapshotClick = ui.onProviderSnapshotClick,
        )
        BurnViewSelectorSection(
            selectedPeriod = ui.selectedPeriod,
            periods = ui.periods,
            onSelectedPeriodChange = ui.onSelectedPeriodChange,
            burnStyle = store.burnStyle,
            onBurnStyleChange = actions.onBurnStyleChange,
        )
        BurnViewStyleSection(store = store, ui = ui)
    }
}

@Composable
private fun BurnViewHeroSection(
    visibleSnapshots: List<ProviderQuotaSnapshot>,
    displayMode: UsageDisplayMode,
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
    onProviderSnapshotClick: (ProviderQuotaSnapshot) -> Unit,
) {
    StaggeredEntrance(delay = 0) {
        FleetHealthRing(
            snapshots = visibleSnapshots,
            modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.lg.dp),
        )
    }

    StaggeredEntrance(delay = 50) {
        ChipSelector(
            items = UsageDisplayMode.entries.toList(),
            selected = displayMode,
            onSelect = onDisplayModeChange,
            labelProvider = { it.label },
            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        )
    }

    val urgent = visibleSnapshots.filter { it.percentageRemaining <= 25 }
    if (urgent.isNotEmpty()) {
        StaggeredEntrance(delay = 75) {
            UrgentBanner(
                count = urgent.size,
                modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
            )
        }
    }

    StaggeredEntrance(delay = 100) {
        ProviderRingStrip(
            snapshots = visibleSnapshots,
            onProviderClick = onProviderSnapshotClick,
            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        )
    }
}

@Composable
private fun BurnViewSelectorSection(
    selectedPeriod: Int,
    periods: List<String>,
    onSelectedPeriodChange: (Int) -> Unit,
    burnStyle: BurnViewStyle,
    onBurnStyleChange: (BurnViewStyle) -> Unit,
) {
    StaggeredEntrance(delay = 125) {
        ChipSelector(
            items = periods,
            selected = periods[selectedPeriod],
            onSelect = { onSelectedPeriodChange(periods.indexOf(it)) },
            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        )
    }

    StaggeredEntrance(delay = 140) {
        ChipSelector(
            items = BurnViewStyle.entries.toList(),
            selected = burnStyle,
            onSelect = onBurnStyleChange,
            labelProvider = { it.label },
            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        )
    }
}

@Composable
private fun BurnViewStyleSection(
    store: BurnViewStoreState,
    ui: BurnViewUiBindings,
) {
    val padH = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
    when (store.burnStyle) {
        BurnViewStyle.CARDS ->
            BurnViewCardsStyleSection(
                store = store,
                onProviderSnapshotClick = ui.onProviderSnapshotClick,
                modifier = padH,
            )
        BurnViewStyle.CONSTELLATION ->
            StaggeredEntrance(delay = 150) {
                BurnConstellationBody(items = store.ringItems, onProviderClick = ui.openProvider, modifier = padH)
            }
        BurnViewStyle.GRID ->
            StaggeredEntrance(delay = 150) {
                BurnGaugeGridBody(items = store.ringItems, onProviderClick = ui.openProvider, modifier = padH)
            }
        BurnViewStyle.LEADERBOARD ->
            StaggeredEntrance(delay = 150) {
                BurnLeaderboardBody(
                    summaries = store.rollups?.providerSummaries ?: emptyList(),
                    quotaItems = store.ringItems,
                    displayMode = ui.displayMode,
                    onProviderClick = ui.openProvider,
                    modifier = padH,
                )
            }
        BurnViewStyle.TIMELINE -> BurnViewTimelineStyleSection(store = store, ui = ui, modifier = padH)
    }
}

@Composable
private fun BurnViewTimelineStyleSection(
    store: BurnViewStoreState,
    ui: BurnViewUiBindings,
    modifier: Modifier = Modifier,
) {
    StaggeredEntrance(delay = 150) {
        val digest =
            remember(store.rollups, store.recentUsages, ui.displayMode) {
                TrendDataDigest.build(
                    rollups = store.rollups ?: UsageRollups(),
                    recentUsages = store.recentUsages,
                    displayMode = ui.displayMode,
                )
            }
        BurnTimelineBody(
            digest = digest,
            displayMode = ui.displayMode,
            onProviderClick = ui.openProvider,
            modifier = modifier,
        )
    }
}

@Composable
private fun BurnViewCardsStyleSection(
    store: BurnViewStoreState,
    onProviderSnapshotClick: (ProviderQuotaSnapshot) -> Unit,
    modifier: Modifier = Modifier,
) {
    StaggeredEntrance(delay = 150) {
        DefaultWindowSelector(modifier = modifier)
    }
    store.visibleSnapshots.forEachIndexed { index, snapshot ->
        StaggeredEntrance(delay = 160 + index * 25) {
            ProviderAccordionCard(
                snapshot = snapshot,
                accounts = matchingQuotaAccounts(snapshot, store.accounts),
                signedInEmail = store.signedInEmail,
                onOpenDetail = { onProviderSnapshotClick(snapshot) },
                bucketPrefs =
                QuotaBucketDisplayPrefs(
                    hiddenBuckets = store.hiddenBuckets,
                    bucketOrders = store.bucketOrders,
                    percentageDisplayMode = store.percentageDisplayMode,
                ),
                modifier = modifier,
            )
        }
    }
}

// ── Provider Detail Dialog ──

@Composable
fun ProviderDetailDialog(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    signedInEmail: String?,
    onDismiss: () -> Unit,
) {
    val provider = AgentProvider.fromKey(snapshot.provider)
    val accountName = quotaAccountName(snapshot, accounts)
    val accountEmail = quotaAccountEmail(snapshot, accounts, signedInEmail)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ProviderAvatar(providerKey = snapshot.provider, size = 32)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(provider?.displayName ?: snapshot.provider, fontWeight = FontWeight.Bold)
            }
        },
        text = {
            ProviderDetailDialogBody(
                snapshot = snapshot,
                accounts = accounts,
                accountName = accountName,
                accountEmail = accountEmail,
            )
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
private fun ProviderDetailDialogBody(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    accountName: String,
    accountEmail: String?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
        ProviderDetailQuotaSummaryCard(
            snapshot = snapshot,
            accountName = accountName,
            accountEmail = accountEmail,
        )
        ProviderDetailAssociatedAccountsSection(
            snapshot = snapshot,
            accounts = accounts,
            accountName = accountName,
            accountEmail = accountEmail,
        )
    }
}

@Composable
private fun ProviderDetailQuotaSummaryCard(
    snapshot: ProviderQuotaSnapshot,
    accountName: String,
    accountEmail: String?,
) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            detailRow("Quota Limit", Formatting.formatTokens(snapshot.quotaLimit.toInt()))
            detailRow("Used", Formatting.formatTokens((snapshot.quotaLimit - snapshot.quotaRemaining).toInt()))
            detailRow("Remaining", Formatting.formatTokens(snapshot.quotaRemaining.toInt()))
            detailRow("% Remaining", "${snapshot.percentageRemaining.roundToInt()}%")
            if (!accountName.equals("Account", ignoreCase = true)) {
                detailRow("Account", accountName)
            }
            detailRow("Email", accountEmail ?: "Not provided")
            detailRow("Status", if (snapshot.isUnlimited) "Unlimited" else "Limited")
        }
    }
}

@Composable
private fun ProviderDetailAssociatedAccountsSection(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    accountName: String,
    accountEmail: String?,
) {
    if (accounts.isEmpty() && accountEmail == null && snapshot.accountId == null) return

    Text("Associated Account", fontWeight = FontWeight.Bold, fontSize = AuroraTypography.caption.sp)
    if (accounts.isEmpty()) {
        ProviderDetailFallbackAccountCard(
            snapshot = snapshot,
            accountName = accountName,
            accountEmail = accountEmail,
        )
    }
    accounts.forEach { account ->
        ProviderDetailAccountCard(account = account)
    }
}

@Composable
private fun ProviderDetailFallbackAccountCard(
    snapshot: ProviderQuotaSnapshot,
    accountName: String,
    accountEmail: String?,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
            Text(accountEmail ?: accountName, fontWeight = FontWeight.Medium)
            accountEmail?.let { detailRow("Email", it) }
            snapshot.accountId?.let { detailRow("Account ID", it) }
        }
    }
}

@Composable
private fun ProviderDetailAccountCard(account: ProviderAccount) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
            Text(account.label.ifEmpty { account.providerId }, fontWeight = FontWeight.Medium)
            account.identityHint?.let { detailRow("Email", it) }
            if (account.identityHint == null && account.label.contains("@")) {
                detailRow("Email", account.label)
            }
            detailRow(
                "Usage",
                "${Formatting.formatTokens(account.usageUsed.toInt())} / ${Formatting.formatTokens(account.usageLimit.toInt())}",
            )
            account.integration?.let { detailRow("Integration", it) }
            account.status?.let { detailRow("Status", it) }
        }
    }
}

@Composable
private fun detailRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.Medium)
    }
}

// ── Fleet Health Ring ──

@Composable
fun FleetHealthRing(snapshots: List<ProviderQuotaSnapshot>, modifier: Modifier = Modifier) {
    val avgRaw =
        if (snapshots.isNotEmpty()) {
            snapshots.sumOf { it.percentageRemaining } / snapshots.size
        } else {
            100.0
        }
    val pct = avgRaw.coerceIn(0.0, 100.0).toFloat()
    val urgent = snapshots.count { it.percentageRemaining < 25.0 }
    val (statusColor, statusLabel) =
        when {
            pct < 25f -> AuroraColors.error to "Critical"
            pct < 50f -> AuroraColors.warning to "Strained"
            pct < 75f -> AuroraColors.amber to "Healthy"
            else -> AuroraColors.success to "Excellent"
        }
    val sweepProgress by animateFloatAsState(
        targetValue = pct / 100f,
        animationSpec = tween(durationMillis = 900, easing = FastOutSlowInEasing),
        label = "fleet-ring",
    )

    AuroraGlassCard(
        modifier = modifier,
        cornerRadius = AuroraRadius.xl,
    ) {
        FleetHealthRingHeader(pct = pct, statusLabel = statusLabel)
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        FleetHealthRingBody(
            sweepProgress = sweepProgress,
            statusColor = statusColor,
            pct = pct,
            providerCount = snapshots.size,
            urgentCount = urgent,
        )
    }
}

@Composable
private fun FleetHealthRingHeader(pct: Float, statusLabel: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "FLEET HEALTH",
            fontWeight = FontWeight.SemiBold,
            fontSize = AuroraTypography.tiny.sp,
            letterSpacing = 1.6.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        AuroraBadge(
            text = statusLabel,
            tone =
            when {
                pct < 25f -> AuroraBadgeTone.Error
                pct < 50f -> AuroraBadgeTone.Warning
                pct < 75f -> AuroraBadgeTone.Accent
                else -> AuroraBadgeTone.Success
            },
        )
    }
}

@Composable
private fun FleetHealthRingBody(
    sweepProgress: Float,
    statusColor: Color,
    pct: Float,
    providerCount: Int,
    urgentCount: Int,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        FleetRingCanvas(
            progress = sweepProgress,
            accent = statusColor,
            modifier = Modifier.size(132.dp),
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "${pct.roundToInt()}% remaining",
                fontSize = AuroraTypography.title.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text =
                "$providerCount provider${if (providerCount == 1) "" else "s"}" +
                    if (urgentCount > 0) " · $urgentCount under pressure" else " · all healthy",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun FleetRingCanvas(progress: Float, accent: Color, modifier: Modifier = Modifier) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        FleetRingCanvasDraw(progress = progress, accent = accent)
        FleetRingCenterLabel(progress = progress)
    }
}

@Composable
private fun FleetRingCanvasDraw(progress: Float, accent: Color) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val stroke = size.minDimension * 0.10f
        val inset = stroke / 2f
        val arcSize = Size(size.width - stroke, size.height - stroke)
        val topLeft = Offset(inset, inset)

        drawCircle(
            brush =
            Brush.radialGradient(
                colors = listOf(accent.copy(alpha = 0.16f), Color.Transparent),
                radius = size.minDimension * 0.55f,
            ),
            radius = size.minDimension * 0.5f,
            center = Offset(size.width / 2f, size.height / 2f),
        )

        drawArc(
            color = accent.copy(alpha = 0.16f),
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            size = arcSize,
            topLeft = topLeft,
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )

        val sweep = progress.coerceIn(0f, 1f) * 360f
        if (sweep > 0f) {
            drawArc(
                brush =
                Brush.sweepGradient(
                    colors =
                    listOf(
                        accent.copy(alpha = 0.65f),
                        accent,
                        accent.copy(alpha = 0.85f),
                        accent.copy(alpha = 0.65f),
                    ),
                    center = Offset(size.width / 2f, size.height / 2f),
                ),
                startAngle = -90f,
                sweepAngle = sweep,
                useCenter = false,
                size = arcSize,
                topLeft = topLeft,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
    }
}

@Composable
private fun FleetRingCenterLabel(progress: Float) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "${(progress * 100f).toInt()}%",
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = "avg.",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun ProviderAccordionCard(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    signedInEmail: String?,
    onOpenDetail: () -> Unit,
    bucketPrefs: QuotaBucketDisplayPrefs,
    modifier: Modifier = Modifier,
) {
    val hiddenBuckets = bucketPrefs.hiddenBuckets
    val bucketOrders = bucketPrefs.bucketOrders
    val percentageDisplayMode = bucketPrefs.percentageDisplayMode
    val defaultWindow by rememberQuotaDefaultWindow()
    var expanded by remember(snapshot.id) { mutableStateOf(false) }

    val customizedBuckets =
        remember(snapshot, hiddenBuckets, bucketOrders) {
            snapshot.customizedBuckets(hiddenBuckets, bucketOrders)
        }
    val classified =
        remember(customizedBuckets) {
            customizedBuckets.map { it to QuotaWindowKind.infer(it) }
        }
    val primaryBucket =
        remember(classified, defaultWindow) {
            classified.firstOrNull { it.second == defaultWindow }
                ?: classified.firstOrNull { it.second != QuotaWindowKind.OTHER }
                ?: classified.firstOrNull()
        }
    val expandRotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "expand-chevron",
    )

    AuroraGlassCard(modifier = modifier) {
        ProviderAccordionCardHeader(
            snapshot = snapshot,
            accounts = accounts,
            signedInEmail = signedInEmail,
            expanded = expanded,
            expandRotation = expandRotation,
            onToggleExpanded = { expanded = !expanded },
        )
        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        ProviderAccordionCardBody(
            snapshot = snapshot,
            classified = classified,
            primaryBucket = primaryBucket,
            expanded = expanded,
            percentageDisplayMode = percentageDisplayMode,
            onOpenDetail = onOpenDetail,
        )
    }
}

@Composable
private fun ProviderAccordionCardHeader(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    signedInEmail: String?,
    expanded: Boolean,
    expandRotation: Float,
    onToggleExpanded: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProviderAvatar(providerKey = snapshot.provider, size = 36)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                AgentProvider.fromKey(snapshot.provider)?.displayName ?: snapshot.provider,
                fontWeight = FontWeight.Bold,
            )
            Text(
                quotaAccountEmail(snapshot, accounts, signedInEmail)
                    ?: quotaAccountName(snapshot, accounts),
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(
            onClick = onToggleExpanded,
            modifier = Modifier.graphicsLayer { rotationZ = expandRotation },
        ) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = if (expanded) "Collapse" else "Expand",
            )
        }
    }
}

@Composable
private fun ProviderAccordionCardBody(
    snapshot: ProviderQuotaSnapshot,
    classified: List<Pair<QuotaBucket, QuotaWindowKind>>,
    primaryBucket: Pair<QuotaBucket, QuotaWindowKind>?,
    expanded: Boolean,
    percentageDisplayMode: String,
    onOpenDetail: () -> Unit,
) {
    when {
        snapshot.isStale() ->
            Text(
                "Quota data is stale. Refresh before trusting these numbers.",
                fontSize = AuroraTypography.caption.sp,
                color = AuroraColors.warning,
            )
        classified.isEmpty() ->
            Text(
                snapshot.statusMessage?.takeIf { it.isNotBlank() } ?: "No quota signal yet.",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        !expanded ->
            primaryBucket?.let { (bucket, kind) ->
                BucketRow(bucket = bucket, kind = kind, displayMode = percentageDisplayMode)
            }
        else ->
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                classified.forEach { (bucket, kind) ->
                    BucketRow(bucket = bucket, kind = kind, displayMode = percentageDisplayMode)
                }
                TextButton(onClick = onOpenDetail, modifier = Modifier.align(Alignment.End)) {
                    Text("Open details")
                }
            }
    }
}

@Composable
private fun BucketRow(bucket: QuotaBucket, kind: QuotaWindowKind, displayMode: String) {
    val pct = bucket.displayRemainingPercent?.roundToInt()
    val isUnlimited = bucket.meta?.get("unit")?.toString()?.equals("unlimited", ignoreCase = true) == true
    val isLow = pct != null && pct in 0..25
    val barColor =
        when {
            pct == null || isUnlimited -> AuroraColors.success
            pct in 0..25 -> AuroraColors.burnOrange
            pct < 50 -> AuroraColors.warning
            else -> AuroraColors.burnCoral
        }

    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        BucketRowLabels(
            kind = kind,
            bucket = bucket,
            isUnlimited = isUnlimited,
            displayMode = displayMode,
            modifier = Modifier.weight(1f),
        )
        BucketRowMeter(
            bucket = bucket,
            pct = pct,
            isUnlimited = isUnlimited,
            isLow = isLow,
            barColor = barColor,
            displayMode = displayMode,
        )
    }
}

@Composable
private fun BucketRowLabels(
    kind: QuotaWindowKind,
    bucket: QuotaBucket,
    isUnlimited: Boolean,
    displayMode: String,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        Text(
            kind.displayLabel.replaceFirstChar { it.uppercase() },
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            if (isUnlimited) {
                "Unlimited"
            } else {
                bucket.getRemainingText(displayMode)
            },
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun BucketRowMeter(
    bucket: QuotaBucket,
    pct: Int?,
    isUnlimited: Boolean,
    isLow: Boolean,
    barColor: Color,
    displayMode: String,
) {
    Column(horizontalAlignment = Alignment.End) {
        Text(
            bucketDisplayValue(bucket = bucket, pct = pct, isUnlimited = isUnlimited, displayMode = displayMode),
            fontWeight = FontWeight.Bold,
            color = if (isLow) AuroraColors.burnOrange else MaterialTheme.colorScheme.onSurface,
        )
        if (pct != null) {
            val progressFraction =
                when (displayMode) {
                    "usedPercent" -> ((100 - pct) / 100f).coerceIn(0f, 1f)
                    else -> (pct / 100f).coerceIn(0f, 1f)
                }
            LinearProgressIndicator(
                progress = { progressFraction },
                modifier = Modifier.width(96.dp).height(6.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(3.dp)),
                color = barColor,
                trackColor = AuroraColors.darkBorder.copy(alpha = 0.35f),
            )
        }
    }
}

private fun bucketDisplayValue(
    bucket: QuotaBucket,
    pct: Int?,
    isUnlimited: Boolean,
    displayMode: String,
): String {
    if (isUnlimited) return "∞"
    return when (displayMode) {
        "remainingPercent" -> pct?.let { "$it%" } ?: "—"
        "usedPercent" -> pct?.let { "${100 - it}%" } ?: "—"
        "fractional" -> pct?.let { "%.2f".format(it / 100.0) } ?: "—"
        "absoluteValues" -> {
            val unit = bucket.bucketUnit
            if (unit == ProviderQuotaUnit.PERCENT) {
                pct?.let { "$it%" } ?: "—"
            } else {
                bucket.formatValue(bucket.remaining)
            }
        }
        else -> pct?.let { "$it%" } ?: "—"
    }
}
