@file:Suppress("MagicNumber")

package com.openburnbar.ui.burn

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.derived.TrendDataDigest
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.IdealPace
import com.openburnbar.data.models.PaceSeverity
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingFraction
import com.openburnbar.data.models.displayRemainingPercent
import com.openburnbar.data.models.effectiveResetsAt
import com.openburnbar.data.models.effectiveWindowLabel
import com.openburnbar.data.models.isCreditBalance
import com.openburnbar.data.models.isStale
import com.openburnbar.data.models.idealPace
import com.openburnbar.data.models.label
import com.openburnbar.data.models.getRemainingText
import com.openburnbar.data.models.pressure
import com.openburnbar.data.models.nextResetDate
import com.openburnbar.data.models.hourlyBucket
import com.openburnbar.data.models.weeklyOrMonthlyBucket
import com.openburnbar.data.models.isDisplayableQuotaSignal
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.models.primaryDisplayableBucket
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.data.stores.rememberQuotaDefaultWindow
import com.openburnbar.ui.components.DemoDataEmptyState
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.components.ShimmerCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting
import com.openburnbar.util.QuotaResetFormatter
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

enum class QuotaSortMode(val label: String) {
    URGENCY("Urgency"),
    SPEND("Spend"),
    ALPHABETICAL("A → Z"),
    RECENTLY_REFRESHED("Recently refreshed");

    companion object {
        fun fromString(s: String?): QuotaSortMode = values().firstOrNull { it.name.equals(s, true) } ?: URGENCY
    }
}

private data class DayBucket(
    val dayStart: Instant,
    val isToday: Boolean,
    val snapshots: List<ProviderQuotaSnapshot>
)

val QuotaBucket.isEstimated: Boolean
    get() = meta?.get("isEstimated")?.toString()?.lowercase() == "true"
        || meta?.get("estimated")?.toString()?.lowercase() == "true"

/** Redesigned top-level screen driven by state, aligned with iOS layout choices. */
@Composable
internal fun BurnViewContent(
    quotaStore: QuotaStore,
    demoDataStore: DemoDataStore,
    dashboardStore: DashboardStore,
    activityStore: ActivityStore,
) {
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
            else -> {
                val sharedPrefs = remember { context.getSharedPreferences("burnbar_quota_prefs", Context.MODE_PRIVATE) }
                var pinnedKeys by remember {
                    mutableStateOf(sharedPrefs.getStringSet("pinned_quotas", emptySet()) ?: emptySet())
                }

                val displayableSnapshots = remember(store.visibleSnapshots, showInactive) {
                    store.visibleSnapshots.filter { snap ->
                        showInactive || snap.buckets.any { it.isDisplayableQuotaSignal() }
                    }
                }

                val sortedSnapshots = remember(displayableSnapshots, sortMode, store.accounts, store.rollups, pinnedKeys) {
                    sortQuotaSnapshots(displayableSnapshots, sortMode, store.accounts, store.rollups, pinnedKeys)
                }

                val filteredSnapshots = remember(sortedSnapshots, selectedProvider) {
                    if (selectedProvider == null) sortedSnapshots
                    else sortedSnapshots.filter { AgentProvider.fromKey(it.provider) == selectedProvider }
                }

                val openUrl: (String) -> Unit = { url ->
                    try {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        context.startActivity(intent)
                    } catch (e: Exception) {
                        // ignore
                    }
                }

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            Brush.linearGradient(
                                colors = listOf(
                                    AuroraColors.ember.copy(alpha = 0.03f),
                                    Color.Transparent,
                                    AuroraColors.amber.copy(alpha = 0.02f)
                                )
                            )
                        )
                        .verticalScroll(rememberScrollState())
                        .padding(bottom = AuroraSpacing.xxl.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
                ) {
                    // 1. Constellation Hero at top
                    SubscriptionConstellationHero(
                        snapshots = sortedSnapshots,
                        selectedProvider = selectedProvider,
                        onOrbTap = { provider ->
                            selectedProvider = if (selectedProvider == provider) null else provider
                        },
                        onClearSelection = { selectedProvider = null }
                    )

                    // 2. Filter Rail
                    QuotaFilterRail(
                        viewMode = store.burnStyle,
                        onViewModeChange = { store.quotaPrefs.setBurnViewStyle(it.key) },
                        sort = sortMode,
                        onSortChange = { sortMode = it },
                        showInactive = showInactive,
                        onShowInactiveChange = { showInactive = it },
                        isRefreshing = store.isLoading,
                        onRefreshAll = { quotaStore.refresh() }
                    )

                    // 3. Focused provider Focus Banner
                    selectedProvider?.let { focusedProvider ->
                        ProviderFocusBanner(
                            provider = focusedProvider,
                            accountCount = filteredSnapshots.size,
                            totalProviderCount = sortedSnapshots.map { it.provider }.distinct().size,
                            onClearSelection = { selectedProvider = null }
                        )
                    }

                    // 4. Grid / Column of Plan entries
                    if (filteredSnapshots.isEmpty()) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = AuroraSpacing.xl.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "No active plans found for focus.",
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    } else {
                        if (store.burnStyle == BurnViewStyle.LIST) {
                            Column(
                                modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
                                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
                            ) {
                                filteredSnapshots.forEach { snapshot ->
                                    SubscriptionListRow(
                                        snapshot = snapshot,
                                        accounts = store.accounts,
                                        onRefresh = { quotaStore.refresh() }
                                    )
                                }
                            }
                        } else {
                            // CARDS view mode
                            Column(
                                modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
                                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
                            ) {
                                filteredSnapshots.forEach { snapshot ->
                                    val snapshotKey = snapshot.provider + "_" + (snapshot.accountId ?: snapshot.sourceId)
                                    SubscriptionCard(
                                        snapshot = snapshot,
                                        accounts = store.accounts,
                                        signedInEmail = store.signedInEmail,
                                        onRefresh = { quotaStore.refresh() },
                                        onTogglePin = { pin ->
                                            val newPinned = if (pin) pinnedKeys + snapshotKey else pinnedKeys - snapshotKey
                                            sharedPrefs.edit().putStringSet("pinned_quotas", newPinned).apply()
                                            pinnedKeys = newPinned
                                        },
                                        isPinned = pinnedKeys.contains(snapshotKey),
                                        onOpenDetail = { openUrl(snapshot.managementUrl ?: "") }
                                    )
                                }
                            }
                        }
                    }

                    // 5. Reset Atlas at the bottom
                    if (filteredSnapshots.isNotEmpty()) {
                        QuotaResetAtlas(snapshots = filteredSnapshots)
                    }

                    // 6. Setup Suggestions
                    val takenProviders = remember(store.visibleSnapshots) {
                        store.visibleSnapshots.mapNotNull { AgentProvider.fromKey(it.provider) }.toSet()
                    }
                    val setupSlots = remember(takenProviders) {
                        AgentProvider.entries.filter { !takenProviders.contains(it) }
                    }
                    if (showInactive && setupSlots.isNotEmpty()) {
                        QuotaSetupSuggestionsStrip(
                            slots = setupSlots,
                            onConnectClick = { /* Connect action */ }
                        )
                    }
                }
            }
        }
    }
}

