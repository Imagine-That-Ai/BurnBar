package com.openburnbar.ui.chartstudio

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Renders an [InsightSpec] as an Aurora glass card: tone-tinted leading icon,
 * title + body text, optional inline sparkline, and an optional follow-up
 * button that dispatches another prompt to Hermes ("Show me the chart →").
 */
@Composable
fun InsightCard(
    spec: InsightSpec,
    modifier: Modifier = Modifier,
    onFollowUp: ((String) -> Unit)? = null
) {
    val tone = ToneStyling.from(spec.tone)
    AuroraGlassCard(modifier = modifier) {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(tone.color.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = tone.icon,
                    contentDescription = null,
                    tint = tone.color,
                    modifier = Modifier.size(16.dp)
                )
            }
            Spacer(Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = spec.title,
                    style = AuroraType.headline,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = spec.body,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                spec.sparkline?.takeIf { it.size >= 2 }?.let { points ->
                    Spacer(Modifier.height(AuroraSpacing.sm.dp))
                    Box(modifier = Modifier.fillMaxWidth().height(56.dp)) {
                        AuroraSparkline(
                            data = points.map { it.toFloat() },
                            strokeColor = tone.color,
                            fillColor = tone.color.copy(alpha = 0.18f),
                            strokeWidth = 2f
                        )
                    }
                }

                val followUp = spec.followUpPrompt
                if (!followUp.isNullOrBlank() && onFollowUp != null) {
                    Spacer(Modifier.height(AuroraSpacing.sm.dp))
                    TextButton(
                        onClick = { onFollowUp(followUp) },
                        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp)
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ShowChart,
                            contentDescription = null,
                            tint = AuroraColors.ember,
                            modifier = Modifier.size(14.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = spec.followUpLabel ?: "Show me the chart →",
                            style = AuroraType.caption,
                            color = AuroraColors.ember,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }
            }
        }
    }
}

private data class ToneStyling(val color: Color, val icon: ImageVector) {
    companion object {
        fun from(raw: String): ToneStyling = when (raw.trim().lowercase()) {
            "positive" -> ToneStyling(AuroraColors.success, Icons.Filled.CheckCircle)
            "warning"  -> ToneStyling(AuroraColors.warning, Icons.Filled.WarningAmber)
            else       -> ToneStyling(AuroraColors.hermesAureate, Icons.Outlined.Lightbulb)
        }
    }
}
