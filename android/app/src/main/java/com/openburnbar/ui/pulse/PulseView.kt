package com.openburnbar.ui.pulse

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.models.*
import com.openburnbar.data.stores.ActivityStore
import com.openburnbar.data.stores.DashboardStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.*
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting
import java.util.Locale
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PulseView(
    dashboardStore: DashboardStore = viewModel(),
    quotaStore: QuotaStore = viewModel(),
    activityStore: ActivityStore = viewModel(),
    demoDataStore: DemoDataStore = viewModel(),
    onNavigateToBurn: (() -> Unit)? = null,
    onNavigateToHermes: (() -> Unit)? = null,
    onNavigateToStreams: (() -> Unit)? = null,
    userStore: UserStore = viewModel()
) {
    val rollups by dashboardStore.rollups.collectAsState()
    val isLoading by dashboardStore.isLoading.collectAsState()
    val error by dashboardStore.error.collectAsState()
    val demoIsSeeding by demoDataStore.isSeeding.collectAsState()
    val demoMessage by demoDataStore.message.collectAsState()
    val demoError by demoDataStore.error.collectAsState()
    var timelineScope by remember { mutableStateOf(PulseTimelineScope.DAY) }
    var displayMode by remember { mutableStateOf(UsageDisplayMode.CURRENCY) }
    var liveNowMillis by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var liveUsageStartMillis by remember { mutableLongStateOf(livePulseUsageQueryStartMillis(liveNowMillis)) }
    val currentUser by userStore.user.collectAsState()

    LaunchedEffect(currentUser.isSignedIn) {
        if (currentUser.isSignedIn) {
            dashboardStore.load()
            quotaStore.load()
            activityStore.loadInitial(pageSize = 250)
        } else {
            activityStore.stopListening()
        }
    }

    LaunchedEffect(currentUser.isSignedIn, liveUsageStartMillis) {
        if (currentUser.isSignedIn) {
            activityStore.startLiveUsageListening(liveUsageStartMillis)
        }
    }

    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000L)
            val now = System.currentTimeMillis()
            liveNowMillis = now
            val queryStart = livePulseUsageQueryStartMillis(now)
            if (queryStart != liveUsageStartMillis) {
                liveUsageStartMillis = queryStart
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Soft, brand-tinted depth layer that lives behind the card stack so
        // the Pulse scroll feels composed instead of pale-and-flat.
        PulseDepthBackdrop()

        // Title bar — centered "Pulse" with avatar in the top-right (mirrors iOS).
        if (currentUser.isSignedIn) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = AuroraSpacing.lg.dp)
                    .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.sm.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = "Pulse",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onBackground
                )
                Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                    UserAvatarBubble(
                        photoUrl = currentUser.photoUrl,
                        displayName = currentUser.displayName,
                        size = 36.dp
                    )
                }
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
                    nowMillis = liveNowMillis,
                    quotaStore = quotaStore,
                    activityStore = activityStore,
                    demoIsSeeding = demoIsSeeding,
                    demoMessage = demoMessage,
                    demoError = demoError,
                    onDisplayModeChange = { displayMode = it },
                    onTimelineChange = { timelineScope = it },
                    onLoadDemoData = {
                        demoDataStore.seed {
                            dashboardStore.refresh()
                            quotaStore.refresh()
                            activityStore.loadInitial(pageSize = 250)
                        }
                    },
                    onDismissDemoStatus = { demoDataStore.clearStatus() },
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
    timelineScope: PulseTimelineScope,
    nowMillis: Long,
    quotaStore: QuotaStore,
    activityStore: ActivityStore,
    demoIsSeeding: Boolean,
    demoMessage: String?,
    demoError: String?,
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
    onTimelineChange: (PulseTimelineScope) -> Unit,
    onLoadDemoData: () -> Unit,
    onDismissDemoStatus: () -> Unit,
    onNavigateToBurn: (() -> Unit)?,
    onNavigateToHermes: (() -> Unit)?,
    onNavigateToStreams: (() -> Unit)?
) {
    val snapshots by quotaStore.snapshots.collectAsState()
    val recentUsages by activityStore.usages.collectAsState()
    val liveUsages by activityStore.liveUsages.collectAsState()
    val pulseUsages = liveUsages.ifEmpty { recentUsages }
    val shouldOfferDemoData = rollups.isEmpty() && snapshots.isEmpty() && pulseUsages.isEmpty()

    val windowMetrics = pulseWindowMetrics(
        scope = timelineScope,
        rollups = rollups,
        recentUsages = pulseUsages,
        nowMillis = nowMillis
    )
    val topProvider = rollups.topProviders.firstOrNull()
    val dailyPoints = rollups.dailyPoints

    Column(
        modifier = Modifier
            .verticalScroll(rememberScrollState())
            .padding(bottom = 128.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
    ) {
        // Reserve room for the "Hi, <user>" greeting that's drawn as an
        // overlay in the parent Box at top — otherwise the hero card slides
        // up underneath it and the texts collide.
        Spacer(modifier = Modifier.height(72.dp))

        if (shouldOfferDemoData) {
            StaggeredEntrance(delay = 0) {
                DemoDataPromptCard(
                    isLoading = demoIsSeeding,
                    message = demoMessage,
                    error = demoError,
                    onLoadDemoData = onLoadDemoData,
                    onDismissStatus = onDismissDemoStatus
                )
            }
        }

        StaggeredEntrance(delay = 0) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = AuroraSpacing.lg.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TimelineScopePicker(
                    selected = timelineScope,
                    onSelect = onTimelineChange
                )
                Spacer(modifier = Modifier.weight(1f))
                PulseDisplayModeToggle(
                    displayMode = displayMode,
                    onToggle = onDisplayModeChange
                )
            }
        }

        StaggeredEntrance(delay = 25) {
            PulseHeroBurnCard(
                displayMode = displayMode,
                value = windowMetrics.value,
                trailingValue = windowMetrics.trailingValue,
                tokenValue = windowMetrics.tokenValue,
                trailingTokenValue = windowMetrics.trailingTokenValue,
                requestValue = windowMetrics.requestValue,
                totals = rollups.totals,
                timelineScope = timelineScope,
                topProvider = topProvider,
                liveUsages = pulseUsages,
                dailyPoints = dailyPoints,
                nowMillis = nowMillis,
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
                onSelect = { onNavigateToBurn?.invoke() },
                onOpenBurn = { onNavigateToBurn?.invoke() }
            )
        }

        StaggeredEntrance(delay = 100) {
            com.openburnbar.ui.pulse.atlas.TrendAtlasCard(
                rollups = rollups,
                recentUsages = recentUsages,
                displayMode = displayMode,
                modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
            )
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
    tokenValue: Long,
    trailingTokenValue: Long,
    requestValue: Int,
    totals: Map<String, Double>,
    timelineScope: PulseTimelineScope,
    topProvider: RollupSummary?,
    liveUsages: List<TokenUsage> = emptyList(),
    dailyPoints: Map<String, Double> = emptyMap(),
    nowMillis: Long = System.currentTimeMillis(),
    onDisplayModeChange: (UsageDisplayMode) -> Unit,
    onTimelineChange: (PulseTimelineScope) -> Unit
) {
    val tokens = tokenValue
    val requests = requestValue
    val trailingDivisor = when (timelineScope) {
        PulseTimelineScope.MINUTE,
        PulseTimelineScope.HOUR,
        PulseTimelineScope.DAY,
        PulseTimelineScope.WEEK -> 7.0
        PulseTimelineScope.MONTH -> 30.0
    }
    val trailingAverage = trailingValue / trailingDivisor
    val deltaPct = if (trailingAverage > 0) ((value - trailingAverage) / trailingAverage) * 100.0 else 0.0
    val isBelow = deltaPct < 0
    val absDelta = kotlin.math.abs(deltaPct)

    val accent = providerAccentColor(topProvider?.provider)
    val isLive = timelineScope == PulseTimelineScope.MINUTE ||
        timelineScope == PulseTimelineScope.HOUR ||
        timelineScope == PulseTimelineScope.DAY

    val burnRateText: String? = remember(displayMode, liveUsages, nowMillis) {
        when (displayMode) {
            UsageDisplayMode.CURRENCY -> PulseBurnRate.dollarsPerMinute(liveUsages, nowMillis)?.let { rate ->
                if (rate < 0.01) "<$0.01/min" else String.format(Locale.getDefault(), "$%.2f/min", rate)
            }
            UsageDisplayMode.TOKENS -> PulseBurnRate.tokensPerMinute(liveUsages, nowMillis)?.let { rate ->
                "${Formatting.formatTokens(rate.toLong())}/min"
            }
        }
    }

    Box(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        AuroraGlassCard(
            modifier = Modifier.fillMaxWidth(),
            cornerRadius = AuroraRadius.xl,
            contentPadding = AuroraSpacing.lg.dp
        ) {
            Box(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        SectionHeaderRow(
                            label = timelineScope.headerLabel,
                            modifier = Modifier.weight(1f)
                        )
                        if (isLive) {
                            BreathingDot(size = 8, color = AuroraColors.success)
                            Spacer(Modifier.width(8.dp))
                        }
                        burnRateText?.let { rateLabel ->
                            BurnVelocityPill(
                                icon = if (displayMode == UsageDisplayMode.CURRENCY) "$" else "#",
                                text = rateLabel,
                                accent = accent
                            )
                            Spacer(Modifier.width(if (topProvider != null) 64.dp else 0.dp))
                        }
                    }

                    Spacer(Modifier.height(AuroraSpacing.sm.dp))

                    GradientCurrency(
                        text = if (displayMode == UsageDisplayMode.CURRENCY) Formatting.formatCurrency(value)
                               else Formatting.formatTokens(tokens),
                        fontSize = 56
                    )

                    Spacer(Modifier.height(AuroraSpacing.xs.dp))

                    MetaRow(text = "${Formatting.formatTokens(tokens)} tokens · $requests requests")

                    if (trailingValue > 0) {
                        Spacer(Modifier.height(AuroraSpacing.sm.dp))
                        DeltaBadge(percent = absDelta, isBelow = isBelow)
                    }

                    Spacer(Modifier.height(AuroraSpacing.md.dp))

                    PulseLiveCostCurve(
                        usages = liveUsages,
                        dailyPoints = dailyPoints,
                        scope = timelineScope,
                        displayMode = displayMode,
                        nowMillis = nowMillis,
                        accent = accent
                    )

                    Spacer(Modifier.height(AuroraSpacing.sm.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        StreamingLine(modifier = Modifier.weight(1f))
                        if (requests > 0) {
                            CallsPill(count = requests)
                        }
                    }

                    if (trailingValue > 0) {
                        Spacer(Modifier.height(AuroraSpacing.sm.dp))
                        ComparisonLine(
                            text = "${if (isBelow) "Below" else "Above"} ${absDelta.toInt()}% your ${trailingWindowLabel(timelineScope)} average",
                            isBelow = isBelow
                        )
                    }
                }

                // Provider halo + avatar (top-right)
                topProvider?.let { tp ->
                    ProviderHaloAvatar(
                        providerKey = tp.provider,
                        accent = accent,
                        modifier = Modifier.align(Alignment.TopEnd)
                    )
                }
            }
        }
    }
}

