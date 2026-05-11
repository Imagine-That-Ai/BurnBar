package com.openburnbar.ui.pulse

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.models.*
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.components.*
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PulseView(
    dashboardStore: DashboardStore = viewModel(),
    quotaStore: QuotaStore = viewModel(),
    activityStore: ActivityStore = viewModel(),
    onNavigateToBurn: (() -> Unit)? = null,
    onNavigateToHermes: (() -> Unit)? = null,
    onNavigateToStreams: (() -> Unit)? = null,
    userStore: UserStore = viewModel()
) {
    val rollups by dashboardStore.rollups.collectAsState()
    val isLoading by dashboardStore.isLoading.collectAsState()
    val error by dashboardStore.error.collectAsState()
    var timelineScope by remember { mutableStateOf(TimelineScope.DAY) }
    var displayMode by remember { mutableStateOf(UsageDisplayMode.CURRENCY) }
    val currentUser by userStore.user.collectAsState()
    val isDark = isSystemInDarkTheme()

    LaunchedEffect(currentUser.isSignedIn) { if (currentUser.isSignedIn) {
        dashboardStore.load(); quotaStore.load(); activityStore.loadInitial() } }

    Box(modifier = Modifier.fillMaxSize()) {
        AuroraBackdrop(isDark = isDark)

        // Welcome / user name bar
        if (currentUser.isSignedIn) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.lg.dp).padding(top = AuroraSpacing.xl.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Hi, ${currentUser.displayName ?: "there"}",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onBackground
                )
            }
        }

        when {
            isLoading && rollups == null -> {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 80.dp, start = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
                ) {
                    ShimmerCard(height = 180)
                    ShimmerCard(height = 80)
                    ShimmerCard(height = 120)
                }
            }
            error != null && rollups == null -> {
                ErrorStateView(
                    icon = Icons.Filled.Error,
                    title = "Couldn't Load Dashboard",
                    message = error ?: "",
                    onRetry = { dashboardStore.refresh() }
                )
            }
            rollups == null -> {
                EmptyStateView(
                    icon = Icons.Filled.ShowChart,
                    title = "No Usage Data",
                    message = "Start using AI to see your burn here."
                )
            }
            else -> {
                Content(
                    rollups = rollups!!,
                    displayMode = displayMode,
                    timelineScope = timelineScope,
                    quotaStore = quotaStore,
                    onDisplayModeChange = { displayMode = it },
                    onTimelineChange = { timelineScope = it },
                    onNavigateToBurn = onNavigateToBurn,
                    onNavigateToHermes = onNavigateToHermes,
                    onNavigateToStreams = onNavigateToStreams
                )
            }
        }
    }
}