/** focused banner matching iOS layout. */
@Composable
fun ProviderFocusBanner(
    provider: AgentProvider,
    accountCount: Int,
    totalProviderCount: Int,
    onClearSelection: () -> Unit
) {
    val primaryColor = Color(provider.brandColor)
    val accountWord = if (accountCount == 1) "account" else "accounts"
    val otherCount = maxOf(0, totalProviderCount - 1)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(primaryColor.copy(alpha = 0.07f))
            .border(0.75.dp, primaryColor.copy(alpha = 0.30f), RoundedCornerShape(AuroraRadius.md.dp))
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ProviderAvatar(providerKey = provider.key, size = 14)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Text(
                    text = "FOCUSED",
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    color = primaryColor,
                    letterSpacing = 0.9.sp
                )
                Text(
                    text = "·",
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                )
                Text(
                    text = provider.displayName,
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
            Text(
                text = "$accountCount $accountWord · $otherCount other provider${if (otherCount == 1) "" else "s"} hidden",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
                .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
                .clickable { onClearSelection() }
                .padding(horizontal = 10.dp, vertical = 5.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(9.dp)
                )
                Text(
                    text = "Show all",
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

/** Redesigned cards list matching iOS SubscriptionCard. */
@Composable
fun SubscriptionCard(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    signedInEmail: String?,
    onRefresh: () -> Unit,
    onTogglePin: (Boolean) -> Unit,
    isPinned: Boolean,
    onOpenDetail: () -> Unit,
    modifier: Modifier = Modifier
) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)
    var expanded by remember { mutableStateOf(false) }

    val defaultWindow by rememberQuotaDefaultWindow()

    val displayableBuckets = remember(snapshot) {
        snapshot.buckets.filter { it.isDisplayableQuotaSignal() }
    }

    val hourlyBucket = snapshot.hourlyBucket
    val weeklyOrMonthlyBucket = snapshot.weeklyOrMonthlyBucket
    val primaryBucket = snapshot.primaryDisplayableBucket(defaultWindow)

    val hourlyLabel = "5-hour window"
    val weeklyLabel = when (weeklyOrMonthlyBucket?.let { QuotaWindowKind.infer(it) }) {
        QuotaWindowKind.MONTHLY -> "30-day window"
        else -> "7-day window"
    }

    val isStale = snapshot.isStale()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = 6.dp,
                shape = RoundedCornerShape(AuroraRadius.lg.dp)
            )
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        primaryColor.copy(alpha = 0.10f),
                        accentColor.copy(alpha = 0.04f),
                        Color.Transparent
                    )
                )
            )
            .border(
                width = 0.8.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        primaryColor.copy(alpha = 0.34f),
                        accentColor.copy(alpha = 0.14f),
                        primaryColor.copy(alpha = 0.08f)
                    )
                ),
                shape = RoundedCornerShape(AuroraRadius.lg.dp)
            )
    ) {
        Column(
            modifier = Modifier.padding(AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            // Header row
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
            ) {
                // Identity orb
                Box(contentAlignment = Alignment.Center, modifier = Modifier.size(36.dp)) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clip(CircleShape)
                            .background(primaryColor.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center
                    ) {
                        ProviderAvatar(providerKey = provider.key, size = 18)
                    }
                    Canvas(modifier = Modifier.size(36.dp)) {
                        drawCircle(
                            color = primaryColor.copy(alpha = 0.35f),
                            radius = size.minDimension / 2f - 1.dp.toPx(),
                            style = Stroke(width = 1.2.dp.toPx())
                        )
                    }
                }

                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
                    ) {
                        Text(
                            text = provider.displayName,
                            fontSize = AuroraTypography.headline.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface
                        )

                        val isEstimated = snapshot.buckets.any { it.isEstimated }
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(primaryColor.copy(alpha = 0.12f))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        ) {
                            Text(
                                text = if (isEstimated) "ESTIMATED" else "ACTIVE",
                                fontSize = 9.sp,
                                fontWeight = FontWeight.Bold,
                                color = primaryColor,
                                letterSpacing = 0.8.sp
                            )
                        }
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.AccountCircle,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                            modifier = Modifier.size(12.dp)
                        )
                        val accountEmail = quotaAccountEmail(snapshot, accounts, signedInEmail)
                            ?: quotaAccountName(snapshot, accounts)
                        Text(
                            text = accountEmail,
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        snapshot.accountStorageScope?.let {
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            ) {
                                Text(
                                    text = it,
                                    fontSize = 9.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }

                // Confidence badge
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(
                            Brush.linearGradient(
                                colors = listOf(
                                    primaryColor.copy(alpha = 0.08f),
                                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)
                                )
                            )
                        )
                        .border(0.5.dp, primaryColor.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                ) {
                    Text(
                        text = "${snapshot.source?.uppercase(Locale.getDefault()) ?: "API"} · ${snapshot.confidence.uppercase(Locale.getDefault())}",
                        fontSize = 9.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        letterSpacing = 0.5.sp
                    )
                }
            }

            // Main row
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
            ) {
                // Dial
                QuotaArcDial(
                    outer = weeklyOrMonthlyBucket ?: primaryBucket,
                    inner = hourlyBucket,
                    provider = provider,
                    diameter = 138.dp
                )

                // Column of metrics
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
                ) {
                    MetricRow(
                        glyph = "clock.fill",
                        label = hourlyLabel,
                        bucket = hourlyBucket,
                        fallback = "Short-window quota not exposed",
                        provider = provider
                    )

                    MetricRow(
                        glyph = "calendar",
                        label = weeklyLabel,
                        bucket = weeklyOrMonthlyBucket ?: primaryBucket,
                        fallback = "Long-window quota not exposed",
                        provider = provider
                    )

                    // Next reset hourglass text
                    val nextResetDate = snapshot.nextResetDate
                    if (nextResetDate != null) {
                        val formattedRelative = relativeTimeLabel(nextResetDate)
                        val formattedAbsolute = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).format(nextResetDate.atZone(ZoneId.systemDefault()))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Schedule,
                                contentDescription = null,
                                tint = primaryColor,
                                modifier = Modifier.size(12.dp)
                            )
                            Text(
                                text = "Next reset $formattedRelative",
                                fontSize = AuroraTypography.caption.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                text = "· $formattedAbsolute",
                                fontSize = AuroraTypography.tiny.sp,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                            )
                        }
                    } else {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Default.Schedule,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                modifier = Modifier.size(12.dp)
                            )
                            Text(
                                text = "Reset time not published.",
                                fontSize = AuroraTypography.caption.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                            )
                        }
                    }

                    if (isStale) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(AuroraColors.warning.copy(alpha = 0.12f))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        ) {
                            Text(
                                text = "Stale signal",
                                fontSize = 9.sp,
                                fontWeight = FontWeight.Bold,
                                color = AuroraColors.warning
                            )
                        }
                    }
                }
            }

            // Footer actions row
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Chevron expander
                Row(
                    modifier = Modifier
                        .clickable(enabled = displayableBuckets.isNotEmpty()) { expanded = !expanded }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                    val toggleLabel = if (displayableBuckets.isEmpty()) "No live buckets"
                    else if (expanded) "Hide buckets"
                    else "Show buckets (${displayableBuckets.size})"
                    Text(
                        text = toggleLabel,
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                Spacer(modifier = Modifier.weight(1f))

                // Pin
                IconButton(
                    onClick = { onTogglePin(!isPinned) },
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = if (isPinned) Icons.Default.PushPin else Icons.Default.PushPin,
                        contentDescription = if (isPinned) "Unpin" else "Pin",
                        tint = if (isPinned) primaryColor else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                }

                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))

                // Refresh
                IconButton(
                    onClick = onRefresh,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = "Refresh snapshot",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                }

                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))

                // Manage link
                if (!snapshot.managementUrl.isNullOrEmpty()) {
                    Row(
                        modifier = Modifier
                            .clickable { onOpenDetail() }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp)
                    ) {
                        Text(
                            text = "Manage",
                            fontSize = AuroraTypography.caption.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = primaryColor
                        )
                        Icon(
                            imageVector = Icons.Default.ArrowForward,
                            contentDescription = null,
                            tint = primaryColor,
                            modifier = Modifier.size(10.dp)
                        )
                    }
                }
            }

            // Expanded view
            AnimatedVisibility(
                visible = expanded,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = AuroraSpacing.sm.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
                ) {
                    HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.2f))
                    Text(
                        text = "QUOTA BARS",
                        fontSize = AuroraTypography.tiny.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        letterSpacing = 1.0.sp
                    )

                    displayableBuckets.forEach { bucket ->
                        UnifiedQuotaSignalView(bucket = bucket, provider = provider, compact = false)
                    }
                }
            }
        }
    }
}

