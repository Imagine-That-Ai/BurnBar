@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.burn

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingFraction
import com.openburnbar.data.models.effectiveResetsAt
import com.openburnbar.data.models.effectiveWindowLabel
import com.openburnbar.data.models.isCreditBalance
import com.openburnbar.data.models.isStale
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting
import com.openburnbar.util.QuotaResetFormatter
import java.time.Duration
import java.time.Instant

@Composable
internal fun QuotaDetailSheetHero(
    provider: AgentProvider?,
    providerKey: String,
    accountCount: Int,
    themeColor: Color,
) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(
                Brush.linearGradient(
                    colors =
                    listOf(
                        themeColor.copy(alpha = 0.12f),
                        themeColor.copy(alpha = 0.04f),
                        Color.Transparent,
                    ),
                ),
            )
            .padding(AuroraSpacing.xl.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
            provider?.let {
                ProviderAuroraAvatar(provider = it, size = 72)
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            Text(
                text = provider?.displayName ?: providerKey,
                fontSize = AuroraTypography.title.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "$accountCount account${if (accountCount == 1) "" else "s"}",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun QuotaDetailStatsRow(snapshots: List<ProviderQuotaSnapshot>) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
        QuotaStatChip(
            label = "Confidence",
            value = snapshots.firstOrNull()?.confidence ?: "—",
            modifier = Modifier.weight(1f),
        )
        QuotaStatChip(
            label = "Source",
            value = snapshots.firstOrNull()?.source ?: "—",
            modifier = Modifier.weight(1f),
        )
        QuotaStatChip(
            label = "Freshness",
            value = quotaFreshnessLabel(snapshots.firstOrNull()),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun QuotaStatChip(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier =
        modifier
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(vertical = AuroraSpacing.sm.dp),
    ) {
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = label,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun AccountQuotaCard(snapshot: ProviderQuotaSnapshot, themeColor: Color, provider: AgentProvider?) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.65f))
            .border(0.5.dp, themeColor.copy(alpha = 0.18f), RoundedCornerShape(AuroraRadius.lg.dp))
            .padding(AuroraSpacing.md.dp),
    ) {
        AccountQuotaCardHeader(snapshot = snapshot)
        AccountQuotaCardExplanation(snapshot = snapshot)
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            snapshot.buckets.forEach { bucket ->
                UnifiedQuotaSignalView(bucket = bucket, provider = provider, compact = false)
            }
        }
    }
}

@Composable
private fun AccountQuotaCardHeader(snapshot: ProviderQuotaSnapshot) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(
                text = snapshot.accountLabel ?: snapshot.accountId ?: "Account",
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "Quota Breakdown",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                letterSpacing = 1.2.sp,
            )
        }
        snapshot.accountStorageScope?.let {
            Text(
                text = it,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier =
                Modifier
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun AccountQuotaCardExplanation(snapshot: ProviderQuotaSnapshot) {
    when {
        snapshot.isStale() ->
            Text(
                text = "Quota data is stale. Refresh this account before trusting the numbers.",
                fontSize = AuroraTypography.caption.sp,
                color = AuroraColors.warning,
                modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp),
            )
        snapshot.buckets.isNotEmpty() ->
            Text(
                text = quotaExplanation(snapshot.buckets),
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp),
            )
    }
}

internal fun quotaFreshnessLabel(snapshot: ProviderQuotaSnapshot?): String {
    val fetched =
        snapshot?.fetchedAt
            ?.takeIf { it.isNotBlank() }
            ?.let { runCatching { Instant.parse(it) }.getOrNull() }
            ?: return "—"
    val age = Duration.between(fetched, Instant.now()).abs()
    val value =
        when {
            age.toMinutes() < 1 -> "now"
            age.toHours() < 1 -> "${age.toMinutes()}m"
            age.toDays() < 1 -> "${age.toHours()}h"
            else -> "${age.toDays()}d"
        }
    return if (snapshot.isStale()) "stale $value" else value
}

