// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
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
import com.openburnbar.ui.theme.AuroraTypography
import com.openburnbar.util.Formatting

@Composable
internal fun SessionTileMicro(usage: TokenUsage, onClick: () -> Unit) {
    val providerEnum = AgentProvider.fromKey(usage.provider)
    val primary = providerEnum?.let { Color(it.brandColor) } ?: com.openburnbar.ui.theme.AuroraColors.ember

    Column(
        modifier =
        Modifier
            .width(160.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(primary.copy(alpha = 0.18f), primary.copy(alpha = 0.06f), Color.Transparent),
                    start = androidx.compose.ui.geometry.Offset(0f, 0f),
                    end = androidx.compose.ui.geometry.Offset(200f, 200f),
                ),
            )
            .border(0.5.dp, primary.copy(alpha = 0.4f), RoundedCornerShape(14.dp))
            .clickable { onClick() }
            .padding(12.dp),
    ) {
        SessionTileProviderHeader(providerEnum = providerEnum, usage = usage, primary = primary)
        Spacer(modifier = Modifier.height(8.dp))
        SessionTileModelRow(usage = usage)
        if (!usage.projectName.isNullOrEmpty()) {
            Text(
                text = usage.projectName,
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        SessionTileCostRow(usage = usage)
    }
}

@Composable
private fun SessionTileProviderHeader(providerEnum: AgentProvider?, usage: TokenUsage, primary: Color) {
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
                color = primary,
            )
            Text(
                text = Formatting.formatRelativeTime(usage.timestamp),
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SessionTileModelRow(usage: TokenUsage) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        val modelKey = usage.model
        if (!modelKey.isNullOrBlank()) {
            com.openburnbar.ui.components.ModelLogo(modelKey = modelKey, size = 16.dp)
            Spacer(modifier = Modifier.width(6.dp))
        }
        Text(
            text = modelKey ?: "Unknown model",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
    }
}

@Composable
private fun SessionTileCostRow(usage: TokenUsage) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = "Cost ${Formatting.formatCurrency(usage.effectiveCost)}",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(text = " · ", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            text = "Tokens ${Formatting.formatTokens(usage.totalTokens)}",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