@Composable
fun SubscriptionOrb(
    provider: AgentProvider,
    snapshot: ProviderQuotaSnapshot,
    isSelected: Boolean,
    isDimmed: Boolean,
    onTap: () -> Unit
) {
    val primaryColor = Color(provider.brandColor)
    val remainingFraction = 1.0 - snapshot.pressure
    val ringColor = when {
        remainingFraction >= 0.75 -> primaryColor
        remainingFraction >= 0.50 -> primaryColor.copy(alpha = 0.78f)
        remainingFraction >= 0.25 -> AuroraColors.amber
        else -> AuroraColors.warning
    }

    val alpha = if (isDimmed) 0.45f else 1.0f

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(64.dp)
            .clickable { onTap() }
            .graphicsLayer { this.alpha = alpha }
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(64.dp)
        ) {
            if (isSelected) {
                Canvas(modifier = Modifier.size(64.dp)) {
                    drawCircle(
                        color = ringColor.copy(alpha = 0.4f),
                        radius = size.minDimension / 2f - 1.dp.toPx(),
                        style = Stroke(width = 1.5.dp.toPx())
                    )
                }
            }

            Box(
                modifier = Modifier
                    .size(46.dp)
                    .clip(CircleShape)
                    .background(primaryColor.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                ProviderAvatar(providerKey = provider.key, size = 28)
            }

            val surfaceVariant = MaterialTheme.colorScheme.surfaceVariant
            Canvas(modifier = Modifier.size(54.dp)) {
                val strokeWidth = 3.dp.toPx()
                val diameter = size.minDimension - strokeWidth
                val topLeft = Offset(strokeWidth / 2f, strokeWidth / 2f)

                drawCircle(
                    color = surfaceVariant.copy(alpha = 0.7f),
                    radius = diameter / 2f,
                    style = Stroke(width = strokeWidth)
                )

                drawArc(
                    color = ringColor,
                    startAngle = -90f,
                    sweepAngle = 360f * remainingFraction.toFloat().coerceIn(0f, 1f),
                    useCenter = false,
                    topLeft = topLeft,
                    size = Size(diameter, diameter),
                    style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                )
            }
        }
        Spacer(modifier = Modifier.height(4.dp))
        val pct = (remainingFraction * 100).roundToInt()
        Text(
            text = "$pct%",
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = ringColor
        )
    }
}