@Composable
private fun BurnVelocityPill(
    icon: String,
    text: String,
    accent: Color
) {
    val transition = rememberInfiniteTransition(label = "burn-rate")
    val breathing by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1600, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "breathing"
    )
    val bgAlpha = 0.14f + 0.08f * breathing
    Surface(
        shape = CircleShape,
        color = accent.copy(alpha = bgAlpha),
        border = BorderStroke(0.5.dp, accent.copy(alpha = 0.4f))
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp)
        ) {
            Text(
                text = icon,
                fontSize = 10.sp,
                fontWeight = FontWeight.ExtraBold,
                color = accent
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = text,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = accent
            )
        }
    }
}

@Composable
private fun CallsPill(count: Int) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.65f),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.GraphicEq,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(10.dp)
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = "$count",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(Modifier.width(4.dp))
            Text(
                text = "calls",
                fontSize = 10.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun ProviderHaloAvatar(
    providerKey: String,
    accent: Color,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier.size(120.dp), contentAlignment = Alignment.Center) {
        // Soft radial halo so the avatar reads as a warm spotlight rather
        // than a circle floating in beige.
        Canvas(modifier = Modifier.fillMaxSize()) {
            val r = size.minDimension / 2f
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        accent.copy(alpha = 0.55f),
                        accent.copy(alpha = 0.18f),
                        Color.Transparent
                    ),
                    center = Offset(size.width / 2f, size.height / 2f),
                    radius = r
                ),
                radius = r,
                center = Offset(size.width / 2f, size.height / 2f)
            )
        }
        ProviderAuroraAvatar(
            providerKey = providerKey,
            size = 52
        )
    }
}

