@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProjectSummary
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting

@Composable
internal fun ProjectDetailHeroCard(project: ProjectSummary) {
    val providerColor = AuroraColors.ember
    AuroraGlassCard(cornerRadius = AuroraRadius.xl) {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier =
                    Modifier
                        .size(56.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(providerColor.copy(alpha = 0.18f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Folder,
                        contentDescription = null,
                        tint = providerColor,
                        modifier = Modifier.size(22.dp),
                    )
                }
                Spacer(modifier = Modifier.width(14.dp))
                Column {
                    Text(
                        text = project.name,
                        fontSize = AuroraTypography.title.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "${project.totalSessions} sessions",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

            Text(
                text = Formatting.formatCurrency(project.totalCost),
                fontSize = AuroraTypography.displayHero.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "${Formatting.formatTokens(project.totalTokens)} tokens · ${project.totalSessions} sessions",
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun ProjectDetailStatRow(project: ProjectSummary, sessions: List<TokenUsage>, topModels: List<Pair<String, Int>>) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        ProjectDetailStatPill(label = "Sessions", value = "${project.totalSessions}", modifier = Modifier.weight(1f))
        val dominantProvider = sessions.firstOrNull()?.provider?.let { AgentProvider.fromKey(it) }
        dominantProvider?.let {
            ProjectDetailStatPill(label = "Top provider", value = it.displayName, modifier = Modifier.weight(1f))
        }
        topModels.firstOrNull()?.let { (model, _) ->
            ProjectDetailStatPill(label = "Top model", value = model, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
internal fun ProjectDetailTopModelsCard(topModels: List<Pair<String, Int>>) {
    if (topModels.isEmpty()) return
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text(
                text = "Top models",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.amber,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            topModels.forEach { (model, tokens) ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = model,
                        fontSize = AuroraTypography.body.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = Formatting.formatTokens(tokens),
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(modifier = Modifier.height(4.dp))
            }
        }
    }
}

@Composable
internal fun ProjectDetailSessionsCard(sessions: List<TokenUsage>, onSessionClick: (TokenUsage) -> Unit) {
    val providerColor = AuroraColors.ember
    AuroraGlassCard {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text(
                text = "Sessions",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = providerColor,
            )
            Text(
                text = "${sessions.size} total",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

            sessions.take(20).forEach { session ->
                ProjectDetailSessionRow(
                    session = session,
                    onClick = { onSessionClick(session) },
                )
                Spacer(modifier = Modifier.height(4.dp))
            }
        }
    }
}

@Composable
private fun ProjectDetailStatPill(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier =
        modifier
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.72f))
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
            .padding(vertical = 10.dp),
    ) {
        Text(
            text = value,
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
        Text(
            text = label.uppercase(),
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 1.2.sp,
        )
    }
}

@Composable
private fun ProjectDetailSessionRow(session: TokenUsage, onClick: () -> Unit) {
    val provider = AgentProvider.fromKey(session.provider)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(vertical = 4.dp),
    ) {
        provider?.let {
            ProviderAuroraAvatar(provider = it, size = 36, showHalo = false)
        }
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = session.model ?: "Unknown",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            Text(
                text = Formatting.formatRelativeTime(session.timestamp),
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = Formatting.formatCurrency(session.effectiveCost),
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}