@Composable
fun SubscriptionConstellationHero(
    snapshots: List<ProviderQuotaSnapshot>,
    selectedProvider: AgentProvider?,
    onOrbTap: (AgentProvider) -> Unit,
    onClearSelection: () -> Unit,
    modifier: Modifier = Modifier
) {
    val activeCount = snapshots.size
    var wideOpenCount = 0
    var narrowingCount = 0
    var nearEdgeCount = 0
    snapshots.forEach { snapshot ->
        val pressure = snapshot.pressure
        when {
            pressure < 0.46 -> wideOpenCount++
            pressure < 0.74 -> narrowingCount++
            else -> nearEdgeCount++
        }
    }

    val eyebrowText = if (selectedProvider != null) {
        "FOCUSED · ${selectedProvider.displayName.uppercase(Locale.getDefault())} · $activeCount ACTIVE ACCOUNT" + (if (activeCount == 1) "" else "S")
    } else {
        "SUBSCRIPTION VAULT · $activeCount ACTIVE PLAN" + (if (activeCount == 1) "" else "s").uppercase(Locale.getDefault())
    }

    val headlineText = if (activeCount == 0) {
        "Connect a plan to start tracking quota"
    } else if (selectedProvider != null) {
        val accountWord = if (activeCount == 1) "account" else "accounts"
        if (nearEdgeCount > 0) {
            "${selectedProvider.displayName} · $activeCount $accountWord · $nearEdgeCount near the edge"
        } else {
            "${selectedProvider.displayName} · $activeCount $accountWord tracked"
        }
    } else {
        if (nearEdgeCount > 0) {
            "$activeCount plan" + (if (activeCount == 1) "" else "s") + " tracked · $nearEdgeCount near the edge"
        } else if (narrowingCount > 0) {
            "$wideOpenCount of $activeCount plans wide open · $narrowingCount narrowing"
        } else {
            "All $activeCount plan" + (if (activeCount == 1) "" else "s") + " have headroom"
        }
    }

    val metaItems = mutableListOf<String>()
    if (activeCount > 0) {
        metaItems.add("$activeCount ACTIVE")
    } else {
        metaItems.add("0 ACTIVE")
    }

    val nextResetSnapshot = snapshots
        .mapNotNull { snapshot -> snapshot.nextResetDate?.let { resetDate -> snapshot to resetDate } }
        .minByOrNull { (_, resetDate) -> resetDate }
    if (nextResetSnapshot != null) {
        val (snapshot, nextResetDate) = nextResetSnapshot
        val providerObj = AgentProvider.fromKey(snapshot.provider)
        if (providerObj != null) {
            val formattedRelative = relativeTimeLabel(nextResetDate).uppercase(Locale.getDefault())
            metaItems.add("NEXT RESET · ${providerObj.displayName.uppercase(Locale.getDefault())} · $formattedRelative")
        }
    }

    val lastSyncStr = snapshots.mapNotNull { it.fetchedAt }.maxOrNull()
    val lastSync = lastSyncStr?.let { runCatching { Instant.parse(it) }.getOrNull() }
    if (lastSync != null) {
        val formattedSync = relativeTimeLabel(lastSync).uppercase(Locale.getDefault())
        metaItems.add("SYNC $formattedSync")
    }

    if (nearEdgeCount > 0) {
        metaItems.add("$nearEdgeCount NEAR EDGE")
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.md.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
        ) {
            Text(
                text = eyebrowText,
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = if (selectedProvider != null) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                letterSpacing = 1.2.sp
            )

            if (selectedProvider != null) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
                        .clickable { onClearSelection() }
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Clear selection",
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(10.dp)
                        )
                        Text(
                            text = "Show all providers",
                            fontSize = AuroraTypography.tiny.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurface,
                            letterSpacing = 0.8.sp
                        )
                    }
                }
            }
        }

        Text(
            text = headlineText,
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )

        if (metaItems.isNotEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                metaItems.forEachIndexed { idx, item ->
                    if (idx > 0) {
                        Text(
                            text = "·",
                            fontSize = AuroraTypography.tiny.sp,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                        )
                    }
                    Text(
                        text = item,
                        fontSize = AuroraTypography.tiny.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        letterSpacing = 0.8.sp
                    )
                }
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(
                    Brush.horizontalGradient(
                        colors = listOf(
                            Color.Transparent,
                            AuroraColors.hermesMercury.copy(alpha = 0.5f),
                            AuroraColors.hermesAureate.copy(alpha = 0.65f),
                            AuroraColors.hermesMercury.copy(alpha = 0.5f),
                            Color.Transparent
                        )
                    )
                )
        )

        val orbEntries = remember(snapshots) {
            snapshots.groupBy { it.provider }.mapNotNull { (provKey, snaps) ->
                val provider = AgentProvider.fromKey(provKey) ?: return@mapNotNull null
                val worstSnapshot = snaps.maxByOrNull { it.pressure } ?: return@mapNotNull null
                provider to worstSnapshot
            }.sortedWith { lhs, rhs ->
                val lPressure = lhs.second.pressure
                val rPressure = rhs.second.pressure
                if (lPressure != rPressure) {
                    rPressure.compareTo(lPressure)
                } else {
                    lhs.first.displayName.compareTo(rhs.first.displayName, ignoreCase = true)
                }
            }
        }

        if (orbEntries.isNotEmpty()) {
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
                modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp)
            ) {
                items(orbEntries) { (provider, snapshot) ->
                    val isSelected = selectedProvider == provider
                    val isDimmed = selectedProvider != null && selectedProvider != provider
                    SubscriptionOrb(
                        provider = provider,
                        snapshot = snapshot,
                        isSelected = isSelected,
                        isDimmed = isDimmed,
                        onTap = { onOrbTap(provider) }
                    )
                }
            }
        }
    }
}

