package com.openburnbar.ui.burn

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.util.Formatting
import com.openburnbar.util.QuotaResetFormatter
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.effectiveResetsAt
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuotaDetailSheet(
    providerKey: String,
    snapshots: List<ProviderQuotaSnapshot>,
    onDismiss: () -> Unit
) {
    val provider = AgentProvider.fromKey(providerKey)
    val themeColor = provider?.let { Color(it.brandColor) } ?: MaterialTheme.colorScheme.onSurfaceVariant

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = AuroraSpacing.lg.dp)
                .padding(bottom = AuroraSpacing.xxl.dp)
                .verticalScroll(rememberScrollState())
        ) {
            // Hero
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(AuroraRadius.lg.dp))
                    .background(
                        Brush.linearGradient(
                            colors = listOf(
                                themeColor.copy(alpha = 0.12f),
                                themeColor.copy(alpha = 0.04f),
                                Color.Transparent
                            )
                        )
                    )
                    .padding(AuroraSpacing.xl.dp)
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
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "${snapshots.size} account${if (snapshots.size == 1) "" else "s"}",
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            // Stats row
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                StatChip(
                    label = "Confidence",
                    value = snapshots.firstOrNull()?.confidence ?: "—",
                    modifier = Modifier.weight(1f)
                )
                StatChip(
                    label = "Source",
                    value = snapshots.firstOrNull()?.source ?: "—",
                    modifier = Modifier.weight(1f)
                )
                StatChip(
                    label = "Buckets",
                    value = "${snapshots.sumOf { it.buckets.size }}",
                    modifier = Modifier.weight(1f)
                )
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            // Account sections
            snapshots.forEach { snapshot ->
                AccountQuotaCard(
                    snapshot = snapshot,
                    themeColor = themeColor,
                    provider = provider
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            }
        }
    }
}
@Composable
private fun StatChip(
    label: String,
    value: String,
    modifier: Modifier = Modifier
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(vertical = AuroraSpacing.sm.dp)
    ) {
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = label,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun AccountQuotaCard(
    snapshot: ProviderQuotaSnapshot,
    themeColor: Color,
    provider: AgentProvider?
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.65f))
            .border(0.5.dp, themeColor.copy(alpha = 0.18f), RoundedCornerShape(AuroraRadius.lg.dp))
            .padding(AuroraSpacing.md.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = snapshot.accountLabel ?: snapshot.accountId ?: "Account",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "Quota Breakdown",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    letterSpacing = 1.2.sp
                )
            }
            snapshot.accountStorageScope?.let {
                Text(
                    text = it,
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 8.dp, vertical = 4.dp)
                )
            }
        }

        if (snapshot.buckets.isNotEmpty()) {
            Text(
                text = quotaExplanation(snapshot.buckets),
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp)
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            snapshot.buckets.forEach { bucket ->
                UnifiedQuotaSignalView(
                    bucket = bucket,
                    provider = provider,
                    compact = false
                )
            }
        }
    }
}

private fun quotaExplanation(buckets: List<QuotaBucket>): String {
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
fun UnifiedQuotaSignalView(
    bucket: QuotaBucket,
    provider: AgentProvider?,
    compact: Boolean
) {
    val primary = provider?.let { Color(it.brandColor) } ?: AuroraColors.ember
    val progress = if (bucket.limit > 0) {
        (bucket.used / bucket.limit).coerceIn(0.0, 1.0)
    } else 0.0
    val animatedProgress by animateFloatAsState(
        targetValue = progress.toFloat(),
        animationSpec = tween(500),
        label = "quota_signal"
    )

    val resetsAt = bucket.effectiveResetsAt
    val resetParts = resetsAt?.let { QuotaResetFormatter.format(it) }

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = bucket.name,
                fontSize = if (compact) AuroraTypography.tiny.sp else AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Compact mode: tuck the relative-only half next to the
                // used/limit text so the card still answers "when does this
                // refill" without growing a new row.
                if (compact && resetParts != null) {
                    Text(
                        text = resetParts.relative,
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                }
                Text(
                    text = "${Formatting.formatTokens(bucket.used.toInt())} / ${Formatting.formatTokens(bucket.limit.toInt())}",
                    fontSize = if (compact) AuroraTypography.tiny.sp else AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Spacer(modifier = Modifier.height(4.dp))
        LinearProgressIndicator(
            progress = { animatedProgress },
            modifier = Modifier
                .fillMaxWidth()
                .height(if (compact) 6.dp else 8.dp)
                .clip(RoundedCornerShape(4.dp)),
            color = primary,
            trackColor = MaterialTheme.colorScheme.surfaceVariant
        )
        if (!compact && bucket.window != null) {
            Text(
                text = "Window: ${bucket.window}",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        // Non-compact reset row: lifts `resetsAt` into its own line, same
        // shape as the iOS UnifiedQuotaSignalView reset row and the Mac
        // ProviderQuotaBucketRow micro-badge. Empty when the bucket has no
        // known reset moment.
        if (!compact && resetParts != null) {
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = "Resets ${resetParts.relative} · ${resetParts.absolute}",
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.82f),
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
        }
    }
}
