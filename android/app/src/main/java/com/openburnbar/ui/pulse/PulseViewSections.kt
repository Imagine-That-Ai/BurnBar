@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ShowChart
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.ui.components.DemoDataPromptCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.components.ShimmerCard
import com.openburnbar.ui.components.StaggeredEntrance
import com.openburnbar.ui.pulse.atlas.TrendAtlasCard
import com.openburnbar.ui.theme.AuroraSpacing
import kotlinx.coroutines.delay

internal data class PulseContentModel(
    val rollups: UsageRollups,
    val displayMode: UsageDisplayMode,
    val timelineScope: PulseTimelineScope,
    val nowMillis: Long,
    val quotaStore: QuotaStore,
    val activityStore: ActivityStore,
    val demoIsSeeding: Boolean,
    val demoMessage: String?,
    val demoError: String?,
)

internal data class PulseContentNavigation(
    val onDisplayModeChange: (UsageDisplayMode) -> Unit,
    val onTimelineChange: (PulseTimelineScope) -> Unit,
    val onLoadDemoData: () -> Unit,
    val onDismissDemoStatus: () -> Unit,
    val onNavigateToBurn: (() -> Unit)?,
    val onNavigateToHermes: (() -> Unit)?,
    val onNavigateToStreams: (() -> Unit)?,
)

@Composable
internal fun PulseViewLiveClock(onTick: (Long, Long) -> Unit) {
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000L)
            val now = System.currentTimeMillis()
            val queryStart = livePulseUsageQueryStartMillis(now)
            onTick(now, queryStart)
        }
    }
}

@Composable
internal fun PulseViewDataEffects(
    isSignedIn: Boolean,
    dashboardStore: DashboardStore,
    quotaStore: QuotaStore,
    activityStore: ActivityStore,
    liveUsageStartMillis: Long,
) {
    LaunchedEffect(isSignedIn) {
        if (isSignedIn) {
            dashboardStore.load()
            quotaStore.load()
            activityStore.loadInitial(pageSize = 250)
        } else {
            activityStore.stopListening()
        }
    }

    LaunchedEffect(isSignedIn, liveUsageStartMillis) {
        if (isSignedIn) {
            activityStore.startLiveUsageListening(liveUsageStartMillis)
        }
    }
}

internal data class PulseViewScaffoldState(
    val isSignedIn: Boolean,
    val photoUrl: String?,
    val displayName: String?,
    val isLoading: Boolean,
    val error: String?,
    val rollups: UsageRollups?,
    val onRetry: () -> Unit,
)

@Composable
internal fun PulseViewScaffold(
    state: PulseViewScaffoldState,
    content: @Composable () -> Unit,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        PulseDepthBackdrop()

        if (state.isSignedIn) {
            PulseViewTitleBar(photoUrl = state.photoUrl, displayName = state.displayName)
        }

        when {
            state.isLoading && state.rollups == null -> PulseViewLoadingSkeleton()
            state.error != null && state.rollups == null ->
                ErrorStateView(
                    icon = Icons.Filled.Error,
                    title = "Couldn't Load Dashboard",
                    message = state.error,
                    onRetry = state.onRetry,
                )
            state.rollups == null ->
                EmptyStateView(
                    icon = Icons.Filled.ShowChart,
                    title = "No Usage Data",
                    message = "Start using AI to see your burn here.",
                )
            else -> content()
        }
    }
}

@Composable
private fun PulseViewTitleBar(photoUrl: String?, displayName: String?) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = "Pulse",
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
            UserAvatarBubble(
                photoUrl = photoUrl,
                displayName = displayName,
                size = 36.dp,
            )
        }
    }
}

@Composable
private fun PulseViewLoadingSkeleton() {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(top = 80.dp, start = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        ShimmerCard(height = 180)
        ShimmerCard(height = 80)
        ShimmerCard(height = 120)
    }
}

@Composable
internal fun PulseViewContent(model: PulseContentModel, navigation: PulseContentNavigation) {
    val derived = rememberPulseViewContentDerived(model)
    PulseViewContentColumn(model = model, navigation = navigation, derived = derived)
}

@Composable
private fun rememberPulseViewContentDerived(model: PulseContentModel): PulseViewContentDerived {
    val snapshots by model.quotaStore.snapshots.collectAsState()
    val recentUsages by model.activityStore.usages.collectAsState()
    val liveUsages by model.activityStore.liveUsages.collectAsState()
    val pulseUsages = liveUsages.ifEmpty { recentUsages }
    val windowMetrics =
        pulseWindowMetrics(
            scope = model.timelineScope,
            rollups = model.rollups,
            recentUsages = pulseUsages,
            nowMillis = model.nowMillis,
        )
    val context = LocalContext.current
    val hermesService = androidx.compose.runtime.remember(context) {
        HermesService(appContext = context.applicationContext)
    }
    return PulseViewContentDerived(
        snapshots = snapshots,
        recentUsages = recentUsages,
        pulseUsages = pulseUsages,
        shouldOfferDemoData = model.rollups.isEmpty() && snapshots.isEmpty() && pulseUsages.isEmpty(),
        windowMetrics = windowMetrics,
        topProvider = model.rollups.topProviders.firstOrNull(),
        hermesService = hermesService,
        heroMetrics =
        PulseHeroCardMetrics(
            displayMode = model.displayMode,
            value = windowMetrics.value,
            trailingValue = windowMetrics.trailingValue,
            tokenValue = windowMetrics.tokenValue,
            trailingTokenValue = windowMetrics.trailingTokenValue,
            requestValue = windowMetrics.requestValue,
            totals = model.rollups.totals,
            timelineScope = model.timelineScope,
            topProvider = model.rollups.topProviders.firstOrNull(),
            liveUsages = pulseUsages,
            dailyPoints = model.rollups.dailyPoints,
            nowMillis = model.nowMillis,
        ),
    )
}