private fun providerAccentColor(providerKey: String?): Color {
    if (providerKey.isNullOrBlank()) return AuroraColors.ember
    return when (providerKey.lowercase()) {
        "openai" -> Color(0xFF74AA9C)
        "anthropic", "claude" -> Color(0xFFD97757)
        "google", "gemini" -> Color(0xFF4285F4)
        "cursor" -> Color(0xFF6E6E73)
        "codex" -> AuroraColors.whimsy
        "openrouter" -> AuroraColors.amber
        "zai" -> AuroraColors.whimsy
        "factory" -> AuroraColors.teal
        "kimi" -> AuroraColors.purple
        else -> AuroraColors.ember
    }
}

private fun trailingWindowLabel(scope: PulseTimelineScope): String = when (scope) {
    PulseTimelineScope.MINUTE,
    PulseTimelineScope.HOUR,
    PulseTimelineScope.DAY -> "7-day"
    PulseTimelineScope.WEEK -> "30-day"
    PulseTimelineScope.MONTH -> "90-day"
}

@Composable
fun VelocityForecastCard(rollups: UsageRollups) {
    // End-of-Day projection: scale today's spend by elapsed-day fraction so the
    // ring fills the way iOS does (17% of day at ~4am, 100% at midnight).
    val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY) +
               java.util.Calendar.getInstance().get(java.util.Calendar.MINUTE) / 60.0
    val dayFraction = (hour / 24.0).coerceIn(0.001, 1.0)
    val projected = rollups.today / dayFraction
    val sevenDayAvg = rollups.sevenDays / 7.0
    val aheadOfPace = projected > sevenDayAvg

    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl,
        contentPadding = AuroraSpacing.lg.dp
    ) {
        SectionHeaderRow(label = "End-of-Day Forecast")
        Spacer(Modifier.height(4.dp))
        Text(
            text = if (aheadOfPace) "Ahead of pace" else "On pace",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(Modifier.height(AuroraSpacing.sm.dp))
        androidx.compose.material3.HorizontalDivider(
            color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f)
        )
        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "PROJECTED",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.6.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(4.dp))
                GradientCurrency(
                    text = Formatting.formatCurrency(projected),
                    fontSize = 36
                )
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Filled.LocalFireDepartment,
                        contentDescription = null,
                        tint = AuroraColors.amber,
                        modifier = Modifier.size(14.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = if (aheadOfPace) "Ahead of pace" else "On pace",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = AuroraColors.amber
                    )
                }
            }

            Spacer(Modifier.width(AuroraSpacing.md.dp))

            MiniRing(
                progress = dayFraction.toFloat(),
                accent = AuroraColors.amber,
                label = "${(dayFraction * 100).toInt()}%",
                sublabel = "of day",
                size = 96.dp,
                strokeWidth = 8.dp
            )
        }
    }
}

