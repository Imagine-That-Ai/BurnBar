package com.openburnbar.ui.burn

import androidx.compose.animation.*
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.*
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.data.stores.UserStore
import com.openburnbar.data.stores.DemoDataStore
import com.openburnbar.data.stores.rememberQuotaDefaultWindow
import com.openburnbar.ui.components.*
import com.openburnbar.ui.theme.*
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting
import kotlin.math.min

@Composable
fun BurnView(
    quotaStore: QuotaStore = viewModel(),
    demoDataStore: DemoDataStore = viewModel()
) {
    val snapshots by quotaStore.snapshots.collectAsState()
    val accounts by quotaStore.accounts.collectAsState()
    val isLoading by quotaStore.isLoading.collectAsState()
    val error by quotaStore.error.collectAsState()
    val demoIsSeeding by demoDataStore.isSeeding.collectAsState()
    val demoMessage by demoDataStore.message.collectAsState()
    val demoError by demoDataStore.error.collectAsState()
    val userStore: UserStore = viewModel()
    val currentUser by userStore.user.collectAsState()

    var detailSnapshot by remember { mutableStateOf<ProviderQuotaSnapshot?>(null) }
    var displayMode by remember { mutableStateOf(UsageDisplayMode.CURRENCY) }
    var selectedPeriod by remember { mutableIntStateOf(0) }
    val periods = listOf("Today", "Week", "Month")

    LaunchedEffect(currentUser.isSignedIn) {
        if (currentUser.isSignedIn) {
            quotaStore.load()
        }
    }

    detailSnapshot?.let { snapshot ->
        ProviderDetailDialog(
            snapshot = snapshot,
            accounts = matchingQuotaAccounts(snapshot, accounts),
            signedInEmail = currentUser.email,
            onDismiss = { detailSnapshot = null }
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        when {
            isLoading && snapshots.isEmpty() -> {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(AuroraSpacing.lg.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
                ) {
                    ShimmerCard(height = 220)
                    ShimmerCard(height = 100)
                    repeat(3) { ShimmerCard(height = 80) }
                }
            }
            error != null && snapshots.isEmpty() -> {
                ErrorStateView(
                    icon = Icons.Filled.Error,
                    title = "Couldn't Load Quota",
                    message = error ?: "",
                    onRetry = { quotaStore.load() }
                )
            }
            !isLoading && snapshots.isEmpty() -> {
                DemoDataEmptyState(
                    isLoading = demoIsSeeding,
                    message = demoMessage,
                    error = demoError,
                    onLoadDemoData = {
                        demoDataStore.seed {
                            quotaStore.refresh()
                        }
                    },
                    onDismissStatus = { demoDataStore.clearStatus() }
                )
            }
            else -> {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = AuroraSpacing.xxl.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
                ) {
                    StaggeredEntrance(delay = 0) {
                        FleetHealthRing(
                            snapshots = snapshots,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.lg.dp)
                        )
                    }

                    StaggeredEntrance(delay = 50) {
                        ChipSelector(
                            items = UsageDisplayMode.entries.toList(),
                            selected = displayMode,
                            onSelect = { displayMode = it },
                            labelProvider = { it.label },
                            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                        )
                    }

                    val urgent = snapshots.filter { it.percentageRemaining <= 25 }
                    if (urgent.isNotEmpty()) {
                        StaggeredEntrance(delay = 75) {
                            UrgentBanner(
                                count = urgent.size,
                                modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                            )
                        }
                    }

                    StaggeredEntrance(delay = 100) {
                        ProviderRingStrip(
                            snapshots = snapshots,
                            onProviderClick = { detailSnapshot = it },
                            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                        )
                    }

                    StaggeredEntrance(delay = 125) {
                        ChipSelector(
                            items = periods,
                            selected = periods[selectedPeriod],
                            onSelect = { selectedPeriod = periods.indexOf(it) },
                            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                        )
                    }

                    StaggeredEntrance(delay = 137) {
                        DefaultWindowSelector(
                            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                        )
                    }

                    snapshots.forEachIndexed { index, snapshot ->
                        StaggeredEntrance(delay = 150 + index * 25) {
                            ProviderAccordionCard(
                                snapshot = snapshot,
                                accounts = matchingQuotaAccounts(snapshot, accounts),
                                signedInEmail = currentUser.email,
                                onOpenDetail = { detailSnapshot = snapshot },
                                modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

// ── Provider Detail Dialog ──
@Composable
fun ProviderDetailDialog(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    signedInEmail: String?,
    onDismiss: () -> Unit
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
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
                    Column(modifier = Modifier.padding(AuroraSpacing.md.dp)) {
                        detailRow("Quota Limit", Formatting.formatTokens(snapshot.quotaLimit.toInt()))
                        detailRow("Used", Formatting.formatTokens((snapshot.quotaLimit - snapshot.quotaRemaining).toInt()))
                        detailRow("Remaining", Formatting.formatTokens(snapshot.quotaRemaining.toInt()))
                        detailRow("% Remaining", "${snapshot.percentageRemaining.toInt()}%")
                        if (!accountName.equals("Account", ignoreCase = true)) {
                            detailRow("Account", accountName)
                        }
                        detailRow("Email", accountEmail ?: "Not provided")
                        detailRow("Status", if (snapshot.isUnlimited) "Unlimited" else "Limited")
                    }
                }

                if (accounts.isNotEmpty() || accountEmail != null || snapshot.accountId != null) {
                    Text("Associated Account", fontWeight = FontWeight.Bold, fontSize = AuroraTypography.caption.sp)
                    if (accounts.isEmpty()) {
                        Card(
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
                                Text(accountEmail ?: accountName, fontWeight = FontWeight.Medium)
                                accountEmail?.let { detailRow("Email", it) }
                                snapshot.accountId?.let { detailRow("Account ID", it) }
                            }
                        }
                    }
                    accounts.forEach { account ->
                        Card(
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
                                Text(account.label.ifEmpty { account.providerId }, fontWeight = FontWeight.Medium)
                                account.identityHint?.let { detailRow("Email", it) }
                                if (account.identityHint == null && account.label.contains("@")) {
                                    detailRow("Email", account.label)
                                }
                                detailRow("Usage", "${Formatting.formatTokens(account.usageUsed.toInt())} / ${Formatting.formatTokens(account.usageLimit.toInt())}")
                                /* routingPolicy not in Firestore ProviderAccountDoc */
                                account.integration?.let { detailRow("Integration", it) }
                                account.status?.let { detailRow("Status", it) }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        }
    )
}

@Composable
private fun detailRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(label, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.Medium)
    }
}

// ── Fleet Health Ring ──
// Beautiful gauge mirroring iOS: gradient stroke ring (no pie), animated
// sweep, semantic accent color (success / warning / error), soft halo behind
// the ring, big rounded percentage at center + tiny supporting label.
@Composable
fun FleetHealthRing(
    snapshots: List<ProviderQuotaSnapshot>,
    modifier: Modifier = Modifier
) {
    val avgRaw = if (snapshots.isNotEmpty()) {
        snapshots.sumOf { it.percentageRemaining } / snapshots.size
    } else 100.0
    val pct = avgRaw.coerceIn(0.0, 100.0).toFloat()
    val urgent = snapshots.count { it.percentageRemaining < 25.0 }

    val (statusColor, statusLabel) = when {
        pct < 25f  -> AuroraColors.error to "Critical"
        pct < 50f  -> AuroraColors.warning to "Strained"
        pct < 75f  -> AuroraColors.amber to "Healthy"
        else       -> AuroraColors.success to "Excellent"
    }

    // Smoothly animate the ring to its target percentage so first paint reads
    // as a sweep-on rather than snapping.
    val sweepProgress by animateFloatAsState(
        targetValue = pct / 100f,
        animationSpec = tween(durationMillis = 900, easing = FastOutSlowInEasing),
        label = "fleet-ring"
    )

    AuroraGlassCard(
        modifier = modifier,
        cornerRadius = AuroraRadius.xl
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "FLEET HEALTH",
                fontWeight = FontWeight.SemiBold,
                fontSize = AuroraTypography.tiny.sp,
                letterSpacing = 1.6.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            AuroraBadge(text = statusLabel, tone = when {
                pct < 25f -> AuroraBadgeTone.Error
                pct < 50f -> AuroraBadgeTone.Warning
                pct < 75f -> AuroraBadgeTone.Accent
                else      -> AuroraBadgeTone.Success
            })
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            FleetRingCanvas(
                progress = sweepProgress,
                accent = statusColor,
                modifier = Modifier.size(132.dp)
            )

            Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "${pct.toInt()}% remaining",
                    fontSize = AuroraTypography.title.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = "${snapshots.size} provider${if (snapshots.size == 1) "" else "s"}" +
                        if (urgent > 0) " · $urgent under pressure" else " · all healthy",
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun FleetRingCanvas(
    progress: Float,
    accent: Color,
    modifier: Modifier = Modifier
) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val stroke = size.minDimension * 0.10f
            val inset = stroke / 2f
            val arcSize = Size(size.width - stroke, size.height - stroke)
            val topLeft = Offset(inset, inset)

            // Soft halo behind the ring
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = 0.16f), Color.Transparent),
                    radius = size.minDimension * 0.55f
                ),
                radius = size.minDimension * 0.5f,
                center = Offset(size.width / 2f, size.height / 2f)
            )

            // Track ring — full circle, dim, thin
            drawArc(
                color = accent.copy(alpha = 0.16f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                size = arcSize,
                topLeft = topLeft,
                style = Stroke(width = stroke, cap = StrokeCap.Round)
            )

            // Foreground sweep — gradient stroke, rounded caps. Start at top
            // (-90°) and sweep clockwise the progress fraction of 360°.
            val sweep = (progress.coerceIn(0f, 1f)) * 360f
            if (sweep > 0f) {
                drawArc(
                    brush = Brush.sweepGradient(
                        colors = listOf(
                            accent.copy(alpha = 0.65f),
                            accent,
                            accent.copy(alpha = 0.85f),
                            accent.copy(alpha = 0.65f)
                        ),
                        center = Offset(size.width / 2f, size.height / 2f)
                    ),
                    startAngle = -90f,
                    sweepAngle = sweep,
                    useCenter = false,
                    size = arcSize,
                    topLeft = topLeft,
                    style = Stroke(width = stroke, cap = StrokeCap.Round)
                )
            }
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "${(progress * 100f).toInt()}%",
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "avg.",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ── Provider Ring Strip ──
@Composable
fun ProviderRingStrip(
    snapshots: List<ProviderQuotaSnapshot>,
    onProviderClick: (ProviderQuotaSnapshot) -> Unit,
    modifier: Modifier = Modifier
) {
    LazyRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        items(snapshots) { snapshot ->
            val provider = AgentProvider.fromKey(snapshot.provider)
            ProviderChip(
                snapshot = snapshot,
                provider = provider,
                onClick = { onProviderClick(snapshot) }
            )
        }
    }
}

@Composable
fun ProviderChip(
    snapshot: ProviderQuotaSnapshot,
    provider: AgentProvider?,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .clickable { onClick() }
            .auroraGlass(
                cornerRadius = AuroraRadius.md.dp,
                tintAlpha = 0.42f,
                shadow = AuroraShadows.small
            )
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ProviderAvatar(providerKey = snapshot.provider, size = 24)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column {
            Text(
                provider?.displayName ?: snapshot.provider,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                "${snapshot.percentageRemaining.toInt()}%",
                fontSize = 11.sp,
                color = if (snapshot.percentageRemaining <= 25) AuroraColors.burnOrange
                        else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ── Urgent Banner ──
@Composable
fun UrgentBanner(count: Int, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = AuroraColors.burnOrange.copy(alpha = 0.15f)
    ) {
        Row(
            modifier = Modifier.padding(AuroraSpacing.md.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = AuroraColors.burnOrange, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text("$count provider(s) below 25% quota", color = AuroraColors.burnOrange, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.Medium)
        }
    }
}

// ── Provider Accordion Card ──
// Mirrors the iOS Pro provider card: by default shows the user's preferred
// bucket window (5h or 7d) inline. Tapping the chevron expands to show every
// bucket the provider exposes (5h + daily + 7d + monthly + requests, etc.).
@Composable
fun ProviderAccordionCard(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    signedInEmail: String?,
    onOpenDetail: () -> Unit,
    modifier: Modifier = Modifier
) {
    val defaultWindow by rememberQuotaDefaultWindow()
    var expanded by remember(snapshot.id) { mutableStateOf(false) }

    val classified = remember(snapshot.buckets) {
        snapshot.buckets.map { it to QuotaWindowKind.infer(it) }
    }
    // Pick the bucket that matches the user's preferred default; fall back to
    // the freshest non-OTHER bucket, then any bucket.
    val primaryBucket = remember(classified, defaultWindow) {
        classified.firstOrNull { it.second == defaultWindow }
            ?: classified.firstOrNull { it.second != QuotaWindowKind.OTHER }
            ?: classified.firstOrNull()
    }
    val expandRotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        animationSpec = AuroraMotion.cardPressSpec(),
        label = "expand-chevron"
    )

    AuroraGlassCard(modifier = modifier) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ProviderAvatar(providerKey = snapshot.provider, size = 36)
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    AgentProvider.fromKey(snapshot.provider)?.displayName ?: snapshot.provider,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    quotaAccountEmail(snapshot, accounts, signedInEmail)
                        ?: quotaAccountName(snapshot, accounts),
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            IconButton(
                onClick = { expanded = !expanded },
                modifier = Modifier.graphicsLayer { rotationZ = expandRotation }
            ) {
                Icon(
                    imageVector = Icons.Filled.KeyboardArrowDown,
                    contentDescription = if (expanded) "Collapse" else "Expand"
                )
            }
        }

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        if (classified.isEmpty()) {
            Text(
                snapshot.statusMessage?.takeIf { it.isNotBlank() } ?: "No quota signal yet.",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else if (!expanded) {
            // Compact: just the user's preferred bucket
            primaryBucket?.let { (bucket, kind) ->
                BucketRow(bucket = bucket, kind = kind)
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                classified.forEach { (bucket, kind) ->
                    BucketRow(bucket = bucket, kind = kind)
                }
                TextButton(onClick = onOpenDetail, modifier = Modifier.align(Alignment.End)) {
                    Text("Open details")
                }
            }
        }
    }
}

@Composable
private fun BucketRow(bucket: QuotaBucket, kind: QuotaWindowKind) {
    val pct = if (bucket.limit > 0) {
        ((bucket.remaining / bucket.limit) * 100).coerceIn(0.0, 100.0).toInt()
    } else if (bucket.limit < 0) -1 // unlimited
    else 0

    val isLow = pct in 0..25
    val barColor = when {
        pct < 0 -> AuroraColors.success
        isLow -> AuroraColors.burnOrange
        pct < 50 -> AuroraColors.warning
        else -> AuroraColors.burnCoral
    }

    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                kind.displayLabel.replaceFirstChar { it.uppercase() },
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                if (pct < 0) "Unlimited"
                else "${formatQuotaValue(bucket.remaining)} / ${formatQuotaValue(bucket.limit)} left",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(
                if (pct < 0) "∞" else "$pct%",
                fontWeight = FontWeight.Bold,
                color = if (isLow) AuroraColors.burnOrange else MaterialTheme.colorScheme.onSurface
            )
            if (pct >= 0) {
                LinearProgressIndicator(
                    progress = { (pct / 100f).coerceIn(0f, 1f) },
                    modifier = Modifier.width(96.dp).height(6.dp).clip(RoundedCornerShape(3.dp)),
                    color = barColor,
                    trackColor = AuroraColors.darkBorder.copy(alpha = 0.35f)
                )
            }
        }
    }
}

private fun formatQuotaValue(v: Double): String {
    val rounded = v.toLong()
    return when {
        v < 1_000 -> rounded.toString()
        v < 1_000_000 -> "%.1fk".format(v / 1_000.0)
        else -> "%.1fM".format(v / 1_000_000.0)
    }
}

@Composable
private fun DefaultWindowSelector(modifier: Modifier = Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember(context) { QuotaPreferences.get(context) }
    val current by prefs.defaultWindow.collectAsState()
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
    ) {
        Text(
            "Default window",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )
        listOf(QuotaWindowKind.FIVE_HOUR, QuotaWindowKind.SEVEN_DAY).forEach { option ->
            val selected = current == option
            Surface(
                onClick = { prefs.setDefaultWindow(option) },
                shape = RoundedCornerShape(AuroraRadius.full.dp),
                color = if (selected) AuroraColors.ember.copy(alpha = 0.18f) else Color.Transparent,
                border = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    if (selected) AuroraColors.ember else AuroraColors.lightBorder.copy(alpha = 0.5f)
                )
            ) {
                Text(
                    text = option.shortLabel,
                    fontSize = AuroraTypography.caption.sp,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color = if (selected) AuroraColors.ember
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = AuroraSpacing.md.dp, vertical = 6.dp)
                )
            }
        }
    }
}