@Composable
fun QuotaFilterRail(
    viewMode: BurnViewStyle,
    onViewModeChange: (BurnViewStyle) -> Unit,
    sort: QuotaSortMode,
    onSortChange: (QuotaSortMode) -> Unit,
    showInactive: Boolean,
    onShowInactiveChange: (Boolean) -> Unit,
    isRefreshing: Boolean,
    onRefreshAll: () -> Unit,
    modifier: Modifier = Modifier
) {
    var sortMenuExpanded by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.sm.dp),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
                .padding(2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            listOf(BurnViewStyle.CARDS, BurnViewStyle.LIST).forEach { mode ->
                val active = viewMode == mode
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(14.dp))
                        .background(if (active) AuroraColors.ember.copy(alpha = 0.18f) else Color.Transparent)
                        .border(0.5.dp, if (active) AuroraColors.ember.copy(alpha = 0.4f) else Color.Transparent, RoundedCornerShape(14.dp))
                        .clickable { onViewModeChange(mode) }
                        .padding(horizontal = 10.dp, vertical = 4.5.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = mode.label,
                        fontSize = 11.sp,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                        color = if (active) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.85f)
                    )
                }
            }
        }

        Box {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                    .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f), RoundedCornerShape(16.dp))
                    .clickable { sortMenuExpanded = true }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    text = "Sort · ${sort.label}",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Icon(
                    imageVector = Icons.Default.ArrowDropDown,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier.size(12.dp)
                )
            }

            DropdownMenu(
                expanded = sortMenuExpanded,
                onDismissRequest = { sortMenuExpanded = false }
            ) {
                QuotaSortMode.values().forEach { mode ->
                    DropdownMenuItem(
                        text = {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                if (sort == mode) {
                                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(14.dp))
                                } else {
                                    Spacer(modifier = Modifier.size(14.dp))
                                }
                                Text(mode.label, fontSize = 13.sp)
                            }
                        },
                        onClick = {
                            onSortChange(mode)
                            sortMenuExpanded = false
                        }
                    )
                }
            }
        }

        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(
                    if (showInactive) AuroraColors.ember.copy(alpha = 0.10f)
                    else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
                )
                .border(
                    0.5.dp,
                    if (showInactive) AuroraColors.ember.copy(alpha = 0.45f)
                    else MaterialTheme.colorScheme.outline.copy(alpha = 0.4f),
                    RoundedCornerShape(16.dp)
                )
                .clickable { onShowInactiveChange(!showInactive) }
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = "Inactive plans",
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = if (showInactive) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Spacer(modifier = Modifier.weight(1f))

        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(AuroraColors.ember.copy(alpha = 0.18f))
                .border(0.5.dp, AuroraColors.ember.copy(alpha = 0.45f), RoundedCornerShape(16.dp))
                .clickable(enabled = !isRefreshing) { onRefreshAll() }
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (isRefreshing) {
                Text(
                    text = "Refreshing…",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
            } else {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(10.dp)
                )
                Text(
                    text = "Refresh all",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

@Composable
fun QuotaArcDial(
    outer: QuotaBucket?,
    inner: QuotaBucket?,
    provider: AgentProvider,
    modifier: Modifier = Modifier,
    diameter: Dp = 138.dp
) {
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)

    val dominantBucket = outer ?: inner
    val dominantRemaining = dominantBucket?.displayRemainingFraction ?: 1.0

    val outerRemaining = outer?.displayRemainingFraction ?: 1.0
    val innerRemaining = inner?.displayRemainingFraction ?: 1.0

    val outerPace = outer?.idealPace()
    val innerPace = inner?.idealPace()

    val outerLabel = when (outer?.let { QuotaWindowKind.infer(it) }) {
        QuotaWindowKind.SEVEN_DAY -> "7d"
        QuotaWindowKind.MONTHLY -> "30d"
        QuotaWindowKind.DAILY -> "24h"
        QuotaWindowKind.FIVE_HOUR -> "5h"
        else -> outer?.label?.take(8) ?: "—"
    }

    val innerLabel = when (inner?.let { QuotaWindowKind.infer(it) }) {
        QuotaWindowKind.FIVE_HOUR -> "5h"
        QuotaWindowKind.DAILY -> "24h"
        QuotaWindowKind.SEVEN_DAY -> "7d"
        QuotaWindowKind.MONTHLY -> "30d"
        else -> inner?.label?.take(8) ?: "—"
    }

    val centerText = if (dominantBucket != null) {
        "${(dominantRemaining * 100).roundToInt()}%"
    } else {
        "—"
    }

    val centerSubtitle = if (dominantBucket != null) {
        val displayLabel = if (outerLabel == "—") innerLabel else outerLabel
        "left in $displayLabel"
    } else {
        "no signal"
    }

    val isDark = isSystemInDarkTheme()
    val trackBgColor = if (isDark) AuroraColors.darkSurfaceElevated.copy(alpha = 0.85f) else AuroraColors.lightSurfaceElevated.copy(alpha = 0.85f)

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier.size(diameter)
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val cx = size.width / 2f
            val cy = size.height / 2f

            // Outer Ring Track (lineWidth = 8.dp)
            val outerLineWidth = 8.dp.toPx()
            val outerDiameter = size.minDimension - outerLineWidth - 4.dp.toPx()
            val outerTopLeft = Offset(cx - outerDiameter / 2f, cy - outerDiameter / 2f)
            val outerSize = Size(outerDiameter, outerDiameter)

            drawCircle(
                color = trackBgColor,
                radius = outerDiameter / 2f,
                style = Stroke(width = outerLineWidth)
            )

            // Outer Ring Fill
            if (outer != null) {
                val outerRemainingFraction = outerRemaining.toFloat().coerceIn(0f, 1f)
                val outerFillColor = when {
                    outerRemaining >= 0.75 -> primaryColor
                    outerRemaining >= 0.50 -> primaryColor.copy(alpha = 0.78f)
                    outerRemaining >= 0.25 -> AuroraColors.amber
                    else -> AuroraColors.warning
                }

                drawArc(
                    color = outerFillColor,
                    startAngle = -90f,
                    sweepAngle = 360f * outerRemainingFraction,
                    useCenter = false,
                    topLeft = outerTopLeft,
                    size = outerSize,
                    style = Stroke(width = outerLineWidth, cap = StrokeCap.Round)
                )

                // Outer Pace Marker
                if (outerPace != null) {
                    val angle = -90f + 360f * (1.0f - outerPace.elapsedFraction.toFloat())
                    val angleRad = Math.toRadians(angle.toDouble())
                    val radius = outerDiameter / 2f
                    val px = cx + Math.cos(angleRad).toFloat() * radius
                    val py = cy + Math.sin(angleRad).toFloat() * radius
                    drawCircle(color = outerFillColor.copy(alpha = 0.25f), radius = (outerLineWidth + 4f)/2f, center = Offset(px, py))
                    drawCircle(color = Color.White, radius = (outerLineWidth - 2f)/2f, center = Offset(px, py))
                    drawCircle(color = outerFillColor.copy(alpha = 0.9f), radius = (outerLineWidth - 2f)/2f, center = Offset(px, py), style = Stroke(width = 1.dp.toPx()))
                }
            } else {
                drawArc(
                    color = primaryColor.copy(alpha = 0.15f),
                    startAngle = 0f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = outerTopLeft,
                    size = outerSize,
                    style = Stroke(width = outerLineWidth, pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 12f)))
                )
            }

            // Inner Ring Track (lineWidth = 6.dp, inset = 20.dp)
            val innerLineWidth = 6.dp.toPx()
            val innerDiameter = size.minDimension - innerLineWidth - 40.dp.toPx()
            val innerTopLeft = Offset(cx - innerDiameter / 2f, cy - innerDiameter / 2f)
            val innerSize = Size(innerDiameter, innerDiameter)

            drawCircle(
                color = trackBgColor,
                radius = innerDiameter / 2f,
                style = Stroke(width = innerLineWidth)
            )

            // Inner Ring Fill
            if (inner != null) {
                val innerRemainingFraction = innerRemaining.toFloat().coerceIn(0f, 1f)
                val innerFillColor = when {
                    innerRemaining >= 0.75 -> accentColor
                    innerRemaining >= 0.50 -> accentColor.copy(alpha = 0.78f)
                    innerRemaining >= 0.25 -> AuroraColors.amber
                    else -> AuroraColors.warning
                }

                drawArc(
                    color = innerFillColor,
                    startAngle = -90f,
                    sweepAngle = 360f * innerRemainingFraction,
                    useCenter = false,
                    topLeft = innerTopLeft,
                    size = innerSize,
                    style = Stroke(width = innerLineWidth, cap = StrokeCap.Round)
                )

                // Inner Pace Marker
                if (innerPace != null) {
                    val angle = -90f + 360f * (1.0f - innerPace.elapsedFraction.toFloat())
                    val angleRad = Math.toRadians(angle.toDouble())
                    val radius = innerDiameter / 2f
                    val px = cx + Math.cos(angleRad).toFloat() * radius
                    val py = cy + Math.sin(angleRad).toFloat() * radius
                    drawCircle(color = innerFillColor.copy(alpha = 0.25f), radius = (innerLineWidth + 4f)/2f, center = Offset(px, py))
                    drawCircle(color = Color.White, radius = (innerLineWidth - 2f)/2f, center = Offset(px, py))
                    drawCircle(color = innerFillColor.copy(alpha = 0.9f), radius = (innerLineWidth - 2f)/2f, center = Offset(px, py), style = Stroke(width = 1.dp.toPx()))
                }
            } else {
                drawArc(
                    color = accentColor.copy(alpha = 0.12f),
                    startAngle = 0f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = innerTopLeft,
                    size = innerSize,
                    style = Stroke(width = innerLineWidth, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 10f)))
                )
            }
        }

        // Center Label
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = centerText,
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = if (dominantBucket != null) primaryColor else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            )
            Text(
                text = centerSubtitle,
                fontSize = AuroraTypography.tiny.sp,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
            )
        }
    }
}