// Inline duplicate `QuotaPulseCard` removed — the richer composable in
// `QuotaPulseCard.kt` (with the gradient ring, status rails, and provider
// rows that mirror iOS) is now the only definition Pulse calls.

@Composable
fun UserAvatarBubble(
    photoUrl: String?,
    displayName: String?,
    size: androidx.compose.ui.unit.Dp = 36.dp
) {
    val initials = displayName?.split(" ", "-")
        ?.mapNotNull { it.firstOrNull()?.uppercaseChar() }
        ?.take(2)
        ?.joinToString("")
        ?.takeIf { it.isNotBlank() }

    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(size)
            .clip(androidx.compose.foundation.shape.CircleShape)
            .background(AuroraColors.whimsy.copy(alpha = 0.35f))
            .border(
                width = 1.dp,
                color = AuroraColors.ember.copy(alpha = 0.4f),
                shape = androidx.compose.foundation.shape.CircleShape
            )
    ) {
        if (!photoUrl.isNullOrBlank()) {
            coil.compose.AsyncImage(
                model = photoUrl,
                contentDescription = displayName,
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                modifier = Modifier.size(size).clip(androidx.compose.foundation.shape.CircleShape)
            )
        } else if (initials != null) {
            Text(
                text = initials,
                color = androidx.compose.ui.graphics.Color.White,
                fontSize = (size.value * 0.38f).sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

// Stub `TrendAtlasCard` removed — the real composable lives in
// `ui/pulse/atlas/TrendAtlasCard.kt` and is called directly from `Content`.

@Composable
fun HermesQuickAskCard(onQuickPrompt: (String) -> Unit, onOpenChat: () -> Unit) {
    AuroraGlassCard(modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)) {
        Column() {
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
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Recent Sessions", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            TextButton(onClick = onSeeAll) { Text("See All") }
        }
    }
}

@Composable
fun QuotaProviderChip(snapshot: ProviderQuotaSnapshot, onClick: () -> Unit) {
    val summary = quotaPulseSummary(snapshot)
    Box(
        modifier = Modifier
            .width(140.dp)
            .clickable { onClick() }
            .auroraGlass(
                cornerRadius = 14.dp,
                tintAlpha = 0.34f,
                shadow = AuroraShadows.small
            )
            .padding(horizontal = 10.dp, vertical = 8.dp)
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            ProviderAvatar(providerKey = snapshot.provider, size = 24)
            Text(
                quotaProviderLabel(snapshot),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center
            )
            Text(
                summary.label,
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center
            )
            Text(
                summary.metric,
                fontSize = 14.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                summary.detail,
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center
            )
        }
    }
}

private data class QuotaPulseSummary(
    val label: String,
    val metric: String,
    val detail: String
)

private fun quotaPulseSummary(snapshot: ProviderQuotaSnapshot): QuotaPulseSummary {
    val constrained = snapshot.buckets
        .filter { it.limit > 0 }
        .minByOrNull { maxOf(0.0, it.remaining) / it.limit }

    if (constrained != null) {
        val pct = (maxOf(0.0, constrained.remaining) / constrained.limit * 100).toInt()
        val label = quotaBucketLabel(constrained)
        return QuotaPulseSummary(
            label = label,
            metric = "$pct% left",
            detail = "Remaining: ${formatQuotaAmount(constrained.remaining, constrained.name)} of ${formatQuotaAmount(constrained.limit, constrained.name)}"
        )
    }

    val unlimited = snapshot.buckets.firstOrNull { it.limit < 0 }
    if (unlimited != null) {
        return QuotaPulseSummary(
            label = quotaBucketLabel(unlimited),
            metric = "Unlimited",
            detail = "Used: ${formatQuotaAmount(unlimited.used, unlimited.name)}"
        )
    }

    return QuotaPulseSummary(
        label = "Quota",
        metric = "No signal",
        detail = "Status: ${snapshot.statusMessage ?: "waiting"}"
    )
}

private fun formatQuotaAmount(value: Double, bucketName: String): String {
    val rounded = value.toLong()
    return if (bucketName.contains("token", ignoreCase = true)) {
        Formatting.formatTokens(rounded)
    } else {
        rounded.toString()
    }
}

private fun quotaBucketLabel(bucket: QuotaBucket): String {
    val name = bucket.name.trim().lowercase()
    val window = bucket.window?.trim()?.lowercase().orEmpty()
    return when {
        name.contains("five") && name.contains("hour") -> "5h quota"
        name.contains("seven") || name.contains("week") || window.contains("week") -> "weekly quota"
        name.contains("day") || window.contains("day") -> "daily quota"
        name.contains("request") -> "request quota"
        name.contains("token") -> "token quota"
        name.isNotBlank() -> humanizedQuotaLabel(name)
        window.isNotBlank() -> "${humanizedQuotaLabel(window)} quota"
        else -> "quota"
    }
}

private fun humanizedQuotaLabel(value: String): String {
    val words = value
        .replace('_', ' ')
        .replace('-', ' ')
        .trim()
        .split(Regex("\\s+"))
        .filter { it.isNotBlank() }
    if (words.isEmpty()) return "quota"
    val label = words.joinToString(" ")
    return if (label.equals("default", ignoreCase = true) || label.equals("quota", ignoreCase = true)) {
        "account quota"
    } else if (label.contains("quota", ignoreCase = true)) {
        label
    } else {
        "$label quota"
    }
}

private fun quotaProviderLabel(snapshot: ProviderQuotaSnapshot): String {
    val label = snapshot.accountLabel?.takeIf { it.isNotBlank() }
    if (label != null) return label
    return AgentProvider.fromKey(snapshot.provider)?.displayName ?: snapshot.provider
}
