package com.openburnbar.ui.burn

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.pressure
import com.openburnbar.data.models.nextResetDate
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.time.Instant
import java.util.Locale
import kotlin.math.roundToInt

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
            ProviderFocusTitle(provider = provider, primaryColor = primaryColor)
            Text(
                text = "$accountCount $accountWord · $otherCount other provider${if (otherCount == 1) "" else "s"} hidden",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        ProviderFocusClearButton(onClearSelection = onClearSelection)
    }
}

@Composable
private fun ProviderFocusTitle(provider: AgentProvider, primaryColor: Color) {
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
}

@Composable
private fun ProviderFocusClearButton(onClearSelection: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
            .clickable { onClearSelection() }
            .padding(horizontal = 10.dp, vertical = 5.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
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
        remainingFraction >= QUOTA_REMAINING_HEALTHY -> primaryColor
        remainingFraction >= QUOTA_REMAINING_WATCH -> primaryColor.copy(alpha = SUBSCRIPTION_ORB_MUTED_ALPHA)
        remainingFraction >= QUOTA_REMAINING_WARN -> AuroraColors.amber
        else -> AuroraColors.warning
    }

    val alpha = if (isDimmed) SUBSCRIPTION_ORB_DIMMED_ALPHA else 1.0f

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(64.dp)
            .clickable { onTap() }
            .graphicsLayer { this.alpha = alpha }
    ) {
        SubscriptionOrbBody(
            provider = provider,
            primaryColor = primaryColor,
            ringColor = ringColor,
            remainingFraction = remainingFraction,
            isSelected = isSelected
        )
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
private fun SubscriptionOrbBody(
    provider: AgentProvider,
    primaryColor: Color,
    ringColor: Color,
    remainingFraction: Double,
    isSelected: Boolean
) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(64.dp)) {
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
        SubscriptionOrbRing(ringColor = ringColor, remainingFraction = remainingFraction)
    }
}