private data class PulseViewContentDerived(
    val snapshots: List<com.openburnbar.data.models.ProviderQuotaSnapshot>,
    val recentUsages: List<com.openburnbar.data.models.TokenUsage>,
    val pulseUsages: List<com.openburnbar.data.models.TokenUsage>,
    val shouldOfferDemoData: Boolean,
    val windowMetrics: PulseWindowMetrics,
    val topProvider: com.openburnbar.data.models.RollupSummary?,
    val hermesService: HermesService,
    val heroMetrics: PulseHeroCardMetrics,
)

@Composable
private fun PulseViewContentColumn(
    model: PulseContentModel,
    navigation: PulseContentNavigation,
    derived: PulseViewContentDerived,
) {
    Column(
        modifier =
        Modifier
            .verticalScroll(rememberScrollState())
            .padding(bottom = 128.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        Spacer(modifier = Modifier.height(72.dp))

        PulseViewDemoPromptSection(
            visible = derived.shouldOfferDemoData,
            isLoading = model.demoIsSeeding,
            message = model.demoMessage,
            error = model.demoError,
            onLoadDemoData = navigation.onLoadDemoData,
            onDismissStatus = navigation.onDismissDemoStatus,
        )

        PulseViewControlsSection(
            timelineScope = model.timelineScope,
            displayMode = model.displayMode,
            onTimelineChange = navigation.onTimelineChange,
            onDisplayModeChange = navigation.onDisplayModeChange,
        )

        PulseViewHeroSection(heroMetrics = derived.heroMetrics)

        PulseViewForecastSection(rollups = model.rollups, pulseUsages = derived.pulseUsages)

        PulseViewQuotaSection(
            snapshots = derived.snapshots,
            onNavigateToBurn = navigation.onNavigateToBurn,
        )

        PulseViewAtlasSection(
            rollups = model.rollups,
            recentUsages = derived.recentUsages,
            displayMode = model.displayMode,
        )

        PulseViewHermesSection(
            hermesService = derived.hermesService,
            onNavigateToHermes = navigation.onNavigateToHermes,
        )

        PulseViewSessionsSection(
            recentUsages = derived.recentUsages,
            onNavigateToStreams = navigation.onNavigateToStreams,
        )
    }
}

@Composable
private fun PulseViewDemoPromptSection(
    visible: Boolean,
    isLoading: Boolean,
    message: String?,
    error: String?,
    onLoadDemoData: () -> Unit,
    onDismissStatus: () -> Unit,
) {
    if (!visible) return
    StaggeredEntrance(delay = 0) {
        DemoDataPromptCard(
            isLoading = isLoading,
            message = message,
            error = error,
            onLoadDemoData = onLoadDemoData,
            onDismissStatus = onDismissStatus,
        )
    }
}

@Composable
private fun PulseViewControlsSection(
    timelineScope: PulseTimelineScope,
    displayMode: UsageDisplayMode,
    onTimelineChange: (PulseTimelineScope) -> Unit,
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
) {
    StaggeredEntrance(delay = 0) {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.lg.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TimelineScopePicker(selected = timelineScope, onSelect = onTimelineChange)
            Spacer(modifier = Modifier.weight(1f))
            PulseDisplayModeToggle(displayMode = displayMode, onToggle = onDisplayModeChange)
        }
    }
}

@Composable
private fun PulseViewHeroSection(heroMetrics: PulseHeroCardMetrics) {
    StaggeredEntrance(delay = 25) {
        PulseHeroBurnCard(metrics = heroMetrics)
    }
}

@Composable
private fun PulseViewForecastSection(
    rollups: UsageRollups,
    pulseUsages: List<com.openburnbar.data.models.TokenUsage>,
) {
    StaggeredEntrance(delay = 50) {
        VelocityForecastCard(rollups = rollups, liveUsages = pulseUsages)
    }
}

@Composable
private fun PulseViewQuotaSection(
    snapshots: List<com.openburnbar.data.models.ProviderQuotaSnapshot>,
    onNavigateToBurn: (() -> Unit)?,
) {
    StaggeredEntrance(delay = 75) {
        QuotaPulseCard(
            snapshots = snapshots,
            onSelect = { onNavigateToBurn?.invoke() },
            onOpenBurn = { onNavigateToBurn?.invoke() },
        )
    }
}

@Composable
private fun PulseViewAtlasSection(
    rollups: UsageRollups,
    recentUsages: List<com.openburnbar.data.models.TokenUsage>,
    displayMode: UsageDisplayMode,
) {
    StaggeredEntrance(delay = 100) {
        TrendAtlasCard(
            rollups = rollups,
            recentUsages = recentUsages,
            displayMode = displayMode,
            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        )
    }
}

@Composable
private fun PulseViewHermesSection(
    hermesService: HermesService,
    onNavigateToHermes: (() -> Unit)?,
) {
    StaggeredEntrance(delay = 125) {
        HermesQuickAskCard(
            service = hermesService,
            suggestedPrompts =
            listOf(
                "What's my burn?",
                "Top providers",
                "Forecast spend",
                "Recent activity",
            ),
            onOpenHermes = { onNavigateToHermes?.invoke() },
        )
    }
}

@Composable
private fun PulseViewSessionsSection(
    recentUsages: List<com.openburnbar.data.models.TokenUsage>,
    onNavigateToStreams: (() -> Unit)?,
) {
    StaggeredEntrance(delay = 150) {
        RecentSessionsStripCard(
            sessions = recentUsages,
            onSelect = { onNavigateToStreams?.invoke() },
            onSeeAll = { onNavigateToStreams?.invoke() },
        )
    }
}
