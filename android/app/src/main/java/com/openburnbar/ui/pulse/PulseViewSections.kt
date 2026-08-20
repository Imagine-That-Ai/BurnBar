// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.models.UsageDisplayMode
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.policy.MobileProductCardDisposition
import com.openburnbar.data.policy.MobileProductSurfacePolicy
import com.openburnbar.data.policy.MobilePulseLoadPresentation
import com.openburnbar.data.policy.MobilePulseWindowPolicy
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.ui.components.DemoDataPromptCard
import com.openburnbar.ui.hermes.rememberAccountScopedHermesService
import com.openburnbar.ui.pulse.atlas.TrendAtlasCard
import com.openburnbar.ui.pulse.layout.HomeLivingLayout
import com.openburnbar.ui.pulse.layout.HomeSlot
import com.openburnbar.ui.theme.AuroraSpacing
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

internal data class PulseContentModel(
    val rollups: UsageRollups?,
    val displayMode: UsageDisplayMode,
    val timelineScope: PulseTimelineScope,
    val liveMetricsStore: PulseLiveMetricsStore,
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
internal fun PulseViewDataEffects(
    isSignedIn: Boolean,
    dashboardStore: DashboardStore,
    quotaStore: QuotaStore,
    activityStore: ActivityStore,
    liveMetricsStore: PulseLiveMetricsStore,
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

    LaunchedEffect(isSignedIn) {
        if (!isSignedIn) return@LaunchedEffect
        // The 1Hz clock lives in PulseLiveMetricsStore; the Firestore live
        // listener only restarts when the hour-quantized window start moves.
        liveMetricsStore.tick
            .map { it.liveUsageQueryStartMillis }
            .distinctUntilChanged()
            .collect { activityStore.startLiveUsageListening(it) }
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
private fun PulseRefreshErrorBanner(message: String, onRetry: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Text(
            text = "Couldn't refresh usage",
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = message,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
            maxLines = 2,
        )
        Text(
            text = "Retry",
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.clickable(onClick = onRetry),
        )
    }
}

@Composable
internal fun PulseViewScaffold(state: PulseViewScaffoldState, content: @Composable () -> Unit) {
    Box(modifier = Modifier.fillMaxSize()) {
        PulseDepthBackdrop()

        Column(modifier = Modifier.fillMaxSize()) {
            if (state.isSignedIn) {
                PulseViewTitleBar(photoUrl = state.photoUrl, displayName = state.displayName)
            }

            val presentation = MobilePulseWindowPolicy.loadPresentation(
                isLoading = state.isLoading,
                failed = state.error != null,
                hasCachedData = state.rollups != null,
            )
            val mayRetry = MobileProductSurfacePolicy.disposition("pulse.retry") ==
                MobileProductCardDisposition.REAL

            if (presentation == MobilePulseLoadPresentation.STALE_REFRESH_FAILED && state.error != null) {
                PulseRefreshErrorBanner(
                    message = state.error,
                    onRetry = if (mayRetry) state.onRetry else ({}),
                )
            }

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                content()
            }
        }
    }
}

@Composable
private fun PulseViewTitleBar(photoUrl: String?, displayName: String?) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.LG.dp)
            .padding(top = AuroraSpacing.MD.dp, bottom = AuroraSpacing.SM.dp),
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
internal fun PulseViewContent(model: PulseContentModel, navigation: PulseContentNavigation) {
    val derived = rememberPulseViewContentDerived(model)

    val slots = remember(derived, model.rollups, model.displayMode, model.timelineScope) {
        buildList {
            if (derived.shouldOfferDemoData) {
                add(
                    HomeSlot(
                        id = "demo_prompt",
                        rank = 5,
                        floor = 60f,
                        ideal = 72f,
                        spans = true,
                        isAmbient = true,
                    ),
                )
            }
            add(
                HomeSlot(
                    id = "controls",
                    rank = 0,
                    floor = 40f,
                    ideal = 44f,
                    spans = true,
                ),
            )
            if (model.rollups != null) {
                add(
                    HomeSlot(
                        id = "hero",
                        rank = 0,
                        floor = 180f,
                        ideal = 240f,
                        spans = true,
                        stretch = 1.0,
                    ),
                )
                add(
                    HomeSlot(
                        id = "forecast",
                        rank = 2,
                        floor = 140f,
                        ideal = 180f,
                        stretch = 0.5,
                    ),
                )
            }
            if (derived.snapshots.isNotEmpty()) {
                add(
                    HomeSlot(
                        id = "quota",
                        rank = 1,
                        floor = 120f,
                        ideal = 200f,
                        rows = HomeSlot.RowAppetite(
                            available = derived.snapshots.size,
                            baseline = 2,
                            unit = 36f,
                            ceiling = 8,
                        ),
                        stretch = 1.0,
                    ),
                )
            }
            if (model.rollups != null) {
                add(
                    HomeSlot(
                        id = "atlas",
                        rank = 3,
                        floor = 180f,
                        ideal = 240f,
                        stretch = 1.0,
                    ),
                )
            }
            add(
                HomeSlot(
                    id = "hermes",
                    rank = 4,
                    floor = 140f,
                    ideal = 180f,
                    stretch = 0.5,
                ),
            )
            if (derived.recentUsages.isNotEmpty()) {
                add(
                    HomeSlot(
                        id = "sessions",
                        rank = 0,
                        floor = 120f,
                        ideal = 220f,
                        rows = HomeSlot.RowAppetite(
                            available = derived.recentUsages.size,
                            baseline = 3,
                            unit = 40f,
                            ceiling = 12,
                        ),
                        stretch = 1.0,
                    ),
                )
            }
        }
    }

    HomeLivingLayout(
        slots = slots,
        modifier = Modifier.fillMaxSize(),
    ) { slotId, _ ->
        when (slotId) {
            "demo_prompt" -> PulseViewDemoPromptSection(
                visible = derived.shouldOfferDemoData,
                isLoading = model.demoIsSeeding,
                message = model.demoMessage,
                error = model.demoError,
                onLoadDemoData = navigation.onLoadDemoData,
                onDismissStatus = navigation.onDismissDemoStatus,
            )
            "controls" -> PulseViewControlsSection(
                timelineScope = model.timelineScope,
                displayMode = model.displayMode,
                onTimelineChange = navigation.onTimelineChange,
                onDisplayModeChange = navigation.onDisplayModeChange,
            )
            "hero" -> model.rollups?.let {
                PulseViewHeroSection(model = model, rollups = it, derived = derived)
            }
            "forecast" -> model.rollups?.let {
                PulseViewForecastSection(rollups = it, pulseUsages = derived.pulseUsages)
            }
            "quota" -> PulseViewQuotaSection(
                snapshots = derived.snapshots,
                onNavigateToBurn = navigation.onNavigateToBurn,
            )
            "atlas" -> model.rollups?.let {
                PulseViewAtlasSection(
                    rollups = it,
                    recentUsages = derived.recentUsages,
                    displayMode = model.displayMode,
                )
            }
            "hermes" -> PulseViewHermesSection(
                hermesService = derived.hermesService,
                onNavigateToHermes = navigation.onNavigateToHermes,
            )
            "sessions" -> PulseViewSessionsSection(
                recentUsages = derived.recentUsages,
                onNavigateToStreams = navigation.onNavigateToStreams,
            )
        }
    }
}