@Composable
fun MetricRow(
    glyph: String,
    label: String,
    bucket: QuotaBucket?,
    fallback: String,
    provider: AgentProvider
) {
    val primaryColor = Color(provider.brandColor)
    val remainingFraction = bucket?.displayRemainingFraction ?: 1.0
    val ringColor = when {
        remainingFraction >= 0.75 -> primaryColor
        remainingFraction >= 0.50 -> primaryColor.copy(alpha = 0.78f)
        remainingFraction >= 0.25 -> AuroraColors.amber
        else -> AuroraColors.warning
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        Box(
            modifier = Modifier.width(14.dp),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = when (glyph) {
                    "clock.fill" -> Icons.Default.Schedule
                    "calendar" -> Icons.Default.DateRange
                    else -> Icons.Default.DateRange
                },
                contentDescription = null,
                tint = primaryColor,
                modifier = Modifier.size(11.dp)
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = label.uppercase(Locale.getDefault()),
                fontSize = 8.sp,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                letterSpacing = 0.8.sp
            )

            if (bucket != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    val remainingText = if (bucket.meta?.get("unit")?.toString()?.lowercase() == "unlimited") "Unlimited" else {
                        bucket.getRemainingText("absoluteValues")
                    }
                    Text(
                        text = remainingText,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "·",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                    )
                    Text(
                        text = quotaUsageText(bucket),
                        fontSize = AuroraTypography.tiny.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )

                    val pace = bucket.idealPace()
                    if (pace != null && pace.severity != PaceSeverity.ON_PACE) {
                        PaceBadge(pace = pace)
                    }
                }
            } else {
                Text(
                    text = fallback,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                )
            }
        }
    }
}

@Composable
fun PaceBadge(pace: IdealPace) {
    val tint = when (pace.severity) {
        PaceSeverity.ON_PACE -> MaterialTheme.colorScheme.onSurfaceVariant
        PaceSeverity.AHEAD_OF_BUDGET -> AuroraColors.warning
        PaceSeverity.BEHIND_BUDGET -> AuroraColors.success
    }

    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(tint.copy(alpha = 0.10f))
            .border(0.5.dp, tint.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Text(
            text = pace.humanLabel,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
            color = tint
        )
    }
}

@Composable
fun SubscriptionListRow(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier
) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.5f))
            .border(0.75.dp, primaryColor.copy(alpha = 0.16f), RoundedCornerShape(AuroraRadius.md.dp))
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(32.dp)) {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .clip(CircleShape)
                    .background(primaryColor.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                ProviderAvatar(providerKey = provider.key, size = 16)
            }
            Canvas(modifier = Modifier.size(32.dp)) {
                drawCircle(
                    color = primaryColor.copy(alpha = 0.35f),
                    radius = size.minDimension / 2f - 1.dp.toPx(),
                    style = Stroke(width = 1.dp.toPx())
                )
            }
        }

        Column(modifier = Modifier.width(180.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                Text(
                    text = provider.displayName,
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                val isEstimated = snapshot.buckets.any { it.isEstimated }
                val badgeText = if (isEstimated) "Estimated" else "Active"
                Text(
                    text = badgeText.uppercase(Locale.getDefault()),
                    fontSize = 8.sp,
                    fontWeight = FontWeight.Bold,
                    color = primaryColor,
                    letterSpacing = 0.8.sp
                )
            }
            val accountEmail = quotaAccountEmail(snapshot, accounts) ?: quotaAccountName(snapshot, accounts)
            Text(
                text = accountEmail,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }

        QuotaDualWindowStrip(
            hourlyBucket = snapshot.hourlyBucket,
            weeklyBucket = snapshot.weeklyOrMonthlyBucket,
            fallbackBucket = snapshot.primaryDisplayableBucket(),
            provider = provider,
            isActive = false,
            modifier = Modifier.weight(1f)
        )

        val remainingPct = ((1.0 - snapshot.pressure) * 100).roundToInt()
        Text(
            text = "$remainingPct%",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = primaryColor,
            modifier = Modifier.width(60.dp),
            maxLines = 1
        )
    }
}

@Composable
fun QuotaDualWindowStrip(
    hourlyBucket: QuotaBucket?,
    weeklyBucket: QuotaBucket?,
    fallbackBucket: QuotaBucket?,
    provider: AgentProvider,
    isActive: Boolean,
    modifier: Modifier = Modifier
) {
    val primaryColor = Color(provider.brandColor)
    val isDark = isSystemInDarkTheme()
    val trackBgColor = if (isDark) AuroraColors.darkSurfaceElevated.copy(alpha = 0.85f) else AuroraColors.lightSurfaceElevated.copy(alpha = 0.85f)

    val shortSlot = hourlyBucket ?: if (fallbackBucket?.let { QuotaWindowKind.infer(it) } == QuotaWindowKind.DAILY) fallbackBucket else null
    val longSlot = weeklyBucket ?: fallbackBucket

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.82f))
            .border(1.dp, primaryColor.copy(alpha = 0.14f), RoundedCornerShape(AuroraRadius.md.dp))
            .padding(AuroraSpacing.sm.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        if (shortSlot != null) {
            val label = when (QuotaWindowKind.infer(shortSlot)) {
                QuotaWindowKind.FIVE_HOUR -> "5h"
                QuotaWindowKind.DAILY -> "24h"
                else -> "5h"
            }
            WindowBar(bucket = shortSlot, label = label, icon = "clock.fill", provider = provider, trackBgColor = trackBgColor)
        } else {
            WindowBarPlaceholder(label = "5h", icon = "clock.fill", provider = provider, trackBgColor = trackBgColor, isActive = isActive)
        }

        if (longSlot != null) {
            val label = when (QuotaWindowKind.infer(longSlot)) {
                QuotaWindowKind.SEVEN_DAY -> "7d"
                QuotaWindowKind.MONTHLY -> "30d"
                else -> "7d"
            }
            WindowBar(bucket = longSlot, label = label, icon = "calendar", provider = provider, trackBgColor = trackBgColor)
        } else {
            WindowBarPlaceholder(label = "7d", icon = "calendar", provider = provider, trackBgColor = trackBgColor, isActive = isActive)
        }
    }
}