@Composable
private fun SubscriptionOrbRing(ringColor: Color, remainingFraction: Double) {
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

@Composable
fun SubscriptionConstellationHero(
    snapshots: List<ProviderQuotaSnapshot>,
    selectedProvider: AgentProvider?,
    onOrbTap: (AgentProvider) -> Unit,
    onClearSelection: () -> Unit,
    modifier: Modifier = Modifier
) {
    val summary = remember(snapshots, selectedProvider) { subscriptionHeroSummary(snapshots, selectedProvider) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp, vertical = AuroraSpacing.md.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
    ) {
        SubscriptionHeroHeader(summary = summary, selectedProvider = selectedProvider, onClearSelection = onClearSelection)
        Text(summary.headlineText, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        SubscriptionHeroMetaRow(metaItems = summary.metaItems)
        SubscriptionHeroDivider()
        SubscriptionHeroOrbRow(
            orbEntries = summary.orbEntries,
            selectedProvider = selectedProvider,
            onOrbTap = onOrbTap
        )
    }
}

private data class SubscriptionHeroPressureCounts(val wideOpen: Int, val narrowing: Int, val nearEdge: Int)

private data class SubscriptionHeroSummary(
    val activeCount: Int,
    val counts: SubscriptionHeroPressureCounts,
    val eyebrowText: String,
    val headlineText: String,
    val metaItems: List<String>,
    val orbEntries: List<Pair<AgentProvider, ProviderQuotaSnapshot>>,
)

private fun subscriptionHeroSummary(
    snapshots: List<ProviderQuotaSnapshot>,
    selectedProvider: AgentProvider?
): SubscriptionHeroSummary {
    val counts = subscriptionHeroPressureCounts(snapshots)
    val activeCount = snapshots.size
    return SubscriptionHeroSummary(
        activeCount = activeCount,
        counts = counts,
        eyebrowText = subscriptionHeroEyebrow(selectedProvider, activeCount),
        headlineText = subscriptionHeroHeadline(selectedProvider, activeCount, counts),
        metaItems = subscriptionHeroMetaItems(snapshots, activeCount, counts.nearEdge),
        orbEntries = subscriptionHeroOrbEntries(snapshots)
    )
}

private fun subscriptionHeroPressureCounts(snapshots: List<ProviderQuotaSnapshot>): SubscriptionHeroPressureCounts {
    var wideOpen = 0
    var narrowing = 0
    var nearEdge = 0
    snapshots.forEach { snapshot ->
        when {
            snapshot.pressure < SUBSCRIPTION_HERO_WIDE_OPEN_PRESSURE -> wideOpen++
            snapshot.pressure < SUBSCRIPTION_HERO_NARROWING_PRESSURE -> narrowing++
            else -> nearEdge++
        }
    }
    return SubscriptionHeroPressureCounts(wideOpen = wideOpen, narrowing = narrowing, nearEdge = nearEdge)
}

private fun subscriptionHeroEyebrow(selectedProvider: AgentProvider?, activeCount: Int): String =
    if (selectedProvider != null) {
        "FOCUSED · ${selectedProvider.displayName.uppercase(Locale.getDefault())} · $activeCount ACTIVE ACCOUNT${if (activeCount == 1) "" else "S"}"
    } else {
        "SUBSCRIPTION VAULT · $activeCount ACTIVE PLAN" + (if (activeCount == 1) "" else "s").uppercase(Locale.getDefault())
    }

private fun subscriptionHeroHeadline(
    selectedProvider: AgentProvider?,
    activeCount: Int,
    counts: SubscriptionHeroPressureCounts
): String =
    when {
        activeCount == 0 -> "Connect a plan to start tracking quota"
        selectedProvider != null -> subscriptionHeroFocusedHeadline(selectedProvider, activeCount, counts.nearEdge)
        counts.nearEdge > 0 -> "$activeCount plan${if (activeCount == 1) "" else "s"} tracked · ${counts.nearEdge} near the edge"
        counts.narrowing > 0 -> "${counts.wideOpen} of $activeCount plans wide open · ${counts.narrowing} narrowing"
        else -> "All $activeCount plan" + (if (activeCount == 1) "" else "s") + " have headroom"
    }

private fun subscriptionHeroFocusedHeadline(provider: AgentProvider, activeCount: Int, nearEdgeCount: Int): String {
    val accountWord = if (activeCount == 1) "account" else "accounts"
    return if (nearEdgeCount > 0) {
        "${provider.displayName} · $activeCount $accountWord · $nearEdgeCount near the edge"
    } else {
        "${provider.displayName} · $activeCount $accountWord tracked"
    }
}

private fun subscriptionHeroMetaItems(
    snapshots: List<ProviderQuotaSnapshot>,
    activeCount: Int,
    nearEdgeCount: Int
): List<String> =
    buildList {
        add("$activeCount ACTIVE")
        subscriptionHeroNextResetMeta(snapshots)?.let(::add)
        subscriptionHeroLastSyncMeta(snapshots)?.let(::add)
        if (nearEdgeCount > 0) add("$nearEdgeCount NEAR EDGE")
    }

private fun subscriptionHeroNextResetMeta(snapshots: List<ProviderQuotaSnapshot>): String? {
    val (snapshot, nextResetDate) =
        snapshots.mapNotNull { snapshot -> snapshot.nextResetDate?.let { snapshot to it } }
            .minByOrNull { (_, resetDate) -> resetDate }
            ?: return null
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return null
    val formattedRelative = relativeTimeLabel(nextResetDate).uppercase(Locale.getDefault())
    return "NEXT RESET · ${provider.displayName.uppercase(Locale.getDefault())} · $formattedRelative"
}

private fun subscriptionHeroLastSyncMeta(snapshots: List<ProviderQuotaSnapshot>): String? {
    val lastSync = snapshots.mapNotNull { it.fetchedAt }.maxOrNull()?.let { runCatching { Instant.parse(it) }.getOrNull() }
    return lastSync?.let { "SYNC ${relativeTimeLabel(it).uppercase(Locale.getDefault())}" }
}

private fun subscriptionHeroOrbEntries(snapshots: List<ProviderQuotaSnapshot>): List<Pair<AgentProvider, ProviderQuotaSnapshot>> =
    snapshots.groupBy { it.provider }.mapNotNull { (providerKey, providerSnapshots) ->
        val provider = AgentProvider.fromKey(providerKey) ?: return@mapNotNull null
        val worstSnapshot = providerSnapshots.maxByOrNull { it.pressure } ?: return@mapNotNull null
        provider to worstSnapshot
    }.sortedWith(compareByDescending<Pair<AgentProvider, ProviderQuotaSnapshot>> { it.second.pressure }.thenBy { it.first.displayName.lowercase() })

@Composable
private fun SubscriptionHeroHeader(
    summary: SubscriptionHeroSummary,
    selectedProvider: AgentProvider?,
    onClearSelection: () -> Unit
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        Text(
            text = summary.eyebrowText,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = if (selectedProvider != null) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            letterSpacing = 1.2.sp
        )
        if (selectedProvider != null) SubscriptionHeroClearButton(onClearSelection)
    }
}

@Composable
private fun SubscriptionHeroClearButton(onClearSelection: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f), RoundedCornerShape(8.dp))
            .clickable { onClearSelection() }
            .padding(horizontal = 8.dp, vertical = 3.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Icon(Icons.Default.Close, contentDescription = "Clear selection", tint = MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(10.dp))
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

@Composable
private fun SubscriptionHeroMetaRow(metaItems: List<String>) {
    if (metaItems.isEmpty()) return
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        metaItems.forEachIndexed { index, item ->
            if (index > 0) SubscriptionHeroMetaSeparator()
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

@Composable
private fun SubscriptionHeroMetaSeparator() {
    Text(
        text = "·",
        fontSize = AuroraTypography.tiny.sp,
        fontFamily = FontFamily.Monospace,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
    )
}

@Composable
private fun SubscriptionHeroDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(
                Brush.horizontalGradient(
                    listOf(
                        Color.Transparent,
                        AuroraColors.hermesMercury.copy(alpha = 0.5f),
                        AuroraColors.hermesAureate.copy(alpha = 0.65f),
                        AuroraColors.hermesMercury.copy(alpha = 0.5f),
                        Color.Transparent
                    )
                )
            )
    )
}

@Composable
private fun SubscriptionHeroOrbRow(
    orbEntries: List<Pair<AgentProvider, ProviderQuotaSnapshot>>,
    selectedProvider: AgentProvider?,
    onOrbTap: (AgentProvider) -> Unit
) {
    if (orbEntries.isEmpty()) return
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
        modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp)
    ) {
        items(orbEntries) { (provider, snapshot) ->
            SubscriptionOrb(
                provider = provider,
                snapshot = snapshot,
                isSelected = selectedProvider == provider,
                isDimmed = selectedProvider != null && selectedProvider != provider,
                onTap = { onOrbTap(provider) }
            )
        }
    }
}