@Composable
private fun Content(
    rollups: UsageRollups,
    displayMode: UsageDisplayMode,
    timelineScope: TimelineScope,
    quotaStore: QuotaStore,
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
    onTimelineChange: (TimelineScope) -> Unit,
    onNavigateToBurn: (() -> Unit)?,
    onNavigateToHermes: (() -> Unit)?,
    onNavigateToStreams: (() -> Unit)?
) {
    val snapshots by quotaStore.snapshots.collectAsState()

    val window = timelineScope.valueFor(rollups)
    val trailingWindow = timelineScope.trailingValueFor(rollups)
    val topProvider = rollups.topProviders.firstOrNull()

    Column(
        modifier = Modifier
            .verticalScroll(rememberScrollState())
            .padding(bottom = AuroraSpacing.xxl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
    ) {
        StaggeredEntrance(delay = 0) {
            PulseHeroBurnCard(
                displayMode = displayMode,
                value = window,
                trailingValue = trailingWindow,
                totals = rollups.totals,
                timelineScope = timelineScope,
                topProvider = topProvider,
                onDisplayModeChange = onDisplayModeChange,
                onTimelineChange = onTimelineChange
            )
        }

        StaggeredEntrance(delay = 50) {
            VelocityForecastCard(rollups = rollups)
        }

        StaggeredEntrance(delay = 75) {
            QuotaPulseCard(
                snapshots = snapshots,
                onChipClick = { onNavigateToBurn?.invoke() }
            )
        }

        StaggeredEntrance(delay = 100) {
            TrendAtlasCard(rollups = rollups)
        }

        StaggeredEntrance(delay = 125) {
            HermesQuickAskCard(
                onQuickPrompt = { _ -> onNavigateToHermes?.invoke() },
                onOpenChat = { onNavigateToHermes?.invoke() }
            )
        }

        StaggeredEntrance(delay = 150) {
            RecentSessionsStripCard(
                onSeeAll = { onNavigateToStreams?.invoke() }
            )
        }
    }
}

// ── Flat model composable cards ──

@Composable
fun PulseHeroBurnCard(
    displayMode: UsageDisplayMode,
    value: Double,
    trailingValue: Double,
    totals: Map<String, Double>,
    timelineScope: TimelineScope,
    topProvider: RollupSummary?,
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
    onTimelineChange: (TimelineScope) -> Unit
) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("Burn", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                ChipSelector(
                    items = UsageDisplayMode.entries.toList(),
                    selected = displayMode,
                    onSelect = onDisplayModeChange,
                    labelProvider = { it.label }
                )
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                TimelineScope.entries.forEach { scope ->
                    SuggestionChip(
                        onClick = { onTimelineChange(scope) },
                        label = { Text(scope.label, fontSize = 12.sp) },
                        modifier = Modifier.weight(1f)
                    )
                }
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            val heroValue = if (displayMode == UsageDisplayMode.CURRENCY) value else totals["tokens"] ?: 0.0
            Text(
                text = if (displayMode == UsageDisplayMode.CURRENCY) Formatting.formatCurrency(heroValue) else Formatting.formatTokens(heroValue.toInt()),
                fontSize = 40.sp, fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            if (trailingValue > 0) {
                Text(
                    text = "Previous: ${Formatting.formatCurrency(trailingValue)}",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            topProvider?.let { tp ->
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ProviderAvatar(providerKey = tp.provider, size = 16)
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text("Top: ${tp.provider} — ${Formatting.formatCurrency(tp.totalCost)}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
fun VelocityForecastCard(rollups: UsageRollups) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Text("Velocity Forecast", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            Text("30d burn rate: ${Formatting.formatCurrency(rollups.thirtyDays)}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
fun QuotaPulseCard(snapshots: List<ProviderQuotaSnapshot>, onChipClick: () -> Unit) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Text("Quota Pulse", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            if (snapshots.isEmpty()) {
                Text("No quotas configured", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                    items(snapshots) { snap ->
                        QuotaProviderChip(snapshot = snap, onClick = onChipClick)
                    }
                }
            }
        }
    }
}

@Composable
fun TrendAtlasCard(rollups: UsageRollups) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Text("Trend Atlas", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            if (rollups.dailyPoints.isNotEmpty()) {
                Text("${rollups.dailyPoints.size} days tracked", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Text("No daily data yet", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
fun HermesQuickAskCard(onQuickPrompt: (String) -> Unit, onOpenChat: () -> Unit) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(18.dp), tint = AuroraColors.hermesMercury)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text("Hermes Quick Ask", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                items(listOf("What's my burn?", "Top providers", "Forecast spend", "Recent activity")) { prompt ->
                    SuggestionChip(onClick = { onQuickPrompt(prompt) }, label = { Text(prompt, fontSize = 12.sp) })
                }
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            TextButton(onClick = onOpenChat) { Text("Open Hermes") }
        }
    }
}

@Composable
fun RecentSessionsStripCard(onSeeAll: () -> Unit) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Row(modifier = Modifier.padding(AuroraSpacing.md.dp).fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Recent Sessions", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            TextButton(onClick = onSeeAll) { Text("See All") }
        }
    }
}

@Composable
fun QuotaProviderChip(snapshot: ProviderQuotaSnapshot, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Row(modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            ProviderAvatar(providerKey = snapshot.provider, size = 16)
            Spacer(modifier = Modifier.width(4.dp))
            Column {
                Text(snapshot.accountLabel ?: snapshot.provider, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                Text("${snapshot.quotaRemaining.toInt()} / ${snapshot.quotaLimit.toInt()}", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

// ── TimelineScope extensions for flat UsageRollups ──

private fun TimelineScope.valueFor(rollups: UsageRollups): Double = when (this) {
    TimelineScope.DAY -> rollups.today
    TimelineScope.WEEK -> rollups.sevenDays
    TimelineScope.MONTH -> rollups.thirtyDays
}

private fun TimelineScope.trailingValueFor(rollups: UsageRollups): Double = when (this) {
    TimelineScope.DAY -> rollups.today
    TimelineScope.WEEK -> rollups.sevenDays
    TimelineScope.MONTH -> rollups.thirtyDays
}