@Composable
private fun rememberPulseViewContentDerived(model: PulseContentModel): PulseViewContentDerived {
    val snapshots by model.quotaStore.snapshots.collectAsState()
    val recentUsages by model.activityStore.usages.collectAsState()
    val liveUsages by model.activityStore.liveUsages.collectAsState()
    val pulseUsages = pulseUsagesForDisplay(liveUsages = liveUsages, recentUsages = recentUsages)
    val hermesService = rememberAccountScopedHermesService()
    return PulseViewContentDerived(
        snapshots = snapshots,
        recentUsages = recentUsages,
        pulseUsages = pulseUsages,
        shouldOfferDemoData = shouldOfferPulseDemoData(model.rollups, snapshots, pulseUsages),
        topProvider = model.rollups?.topProviders?.firstOrNull(),
        hermesService = hermesService,
    )
}

/**
 * The usage rows the Pulse hero/forecast aggregate over: the live listener
 * window when it has data, otherwise the paged recents (cold start, listener
 * still attaching). Extracted for unit tests.
 */
internal fun pulseUsagesForDisplay(
    liveUsages: List<com.openburnbar.data.models.TokenUsage>,
    recentUsages: List<com.openburnbar.data.models.TokenUsage>,
): List<com.openburnbar.data.models.TokenUsage> = liveUsages.ifEmpty { recentUsages }

/**
 * The demo-data prompt shows only for a genuinely empty account: no rollups,
 * no quota snapshots, and no usage rows on either feed. Extracted for unit
 * tests.
 */
internal fun shouldOfferPulseDemoData(
    rollups: com.openburnbar.data.models.UsageRollups?,
    snapshots: List<com.openburnbar.data.models.ProviderQuotaSnapshot>,
    pulseUsages: List<com.openburnbar.data.models.TokenUsage>,
): Boolean = (rollups == null || rollups.isEmpty()) && snapshots.isEmpty() && pulseUsages.isEmpty()

