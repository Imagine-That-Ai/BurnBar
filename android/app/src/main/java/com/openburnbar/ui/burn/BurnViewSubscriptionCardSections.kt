package com.openburnbar.ui.burn

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.hourlyBucket
import com.openburnbar.data.models.isDisplayableQuotaSignal
import com.openburnbar.data.models.isStale
import com.openburnbar.data.models.nextResetDate
import com.openburnbar.data.models.primaryDisplayableBucket
import com.openburnbar.data.models.weeklyOrMonthlyBucket
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.data.stores.rememberQuotaDefaultWindow
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

internal data class SubscriptionCardState(
    val snapshot: ProviderQuotaSnapshot,
    val accounts: List<ProviderAccount>,
    val signedInEmail: String?,
    val isPinned: Boolean,
)

internal data class SubscriptionCardActions(
    val onRefresh: () -> Unit,
    val onTogglePin: (Boolean) -> Unit,
    val onOpenDetail: () -> Unit,
)

private data class SubscriptionCardBuckets(
    val displayable: List<QuotaBucket>,
    val hourly: QuotaBucket?,
    val weeklyOrMonthly: QuotaBucket?,
    val primary: QuotaBucket?,
) {
    val longWindow: QuotaBucket? get() = weeklyOrMonthly ?: primary
    val weeklyLabel: String
        get() = if (weeklyOrMonthly?.let { QuotaWindowKind.infer(it) } == QuotaWindowKind.MONTHLY) "30-day window" else "7-day window"
}

private data class SubscriptionCardColors(val primary: Color, val accent: Color)

/** Redesigned cards list matching iOS SubscriptionCard. */
@Composable
internal fun SubscriptionCard(state: SubscriptionCardState, actions: SubscriptionCardActions, modifier: Modifier = Modifier) {
    val provider = AgentProvider.fromKey(state.snapshot.provider) ?: return
    val colors = SubscriptionCardColors(primary = Color(provider.brandColor), accent = Color(provider.accentColor))
    val defaultWindow by rememberQuotaDefaultWindow()
    val buckets = remember(state.snapshot, defaultWindow) { state.snapshot.subscriptionCardBuckets(defaultWindow) }
    var expanded by remember { mutableStateOf(false) }

    Box(modifier = modifier.subscriptionCardContainer(colors)) {
        Column(
            modifier = Modifier.padding(AuroraSpacing.LG.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        ) {
            SubscriptionCardHeader(state = state, provider = provider, colors = colors)
            SubscriptionCardMain(snapshot = state.snapshot, provider = provider, colors = colors, buckets = buckets)
            SubscriptionCardFooter(
                buckets = buckets,
                expanded = expanded,
                onExpandedChange = { expanded = it },
                state = state,
                actions = actions,
                colors = colors,
            )
            SubscriptionCardExpanded(expanded = expanded, buckets = buckets.displayable, provider = provider)
        }
    }
}

private fun ProviderQuotaSnapshot.subscriptionCardBuckets(defaultWindow: QuotaWindowKind): SubscriptionCardBuckets = SubscriptionCardBuckets(
    displayable = buckets.filter { it.isDisplayableQuotaSignal() },
    hourly = hourlyBucket,
    weeklyOrMonthly = weeklyOrMonthlyBucket,
    primary = primaryDisplayableBucket(defaultWindow),
)

@Composable
private fun Modifier.subscriptionCardContainer(colors: SubscriptionCardColors): Modifier = fillMaxWidth()
    .shadow(elevation = 6.dp, shape = RoundedCornerShape(AuroraRadius.LG.dp))
    .clip(RoundedCornerShape(AuroraRadius.LG.dp))
    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
    .background(Brush.linearGradient(listOf(colors.primary.copy(alpha = 0.10f), colors.accent.copy(alpha = 0.04f), Color.Transparent)))
    .border(
        width = 0.8.dp,
        brush = Brush.linearGradient(listOf(colors.primary.copy(alpha = 0.34f), colors.accent.copy(alpha = 0.14f), colors.primary.copy(alpha = 0.08f))),
        shape = RoundedCornerShape(AuroraRadius.LG.dp),
    )

@Composable
private fun SubscriptionCardHeader(state: SubscriptionCardState, provider: AgentProvider, colors: SubscriptionCardColors) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        SubscriptionCardIdentityOrb(provider = provider, primaryColor = colors.primary)
        SubscriptionCardIdentityText(state = state, provider = provider, primaryColor = colors.primary, modifier = Modifier.weight(1f))
        SubscriptionCardConfidenceBadge(snapshot = state.snapshot, primaryColor = colors.primary)
    }
}

@Composable
private fun SubscriptionCardIdentityOrb(provider: AgentProvider, primaryColor: Color) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(36.dp)) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(primaryColor.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            ProviderAvatar(providerKey = provider.key, size = 18)
        }
        Canvas(modifier = Modifier.size(36.dp)) {
            drawCircle(
                color = primaryColor.copy(alpha = 0.35f),
                radius = size.minDimension / 2f - 1.dp.toPx(),
                style = Stroke(width = 1.2.dp.toPx()),
            )
        }
    }
}

@Composable
private fun SubscriptionCardIdentityText(state: SubscriptionCardState, provider: AgentProvider, primaryColor: Color, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(
                text = provider.displayName,
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            SubscriptionStatusBadge(isEstimated = state.snapshot.buckets.any { it.isEstimated }, primaryColor = primaryColor)
        }
        SubscriptionAccountRow(state = state)
    }
}

@Composable
private fun SubscriptionStatusBadge(isEstimated: Boolean, primaryColor: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(primaryColor.copy(alpha = 0.12f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            text = if (isEstimated) "ESTIMATED" else "ACTIVE",
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
            color = primaryColor,
            letterSpacing = 0.8.sp,
        )
    }
}

