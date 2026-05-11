package com.openburnbar.ui.pulse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting

@Composable
fun RecentSessionsStripCard(
    sessions: List<TokenUsage>,
    onSelect: (TokenUsage) -> Unit,
    onSeeAll: () -> Unit
) {
    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp),
        cornerRadius = AuroraRadius.xl
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "Recent",
                        fontSize = AuroraTypography.caption.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = AuroraColors.whimsy
                    )
                    Text(
                        text = if (sessions.isEmpty()) "Awaiting first session" else "Last ${sessions.size} sessions",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    text = "See all ›",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AuroraColors.whimsy,
                    modifier = Modifier.clickable { onSeeAll() }
                )
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

            if (sessions.isEmpty()) {
                EmptyStateView(
                    title = "No sessions yet",
                    message = "Sessions will appear here as soon as your Mac syncs."
                )
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(sessions.take(8)) { session ->
                        SessionTileMicro(
                            usage = session,
                            onClick = { onSelect(session) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SessionTileMicro(
    usage: TokenUsage,
    onClick: () -> Unit
) {
    val providerEnum = AgentProvider.fromKey(usage.provider)
    val primary = providerEnum?.let { Color(it.brandColor) } ?: AuroraColors.ember

    Column(
        modifier = Modifier
            .width(160.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        primary.copy(alpha = 0.18f),
                        primary.copy(alpha = 0.06f),
                        Color.Transparent
                    ),
                    start = androidx.compose.ui.geometry.Offset(0f, 0f),
                    end = androidx.compose.ui.geometry.Offset(200f, 200f)
                )
            )
            .border(0.5.dp, primary.copy(alpha = 0.4f), RoundedCornerShape(14.dp))
            .clickable { onClick() }
            .padding(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            providerEnum?.let {
                ProviderAuroraAvatar(provider = it, size = 32, showHalo = false)
            }
            Spacer(modifier = Modifier.width(8.dp))
            Column {
                Text(
                    text = providerEnum?.displayName ?: usage.provider,
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = primary
                )
                Text(
                    text = Formatting.formatRelativeTime(usage.timestamp),
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = usage.model ?: "Unknown model",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1
        )
        if (!usage.projectName.isNullOrEmpty()) {
            Text(
                text = usage.projectName,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = Formatting.formatCurrency(usage.effectiveCost),
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = " · ",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = Formatting.formatTokens(usage.totalTokens),
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
