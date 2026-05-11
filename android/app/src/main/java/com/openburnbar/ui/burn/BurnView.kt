package com.openburnbar.ui.burn

import androidx.compose.animation.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
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
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.ui.components.*
import com.openburnbar.ui.theme.*
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting
import kotlin.math.min

@Composable
fun BurnView(
    quotaStore: QuotaStore = viewModel()
) {
    val snapshots by quotaStore.snapshots.collectAsState()
    val accounts by quotaStore.accounts.collectAsState()
    val isLoading by quotaStore.isLoading.collectAsState()
    val error by quotaStore.error.collectAsState()
    val isDark = isSystemInDarkTheme()
    var detailSnapshot by remember { mutableStateOf<ProviderQuotaSnapshot?>(null) }
    var displayMode by remember { mutableStateOf(UsageDisplayMode.CURRENCY) }
    var selectedPeriod by remember { mutableIntStateOf(0) }
    val periods = listOf("Today", "Week", "Month")

    LaunchedEffect(Unit) { quotaStore.load() }

    detailSnapshot?.let { snapshot ->
        ProviderDetailDialog(
            snapshot = snapshot,
            accounts = accounts.filter { it.providerId == snapshot.provider },
            onDismiss = { detailSnapshot = null }
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        AuroraBackdrop(isDark = isDark)

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
                EmptyStateView(
                    icon = Icons.Filled.LocalFireDepartment,
                    title = "No Quota Data",
                    message = "Connect provider accounts to see your quota usage."
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

                    snapshots.forEachIndexed { index, snapshot ->
                        StaggeredEntrance(delay = 150 + index * 25) {
                            ProviderAccordionCard(
                                snapshot = snapshot,
                                accounts = accounts.filter { it.providerId == snapshot.provider },
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
    onDismiss: () -> Unit
) {
    val provider = AgentProvider.fromKey(snapshot.provider)

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
                        detailRow("Accounts", "${snapshot.accountCount}")
                        detailRow("Status", if (snapshot.isUnlimited) "Unlimited" else "Limited")
                    }
                }

                if (accounts.isNotEmpty()) {
                    Text("Accounts", fontWeight = FontWeight.Bold, fontSize = AuroraTypography.caption.sp)
                    accounts.forEach { account ->
                        Card(
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
                                Text(account.label.ifEmpty { account.providerId }, fontWeight = FontWeight.Medium)
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
@Composable
fun FleetHealthRing(
    snapshots: List<ProviderQuotaSnapshot>,
    modifier: Modifier = Modifier
) {
    AuroraGlassCard(modifier = modifier) {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text("Fleet Health", fontWeight = FontWeight.Bold, fontSize = AuroraTypography.heading.sp)
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            val totalRemaining = snapshots.sumOf { it.percentageRemaining }
            val avg = if (snapshots.isNotEmpty()) totalRemaining / snapshots.size else 100.0
            val trackColor = MaterialTheme.colorScheme.surfaceVariant
            Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth().height(160.dp)) {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    val sweepAngle = (avg / 100 * 360).toFloat()
                    drawArc(
                        brush = Brush.sweepGradient(listOf(AuroraColors.burnOrange, AuroraColors.burnCoral, AuroraColors.burnOrange)),
                        startAngle = -90f,
                        sweepAngle = sweepAngle,
                        useCenter = true,
                        size = Size(min(size.width, size.height) * 0.8f, min(size.width, size.height) * 0.8f),
                        topLeft = Offset((size.width - min(size.width, size.height) * 0.8f) / 2, (size.height - min(size.width, size.height) * 0.8f) / 2)
                    )
                    drawArc(
                        color = trackColor,
                        startAngle = -90f + sweepAngle,
                        sweepAngle = 360f - sweepAngle,
                        useCenter = false,
                        style = Stroke(width = 12f, cap = StrokeCap.Round),
                        size = Size(min(size.width, size.height) * 0.8f, min(size.width, size.height) * 0.8f),
                        topLeft = Offset((size.width - min(size.width, size.height) * 0.8f) / 2, (size.height - min(size.width, size.height) * 0.8f) / 2)
                    )
                }
                Text("${avg.toInt()}%", fontSize = 28.sp, fontWeight = FontWeight.Bold)
            }
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
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Row(
            modifier = Modifier.padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            ProviderAvatar(providerKey = snapshot.provider, size = 24)
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Column {
                Text(provider?.displayName ?: snapshot.provider, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.Medium)
                Text("${snapshot.percentageRemaining.toInt()}%", fontSize = 11.sp, color = if (snapshot.percentageRemaining <= 25) AuroraColors.burnOrange else MaterialTheme.colorScheme.onSurfaceVariant)
            }
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
@Composable
fun ProviderAccordionCard(
    snapshot: ProviderQuotaSnapshot,
    accounts: List<ProviderAccount>,
    onOpenDetail: () -> Unit,
    modifier: Modifier = Modifier
) {
    AuroraGlassCard(modifier = modifier.clickable { onOpenDetail() }) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(AuroraSpacing.md.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ProviderAvatar(providerKey = snapshot.provider, size = 36)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Column {
                    Text(AgentProvider.fromKey(snapshot.provider)?.displayName ?: snapshot.provider, fontWeight = FontWeight.Bold)
                    Text("${accounts.size} account(s)", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text("${snapshot.percentageRemaining.toInt()}%", fontWeight = FontWeight.Bold, color = if (snapshot.percentageRemaining <= 25) AuroraColors.burnOrange else MaterialTheme.colorScheme.onSurface)
                LinearProgressIndicator(
                    progress = { (snapshot.percentageRemaining / 100.0).toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.width(80.dp).height(6.dp).clip(RoundedCornerShape(3.dp)),
                    color = if (snapshot.percentageRemaining <= 25) AuroraColors.burnOrange else AuroraColors.burnCoral,
                    trackColor = MaterialTheme.colorScheme.surfaceVariant
                )
            }
        }
    }
}