@Composable
private fun SubscriptionAccountRow(state: SubscriptionCardState) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
        Icon(
            imageVector = Icons.Default.AccountCircle,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            modifier = Modifier.size(12.dp),
        )
        Text(
            text = quotaAccountEmail(state.snapshot, state.accounts, state.signedInEmail) ?: quotaAccountName(state.snapshot, state.accounts),
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        state.snapshot.accountStorageScope?.let { SubscriptionScopeChip(scope = it) }
    }
}

@Composable
private fun SubscriptionScopeChip(scope: String) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            text = scope,
            fontSize = 9.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SubscriptionCardConfidenceBadge(snapshot: ProviderQuotaSnapshot, primaryColor: Color) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(Brush.linearGradient(listOf(primaryColor.copy(alpha = 0.08f), MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))))
            .border(0.5.dp, primaryColor.copy(alpha = 0.18f), RoundedCornerShape(8.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            text = "${snapshot.source?.uppercase(Locale.getDefault()) ?: "API"} · ${snapshot.confidence.uppercase(Locale.getDefault())}",
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.5.sp,
        )
    }
}

@Composable
private fun SubscriptionCardMain(snapshot: ProviderQuotaSnapshot, provider: AgentProvider, colors: SubscriptionCardColors, buckets: SubscriptionCardBuckets) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp),
    ) {
        QuotaArcDial(outer = buckets.longWindow, inner = buckets.hourly, provider = provider, diameter = 138.dp)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            MetricRow("clock.fill", "5-hour window", buckets.hourly, "Short-window quota not exposed", provider)
            MetricRow("calendar", buckets.weeklyLabel, buckets.longWindow, "Long-window quota not exposed", provider)
            SubscriptionResetRow(nextResetDate = snapshot.nextResetDate, primaryColor = colors.primary)
            if (snapshot.isStale()) SubscriptionStaleBadge()
        }
    }
}

@Composable
private fun SubscriptionResetRow(nextResetDate: Instant?, primaryColor: Color) {
    val tint = if (nextResetDate == null) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f) else primaryColor
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(imageVector = Icons.Default.Schedule, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
        if (nextResetDate == null) {
            Text("Reset time not published.", fontSize = AuroraTypography.caption.sp, color = tint)
        } else {
            Text("Next reset ${relativeTimeLabel(nextResetDate)}", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                text = "· ${DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).format(nextResetDate.atZone(ZoneId.systemDefault()))}",
                fontSize = AuroraTypography.tiny.sp,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            )
        }
    }
}

@Composable
private fun SubscriptionStaleBadge() {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(AuroraColors.warning.copy(alpha = 0.12f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(text = "Stale signal", fontSize = 9.sp, fontWeight = FontWeight.Bold, color = AuroraColors.warning)
    }
}

@Composable
private fun SubscriptionCardFooter(
    buckets: SubscriptionCardBuckets,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    state: SubscriptionCardState,
    actions: SubscriptionCardActions,
    colors: SubscriptionCardColors,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        SubscriptionBucketToggle(displayableBuckets = buckets.displayable, expanded = expanded, onExpandedChange = onExpandedChange)
        Spacer(modifier = Modifier.weight(1f))
        SubscriptionPinButton(isPinned = state.isPinned, primaryColor = colors.primary) { actions.onTogglePin(!state.isPinned) }
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        SubscriptionRefreshButton(onRefresh = actions.onRefresh)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        if (!state.snapshot.managementUrl.isNullOrEmpty()) SubscriptionManageLink(primaryColor = colors.primary, onOpenDetail = actions.onOpenDetail)
    }
}

@Composable
private fun SubscriptionBucketToggle(displayableBuckets: List<QuotaBucket>, expanded: Boolean, onExpandedChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier
            .clickable(enabled = displayableBuckets.isNotEmpty()) { onExpandedChange(!expanded) }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            imageVector = if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(14.dp),
        )
        Text(
            text = subscriptionBucketToggleLabel(displayableBuckets.size, expanded),
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun subscriptionBucketToggleLabel(bucketCount: Int, expanded: Boolean): String = when {
    bucketCount == 0 -> "No live buckets"
    expanded -> "Hide buckets"
    else -> "Show buckets ($bucketCount)"
}

@Composable
private fun SubscriptionPinButton(isPinned: Boolean, primaryColor: Color, onTogglePin: () -> Unit) {
    IconButton(onClick = onTogglePin, modifier = Modifier.size(28.dp)) {
        Icon(
            imageVector = Icons.Default.PushPin,
            contentDescription = if (isPinned) "Unpin" else "Pin",
            tint = if (isPinned) primaryColor else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun SubscriptionRefreshButton(onRefresh: () -> Unit) {
    IconButton(onClick = onRefresh, modifier = Modifier.size(28.dp)) {
        Icon(
            imageVector = Icons.Default.Refresh,
            contentDescription = "Refresh snapshot",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun SubscriptionManageLink(primaryColor: Color, onOpenDetail: () -> Unit) {
    Row(
        modifier = Modifier
            .clickable { onOpenDetail() }
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text("Manage", fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.SemiBold, color = primaryColor)
        Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = primaryColor, modifier = Modifier.size(10.dp))
    }
}

@Composable
private fun SubscriptionCardExpanded(expanded: Boolean, buckets: List<QuotaBucket>, provider: AgentProvider) {
    AnimatedVisibility(visible = expanded, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = AuroraSpacing.SM.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        ) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.2f))
            Text(
                text = "QUOTA BARS",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                letterSpacing = 1.0.sp,
            )
            buckets.forEach { UnifiedQuotaSignalView(bucket = it, provider = provider, compact = false) }
        }
    }
}