@Composable
fun WindowBar(
    bucket: QuotaBucket,
    label: String,
    icon: String,
    provider: AgentProvider,
    trackBgColor: Color
) {
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)
    val remainingFraction = bucket.displayRemainingFraction ?: 1.0
    val fill = when {
        remainingFraction >= 0.75 -> primaryColor
        remainingFraction >= 0.50 -> primaryColor.copy(alpha = 0.72f)
        remainingFraction >= 0.25 -> AuroraColors.amber
        else -> AuroraColors.warning
    }

    val fillBrush = when {
        remainingFraction >= 0.75 -> Brush.horizontalGradient(colors = listOf(primaryColor, accentColor))
        remainingFraction >= 0.50 -> Brush.horizontalGradient(colors = listOf(primaryColor.copy(alpha = 0.72f), accentColor.copy(alpha = 0.58f)))
        remainingFraction >= 0.25 -> Brush.horizontalGradient(colors = listOf(primaryColor.copy(alpha = 0.55f), AuroraColors.amber))
        else -> Brush.horizontalGradient(colors = listOf(AuroraColors.warning, AuroraColors.warning.copy(alpha = 0.6f)))
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            modifier = Modifier.width(34.dp)
        ) {
            Box(
                modifier = Modifier.width(12.dp),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = when (icon) {
                        "clock.fill", "clock" -> Icons.Default.Schedule
                        "calendar" -> Icons.Default.DateRange
                        else -> Icons.Default.DateRange
                    },
                    contentDescription = null,
                    tint = fill,
                    modifier = Modifier.size(9.dp)
                )
            }
            Text(text = label, fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .height(10.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(trackBgColor)
                .border(1.dp, fill.copy(alpha = 0.18f), RoundedCornerShape(3.dp))
        ) {
            if (remainingFraction > 0) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(remainingFraction.toFloat())
                        .fillMaxSize()
                        .background(fillBrush)
                )
            }
            val pace = bucket.idealPace()
            if (pace != null) {
                val tickPos = (1.0f - pace.elapsedFraction.toFloat()).coerceIn(0f, 1f)
                Box(
                    modifier = Modifier
                        .fillMaxWidth(tickPos)
                        .fillMaxSize(),
                    contentAlignment = Alignment.CenterEnd
                ) {
                    Box(
                        modifier = Modifier
                            .width(1.5.dp)
                            .fillMaxSize()
                            .background(Color.White)
                    )
                }
            }
        }

        Text(
            text = bucket.getRemainingText("absoluteValues"),
            fontSize = AuroraTypography.tiny.sp,
            fontFamily = FontFamily.Monospace,
            color = fill,
            modifier = Modifier.width(36.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
fun WindowBarPlaceholder(
    label: String,
    icon: String,
    provider: AgentProvider,
    trackBgColor: Color,
    isActive: Boolean
) {
    val primaryColor = Color(provider.brandColor)

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            modifier = Modifier.width(34.dp)
        ) {
            Box(
                modifier = Modifier.width(12.dp),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = when (icon) {
                        "clock.fill", "clock" -> Icons.Default.Schedule
                        "calendar" -> Icons.Default.DateRange
                        else -> Icons.Default.DateRange
                    },
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                    modifier = Modifier.size(9.dp)
                )
            }
            Text(text = label, fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f))
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .height(10.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(trackBgColor)
                .border(
                    width = 1.dp,
                    color = primaryColor.copy(alpha = if (isActive) 0.18f else 0.08f)
                )
        )

        Text(
            text = "—",
            fontSize = AuroraTypography.tiny.sp,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
            modifier = Modifier.width(36.dp)
        )
    }
}

@Composable
fun ResetCell(snapshot: ProviderQuotaSnapshot, zone: ZoneId) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)

    val timeText = snapshot.nextResetDate?.let {
        val formatter = DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault()).withZone(zone)
        formatter.format(it).replace("am", "AM").replace("pm", "PM")
    } ?: "—"

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            primaryColor.copy(alpha = 0.22f),
                            accentColor.copy(alpha = 0.10f)
                        )
                    )
                )
                .border(0.75.dp, primaryColor.copy(alpha = 0.34f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            ProviderAvatar(providerKey = provider.key, size = 14)
        }

        Text(
            text = timeText,
            fontSize = 8.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

fun relativeTimeLabel(target: Instant, now: Instant = Instant.now()): String {
    val duration = Duration.between(now, target)
    val isFuture = !duration.isNegative
    val absDuration = duration.abs()

    val seconds = absDuration.seconds
    return when {
        seconds < 60 -> "just now"
        seconds < 3600 -> {
            val minutes = seconds / 60
            if (isFuture) "in ${minutes}m" else "${minutes}m ago"
        }
        seconds < 86400 -> {
            val hours = seconds / 3600
            val minutes = (seconds % 3600) / 60
            if (isFuture) "in ${hours}h ${minutes}m" else "${hours}h ${minutes}m ago"
        }
        else -> {
            val days = seconds / 86400
            if (isFuture) "in ${days}d" else "${days}d ago"
        }
    }
}

@Composable
fun BurnViewLoadingShimmer() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        ShimmerCard(height = 160)
        ShimmerCard(height = 50)
        repeat(3) {
            ShimmerCard(height = 200)
        }
    }
}

fun sortQuotaSnapshots(
    snapshots: List<ProviderQuotaSnapshot>,
    mode: QuotaSortMode,
    accounts: List<ProviderAccount>,
    rollups: UsageRollups?,
    pinnedKeys: Set<String> = emptySet()
): List<ProviderQuotaSnapshot> {
    val spendByID = mutableMapOf<String, Double>()
    rollups?.providerSummaries?.forEach { summary ->
        spendByID[summary.provider.lowercase()] = summary.totalCost
    }

    val baseComparator = Comparator<ProviderQuotaSnapshot> { lhs, rhs ->
        when (mode) {
            QuotaSortMode.URGENCY -> {
                val lPressure = lhs.pressure
                val rPressure = rhs.pressure
                if (lPressure != rPressure) {
                    rPressure.compareTo(lPressure)
                } else {
                    val lReset = lhs.nextResetDate ?: java.time.Instant.MAX
                    val rReset = rhs.nextResetDate ?: java.time.Instant.MAX
                    if (lReset != rReset) {
                        lReset.compareTo(rReset)
                    } else {
                        val lhsProvider = AgentProvider.fromKey(lhs.provider)
                        val rhsProvider = AgentProvider.fromKey(rhs.provider)
                        val lhsName = lhsProvider?.displayName ?: lhs.provider
                        val rhsName = rhsProvider?.displayName ?: rhs.provider
                        lhsName.compareTo(rhsName, ignoreCase = true)
                    }
                }
            }
            QuotaSortMode.SPEND -> {
                val lSpend = spendByID[lhs.provider.lowercase()] ?: 0.0
                val rSpend = spendByID[rhs.provider.lowercase()] ?: 0.0
                if (lSpend != rSpend) {
                    rSpend.compareTo(lSpend)
                } else {
                    val lhsProvider = AgentProvider.fromKey(lhs.provider)
                    val rhsProvider = AgentProvider.fromKey(rhs.provider)
                    val lhsName = lhsProvider?.displayName ?: lhs.provider
                    val rhsName = rhsProvider?.displayName ?: rhs.provider
                    lhsName.compareTo(rhsName, ignoreCase = true)
                }
            }
            QuotaSortMode.ALPHABETICAL -> {
                val lhsProvider = AgentProvider.fromKey(lhs.provider)
                val rhsProvider = AgentProvider.fromKey(rhs.provider)
                val lhsName = lhsProvider?.displayName ?: lhs.provider
                val rhsName = rhsProvider?.displayName ?: rhs.provider
                lhsName.compareTo(rhsName, ignoreCase = true)
            }
            QuotaSortMode.RECENTLY_REFRESHED -> {
                val lFetched = lhs.fetchedAt ?: ""
                val rFetched = rhs.fetchedAt ?: ""
                rFetched.compareTo(lFetched)
            }
        }
    }

    return snapshots.sortedWith { lhs, rhs ->
        val lKey = lhs.provider + "_" + (lhs.accountId ?: lhs.sourceId)
        val rKey = rhs.provider + "_" + (rhs.accountId ?: rhs.sourceId)
        val lPinned = pinnedKeys.contains(lKey)
        val rPinned = pinnedKeys.contains(rKey)
        if (lPinned != rPinned) {
            if (lPinned) -1 else 1
        } else {
            baseComparator.compare(lhs, rhs)
        }
    }
}