private data class PulseViewContentDerived(
    val snapshots: List<com.openburnbar.data.models.ProviderQuotaSnapshot>,
    val recentUsages: List<com.openburnbar.data.models.TokenUsage>,
    val pulseUsages: List<com.openburnbar.data.models.TokenUsage>,
    val shouldOfferDemoData: Boolean,
    val topProvider: com.openburnbar.data.models.RollupSummary?,
    val hermesService: HermesService,
)

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
    DemoDataPromptCard(
        isLoading = isLoading,
        message = message,
        error = error,
        onLoadDemoData = onLoadDemoData,
        onDismissStatus = onDismissStatus,
    )
}

@Composable
private fun PulseViewControlsSection(
    timelineScope: PulseTimelineScope,
    displayMode: UsageDisplayMode,
    onTimelineChange: (PulseTimelineScope) -> Unit,
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.LG.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TimelineScopePicker(selected = timelineScope, onSelect = onTimelineChange)
        Spacer(modifier = Modifier.weight(1f))
        PulseDisplayModeToggle(displayMode = displayMode, onToggle = onDisplayModeChange)
    }
}

@Composable
private fun PulseViewHeroSection(model: PulseContentModel, rollups: UsageRollups, derived: PulseViewContentDerived) {
    // The 1Hz tick state is read only inside this leaf, so the live clock
    // recomposes the hero card alone instead of restarting the whole
    // Pulse tree (and the O(N) window aggregation runs in the store).
    val tick = model.liveMetricsStore.collectLiveTick(
        timelineScope = model.timelineScope,
        rollups = rollups,
        usages = derived.pulseUsages,
    )
    PulseHeroBurnCard(
        metrics =
        PulseHeroCardMetrics(
            displayMode = model.displayMode,
            value = tick.windowMetrics.value,
            trailingValue = tick.windowMetrics.trailingValue,
            tokenValue = tick.windowMetrics.tokenValue,
            trailingTokenValue = tick.windowMetrics.trailingTokenValue,
            requestValue = tick.windowMetrics.requestValue,
            totals = rollups.totals,
            timelineScope = model.timelineScope,
            topProvider = derived.topProvider,
            liveUsages = derived.pulseUsages,
            dailyPoints = rollups.dailyPoints,
            nowMillis = tick.nowMillis,
        ),
    )
}

@Composable
private fun PulseLiveMetricsStore.collectLiveTick(
    timelineScope: PulseTimelineScope,
    rollups: UsageRollups,
    usages: List<com.openburnbar.data.models.TokenUsage>,
): PulseLiveTick {
    // The in-composition push plus `key` re-keying the collector keep input
    // changes (scope taps, usage snapshots) skew-free within the same frame —
    // matching the old synchronous in-composition aggregation — while the
    // store's ticker owns the 1Hz updates between input changes.
    return key(timelineScope, rollups, usages) {
        remember { updateInputs(timelineScope = timelineScope, rollups = rollups, usages = usages) }
        val current by tick.collectAsState()
        current
    }
}

@Composable
private fun PulseViewForecastSection(rollups: UsageRollups, pulseUsages: List<com.openburnbar.data.models.TokenUsage>) {
    VelocityForecastCard(rollups = rollups, liveUsages = pulseUsages)
}

@Composable
private fun PulseViewQuotaSection(snapshots: List<com.openburnbar.data.models.ProviderQuotaSnapshot>, onNavigateToBurn: (() -> Unit)?) {
    QuotaPulseCard(
        snapshots = snapshots,
        onSelect = { onNavigateToBurn?.invoke() },
        onOpenBurn = { onNavigateToBurn?.invoke() },
    )
}

@Composable
private fun PulseViewAtlasSection(rollups: UsageRollups, recentUsages: List<com.openburnbar.data.models.TokenUsage>, displayMode: UsageDisplayMode) {
    TrendAtlasCard(
        rollups = rollups,
        recentUsages = recentUsages,
        displayMode = displayMode,
        modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
    )
}

@Composable
private fun PulseViewHermesSection(hermesService: HermesService, onNavigateToHermes: (() -> Unit)?) {
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

@Composable
private fun PulseViewSessionsSection(recentUsages: List<com.openburnbar.data.models.TokenUsage>, onNavigateToStreams: (() -> Unit)?) {
    RecentSessionsStripCard(
        sessions = recentUsages,
        onSelect = { onNavigateToStreams?.invoke() },
        onSeeAll = { onNavigateToStreams?.invoke() },
    )
}