internal fun quotaExplanation(buckets: List<QuotaBucket>): String {
    val windows = buckets.mapNotNull { it.window?.lowercase() }
    val names = buckets.map { it.name.lowercase() }
    return when {
        windows.any { it.contains("hour") } && windows.any { it.contains("week") || it.contains("day") } ->
            "Each gauge tracks usage over a different rolling window. The shorter window paces your near-term burn; the longer window protects against weekly caps."
        names.any { it.contains("token") } && names.any { it.contains("request") } ->
            "One gauge tracks tokens consumed; the other tracks request count. Hitting either limit pauses the account."
        buckets.size > 1 ->
            "Each gauge is a separate quota the provider exposes. The smallest reserve is the one that will throttle first."
        else ->
            "Headroom remaining in this account's active quota window."
    }
}

@Composable
internal fun UnifiedQuotaSignalView(bucket: QuotaBucket, provider: AgentProvider?, compact: Boolean) {
    val primary = provider?.let { Color(it.brandColor) } ?: AuroraColors.ember
    val progress = 1.0 - (bucket.displayRemainingFraction ?: 1.0)
    val animatedProgress by animateFloatAsState(
        targetValue = progress.toFloat(),
        animationSpec = tween(500),
        label = "quota_signal",
    )
    val resetParts = bucket.effectiveResetsAt?.let { QuotaResetFormatter.format(it, bucket.effectiveWindowLabel) }

    Column(modifier = Modifier.fillMaxWidth()) {
        UnifiedQuotaSignalHeader(bucket = bucket, primary = primary, compact = compact, resetParts = resetParts)
        Spacer(modifier = Modifier.height(4.dp))
        if (!bucket.isCreditBalance) {
            LinearProgressIndicator(
                progress = { animatedProgress },
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(if (compact) 6.dp else 8.dp)
                    .clip(RoundedCornerShape(4.dp)),
                color = primary,
                trackColor = MaterialTheme.colorScheme.surfaceVariant,
            )
        }
        UnifiedQuotaSignalFooter(bucket = bucket, compact = compact, resetParts = resetParts)
    }
}

@Composable
private fun UnifiedQuotaSignalHeader(
    bucket: QuotaBucket,
    primary: Color,
    compact: Boolean,
    resetParts: QuotaResetFormatter.Parts?,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = bucket.name,
                fontSize = if (compact) AuroraTypography.tiny.sp else AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (bucket.isCreditBalance) {
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "Balance",
                    fontSize = AuroraTypography.tiny.sp,
                    color = Color.White,
                    modifier =
                    Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(primary)
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (compact && resetParts != null) {
                Text(
                    text = resetParts.relative,
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.width(8.dp))
            }
            Text(
                text = quotaUsageText(bucket),
                fontSize = if (compact) AuroraTypography.tiny.sp else AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun UnifiedQuotaSignalFooter(
    bucket: QuotaBucket,
    compact: Boolean,
    resetParts: QuotaResetFormatter.Parts?,
) {
    if (!compact && !bucket.isCreditBalance && bucket.window != null) {
        Text(
            text = "Window: ${bucket.window}",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    if (!compact && !bucket.isCreditBalance && resetParts != null) {
        Spacer(modifier = Modifier.height(2.dp))
        Text(
            text = "Resets ${resetParts.relative} · ${resetParts.absolute}",
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.82f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

internal fun quotaUsageText(bucket: QuotaBucket): String {
    val unit = bucket.meta?.get("unit")?.toString()?.lowercase()
    if (unit == "unlimited") return "Unlimited"
    if (bucket.limit <= 0) {
        return "${Formatting.formatTokens(bucket.remaining.toInt())} remaining"
    }
    return "${Formatting.formatTokens(bucket.used.toInt())} / ${Formatting.formatTokens(bucket.limit.toInt())}"
}