@Composable
fun QuotaResetAtlas(
    snapshots: List<ProviderQuotaSnapshot>,
    modifier: Modifier = Modifier
) {
    val daysForward = 7

    val dayBuckets = remember(snapshots) {
        val zone = ZoneId.systemDefault()
        val now = Instant.now()
        val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()

        val bucketsMap = mutableMapOf<java.time.LocalDate, MutableList<ProviderQuotaSnapshot>>()
        for (snap in snapshots) {
            val reset = snap.nextResetDate ?: continue
            val resetDate = ZonedDateTime.ofInstant(reset, zone).toLocalDate()
            val daysBetween = java.time.temporal.ChronoUnit.DAYS.between(today, resetDate)
            if (daysBetween in 0..daysForward) {
                bucketsMap.getOrPut(resetDate) { mutableListOf() }.add(snap)
            }
        }

        (0..daysForward).map { offset ->
            val day = today.plusDays(offset.toLong())
            val daySnaps = (bucketsMap[day] ?: emptyList()).sortedBy {
                it.nextResetDate ?: Instant.MAX
            }
            DayBucketData(
                day = day,
                isToday = offset == 0,
                snapshots = daySnaps
            )
        }
    }

    val totalResetCount = remember(dayBuckets) {
        dayBuckets.sumOf { it.snapshots.size }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "RESET ATLAS · NEXT 7 DAYS",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                letterSpacing = 1.0.sp
            )

            if (totalResetCount == 0) {
                Text(
                    text = "No resets scheduled in this window",
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                )
            } else {
                val s = if (totalResetCount == 1) "" else "s"
                Text(
                    text = "$totalResetCount reset event$s",
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(
                    Brush.horizontalGradient(
                        colors = listOf(
                            AuroraColors.hermesMercury.copy(alpha = 0f),
                            AuroraColors.hermesMercury.copy(alpha = 0.55f),
                            AuroraColors.hermesAureate.copy(alpha = 0.65f),
                            AuroraColors.hermesMercury.copy(alpha = 0.55f),
                            AuroraColors.hermesMercury.copy(alpha = 0f)
                        )
                    )
                )
        )

        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(AuroraRadius.md.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f)),
            border = androidx.compose.foundation.BorderStroke(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.40f))
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(AuroraSpacing.sm.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                dayBuckets.forEachIndexed { index, bucket ->
                    DayColumn(
                        bucket = bucket,
                        modifier = Modifier.weight(1f),
                        showLeadingDivider = index > 0
                    )
                }
            }
        }
    }
}

private data class DayBucketData(
    val day: java.time.LocalDate,
    val isToday: Boolean,
    val snapshots: List<ProviderQuotaSnapshot>
)

@Composable
private fun DayColumn(
    bucket: DayBucketData,
    modifier: Modifier = Modifier,
    showLeadingDivider: Boolean = false
) {
    Box(modifier = modifier) {
        if (showLeadingDivider) {
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .width(0.5.dp)
                    .height(60.dp)
                    .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.35f))
            )
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 2.dp, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            val dayLabel = if (bucket.isToday) "TODAY" else {
                val formatter = java.time.format.DateTimeFormatter.ofPattern("E d", Locale.getDefault())
                bucket.day.format(formatter).uppercase(Locale.getDefault())
            }
            Text(
                text = dayLabel,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                color = if (bucket.isToday) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
            )

            Box(
                modifier = Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(
                        if (bucket.isToday) AuroraColors.ember.copy(alpha = 0.85f)
                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
                    )
            )

            if (bucket.snapshots.isEmpty()) {
                Text(
                    text = "—",
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f),
                    modifier = Modifier.padding(top = 4.dp)
                )
            } else {
                Column(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(top = 2.dp)
                ) {
                    bucket.snapshots.forEach { snap ->
                        ResetCell(snapshot = snap)
                    }
                }
            }
        }
    }
}

@Composable
private fun ResetCell(snapshot: ProviderQuotaSnapshot) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)

    val timeLabel = remember(snapshot.nextResetDate) {
        val date = snapshot.nextResetDate ?: return@remember "—"
        val zone = ZoneId.systemDefault()
        val zdt = ZonedDateTime.ofInstant(date, zone)
        val formatter = java.time.format.DateTimeFormatter.ofPattern("h:mm a", Locale.US)
        zdt.format(formatter)
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(24.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .clip(CircleShape)
                    .background(
                        Brush.linearGradient(
                            colors = listOf(
                                primaryColor.copy(alpha = 0.22f),
                                accentColor.copy(alpha = 0.10f)
                            )
                        )
                    )
                    .border(0.75.dp, primaryColor.copy(alpha = 0.34f), CircleShape)
            )
            ProviderAvatar(providerKey = provider.key, size = 14)
        }

        Text(
            text = timeLabel,
            fontSize = 8.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1
        )
    }
}

@Composable
fun QuotaSetupSuggestionsStrip(
    slots: List<AgentProvider>,
    onConnectClick: (AgentProvider) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "✨",
                    fontSize = 11.sp
                )
                val s = if (slots.size == 1) "" else "S"
                Text(
                    text = "READY TO ADD · ${slots.size} PROVIDER$s",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    letterSpacing = 1.0.sp
                )
            }
        }

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)
        ) {
            items(slots) { provider ->
                SlotChip(provider = provider, onClick = { onConnectClick(provider) })
            }
        }
    }
}

@Composable
private fun SlotChip(
    provider: AgentProvider,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val primaryColor = Color(provider.brandColor)
    Card(
        modifier = modifier.width(232.dp),
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
        border = androidx.compose.foundation.BorderStroke(0.75.dp, primaryColor.copy(alpha = 0.20f))
    ) {
        Column(
            modifier = Modifier
                .clickable { onClick() }
                .padding(AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(primaryColor.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center
                ) {
                    ProviderAvatar(providerKey = provider.key, size = 18)
                }

                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(
                        text = provider.displayName,
                        fontSize = AuroraTypography.body.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "Not connected",
                        fontSize = AuroraTypography.tiny.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                    )
                }
            }

            Text(
                text = "Tap to configure tracking settings for ${provider.displayName}.",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(200.dp)
            )
        }
    }
}
