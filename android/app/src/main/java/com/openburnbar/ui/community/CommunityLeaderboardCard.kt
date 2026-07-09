package com.openburnbar.ui.community

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.openburnbar.data.community.CommunityGeoTier
import com.openburnbar.data.models.generated.FirestoreLeaderboardEntry
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
fun CommunityLeaderboardCard(
    state: CommunityLeaderboardCardState,
    anonId: String?,
    modifier: Modifier = Modifier,
) {
    AuroraGlassCard(
        modifier = modifier.fillMaxWidth(),
        cornerRadius = AuroraRadius.LG,
        contentPadding = AuroraSpacing.MD.dp,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "${state.tier.label} leaderboard",
                    style = AuroraType.headline,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                if (state.isLoading) {
                    AuroraBadge(text = "Updating", tone = AuroraBadgeTone.Info)
                }
            }

            val board = state.board
            when {
                board == null && state.isLoading ->
                    Text(
                        text = "Loading rankings…",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                board == null ->
                    Text(
                        text = "Rankings appear after you opt in to community leaderboards.",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                board.belowThreshold ->
                    CommunityBelowThresholdMessage(
                        tier = state.tier,
                        geoLabel = state.geoKey,
                        kThreshold = board.kThreshold,
                    )
                board.entries.isEmpty() ->
                    Text(
                        text = "No ranked burners yet for this window.",
                        style = AuroraType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                else -> {
                    val pinned = board.entries.firstOrNull { it.anonId == anonId }
                    board.entries.take(5).forEach { entry ->
                        CommunityLeaderboardRow(entry = entry, isYou = entry.anonId == anonId)
                    }
                    pinned?.let { you ->
                        if (board.entries.none { it.anonId == you.anonId }) {
                            Text(
                                text = "Your rank",
                                style = AuroraType.caption,
                                modifier = Modifier.padding(top = AuroraSpacing.XS.dp),
                            )
                            CommunityLeaderboardRow(entry = you, isYou = true)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CommunityBelowThresholdMessage(
    tier: CommunityGeoTier,
    geoLabel: String,
    kThreshold: Long,
) {
    val place =
        when (tier) {
            CommunityGeoTier.CITY -> geoLabel
            CommunityGeoTier.REGION -> geoLabel
            CommunityGeoTier.COUNTRY -> geoLabel
            CommunityGeoTier.WORLD -> "your cohort"
        }
    Text(
        text = "Needs $kThreshold more burners in $place before individual rankings can appear. " +
            "We'll show the next broader tier instead.",
        style = AuroraType.caption,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        lineHeight = 18.sp,
    )
}

@Composable
private fun CommunityLeaderboardRow(
    entry: FirestoreLeaderboardEntry,
    isYou: Boolean,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(
                text = "#${entry.rank}",
                style = AuroraType.caption,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = entry.handle?.takeIf { it.isNotBlank() } ?: entry.anonId.take(8),
                style = AuroraType.body,
            )
            if (isYou) {
                AuroraBadge(text = "You", tone = AuroraBadgeTone.Accent)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
            Text(
                text = formatTokens(entry.totalTokens),
                style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = movementGlyph(entry.movement),
                style = AuroraType.caption,
            )
        }
    }
}

private fun movementGlyph(movement: String): String =
    when (movement.lowercase()) {
        "up" -> "▲"
        "down" -> "▼"
        else -> "•"
    }

private fun formatTokens(tokens: Long): String =
    when {
        tokens >= 1_000_000 -> "%.1fM".format(tokens / 1_000_000.0)
        tokens >= 1_000 -> "%.1fK".format(tokens / 1_000.0)
        else -> tokens.toString()
    }