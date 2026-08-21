package com.openburnbar.ui.recap

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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.recap.MonthlyRecap
import com.openburnbar.data.recap.RecapCard
import com.openburnbar.data.recap.RecapCardSize
import com.openburnbar.data.recap.RecapInsightKind
import com.openburnbar.data.recap.RecapVisual
import com.openburnbar.data.recap.RecapVisualData
import com.openburnbar.ui.theme.AuroraColors

@Composable
fun RecapCardView(card: RecapCard, modifier: Modifier = Modifier, onShare: ((RecapCard) -> Unit)? = null) {
    RecapCardChrome(card = card, modifier = modifier, onShare = onShare) {
        when (card.size) {
            RecapCardSize.HERO, RecapCardSize.FULL_BLEED -> RecapHeroCard(card = card)
            RecapCardSize.SMALL -> RecapTileCard(card = card)
            RecapCardSize.MEDIUM, RecapCardSize.WIDE -> RecapStandardCard(card = card)
        }
    }
}

// ── Hero Card ──

@Composable
fun RecapHeroCard(card: RecapCard, modifier: Modifier = Modifier) {
    val accent = RecapTheme.accentFor(card)
    val primaryMetric = card.primaryMetric

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            RecapEyebrow(
                text = card.kind.label(RecapInsightKind.LabelStyle.LONG),
                accent = accent,
            )
            Spacer(modifier = Modifier.weight(1f))
            card.comparison?.let { RecapDeltaChip(comparison = it) }
        }

        if (primaryMetric != null && card.visual == RecapVisual.BIG_NUMBER) {
            Text(
                text = primaryMetric.formatted,
                style = RecapTheme.Typography.heroNumeral,
                color = accent,
            )
        }

        RecapCopy(
            headline = card.headline,
            message = card.body,
            headlineStyle = RecapTheme.Typography.heroHeadline,
        )

        val visualData = card.visualData
        if (card.visual != RecapVisual.NONE && visualData != null) {
            RecapCardVisualRenderer(
                visual = card.visual,
                visualData = visualData,
                accent = accent,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        RecapSupportingMetricsRow(card.metrics.drop(1).take(2))
    }
}

@Composable
private fun RecapSupportingMetricsRow(metrics: List<com.openburnbar.data.recap.RecapMetric>) {
    if (metrics.isEmpty()) return
    Row(
        horizontalArrangement = Arrangement.spacedBy(24.dp),
        modifier = Modifier.padding(top = 8.dp),
    ) {
        metrics.forEach { m ->
            Column {
                Text(
                    text = m.formatted,
                    style = RecapTheme.Typography.caption.copy(fontWeight = FontWeight.Bold),
                    color = AuroraColors.lightTextPrimary,
                )
                Text(
                    text = m.label,
                    style = RecapTheme.Typography.eyebrow.copy(fontSize = 10.sp),
                    color = AuroraColors.lightTextMuted,
                )
            }
        }
    }
}

// ── Tile Card (Small) ──

@Composable
fun RecapTileCard(card: RecapCard, modifier: Modifier = Modifier) {
    val accent = RecapTheme.accentFor(card)
    val primaryMetric = card.primaryMetric

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RecapEyebrow(
            text = primaryMetric?.label ?: card.kind.label(RecapInsightKind.LabelStyle.SHORT),
            accent = accent,
        )

        if (primaryMetric != null) {
            Text(
                text = primaryMetric.formatted,
                style = RecapTheme.Typography.tileNumeral,
                color = accent,
            )
        }

        Text(
            text = card.headline,
            style = RecapTheme.Typography.cardHeadline,
            color = AuroraColors.lightTextPrimary,
        )

        if (card.visual == RecapVisual.NONE && card.body.isNotEmpty()) {
            Text(
                text = card.body,
                style = RecapTheme.Typography.cardBody,
                color = AuroraColors.lightTextSecondary,
                maxLines = 3,
            )
        }

        val visualData = card.visualData
        if (card.visual != RecapVisual.NONE && visualData != null) {
            RecapCardVisualRenderer(
                visual = card.visual,
                visualData = visualData,
                accent = accent,
                modifier = Modifier.fillMaxWidth(),
            )
        } else if (card.comparison != null) {
            RecapDeltaChip(comparison = card.comparison!!)
        }
    }
}

// ── Standard Card (Medium / Wide) ──

@Composable
fun RecapStandardCard(card: RecapCard, modifier: Modifier = Modifier) {
    val accent = RecapTheme.accentFor(card)

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            RecapEyebrow(
                text = card.kind.label(RecapInsightKind.LabelStyle.SHORT),
                accent = accent,
            )
            Spacer(modifier = Modifier.weight(1f))
            card.comparison?.let { RecapDeltaChip(comparison = it) }
        }

        RecapCopy(headline = card.headline, message = card.body)

        val visualData = card.visualData
        if (card.visual != RecapVisual.NONE && visualData != null) {
            Spacer(modifier = Modifier.height(4.dp))
            RecapCardVisualRenderer(
                visual = card.visual,
                visualData = visualData,
                accent = accent,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// ── Closing Card ──

@Composable
fun RecapClosingCard(recap: MonthlyRecap, modifier: Modifier = Modifier, onShare: (() -> Unit)? = null) {
    val accent = AuroraColors.ember

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(RecapTheme.Layout.heroCornerRadius))
            .background(RecapTheme.wash(accent))
            .border(
                width = 1.dp,
                color = accent.copy(alpha = 0.35f),
                shape = RoundedCornerShape(RecapTheme.Layout.heroCornerRadius),
            )
            .padding(RecapTheme.Layout.heroPadding),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            RecapEyebrow(text = "Your month in a sentence", accent = accent)

            Text(
                text = recap.closingSentence,
                style = RecapTheme.Typography.heroHeadline.copy(fontSize = 22.sp, lineHeight = 28.sp),
                color = AuroraColors.lightTextPrimary,
            )

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
            ) {
                Icon(
                    imageVector = if (recap.isVoiceAuthored) Icons.Default.AutoAwesome else Icons.Default.Functions,
                    contentDescription = null,
                    tint = AuroraColors.lightTextMuted,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(modifier = Modifier.size(6.dp))
                Text(
                    text = if (recap.isVoiceAuthored) "Written with AI assistance" else "Written from your numbers, on this device",
                    style = RecapTheme.Typography.eyebrow.copy(fontSize = 11.sp),
                    color = AuroraColors.lightTextMuted,
                )

                if (onShare != null) {
                    Spacer(modifier = Modifier.weight(1f))
                    OutlinedButton(
                        onClick = onShare,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = accent),
                        border = ButtonDefaults.outlinedButtonBorder.copy(brush = androidx.compose.ui.graphics.SolidColor(accent.copy(alpha = 0.4f))),
                        modifier = Modifier.height(32.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Share,
                            contentDescription = null,
                            modifier = Modifier.size(13.dp),
                        )
                        Spacer(modifier = Modifier.size(4.dp))
                        Text(text = "Share", style = RecapTheme.Typography.eyebrow.copy(fontSize = 11.sp))
                    }
                }
            }
        }
    }
}

// ── Visual Dispatcher ──

@Composable
fun RecapCardVisualRenderer(visual: RecapVisual, visualData: RecapVisualData, accent: Color, modifier: Modifier = Modifier) {
    when {
        visual == RecapVisual.SPARKLINE && visualData is RecapVisualData.Series -> {
            RecapSparkline(values = visualData.values, accent = accent, modifier = modifier)
        }
        (visual == RecapVisual.SPARKLINE || visual == RecapVisual.TIMELINE) && visualData is RecapVisualData.DualSeries -> {
            RecapDualSparkline(current = visualData.current, reference = visualData.reference, accent = accent, modifier = modifier)
        }
        visual == RecapVisual.TIMELINE && visualData is RecapVisualData.Series -> {
            RecapSparkline(values = visualData.values, accent = accent, modifier = modifier)
        }
        (visual == RecapVisual.RANKING || visual == RecapVisual.BARS || visual == RecapVisual.SPOTLIGHT) && visualData is RecapVisualData.Ranked -> {
            RecapRankedBars(entries = visualData.entries, accent = accent, modifier = modifier)
        }
        visual == RecapVisual.DONUT && visualData is RecapVisualData.Ranked -> {
            Box(contentAlignment = Alignment.Center, modifier = modifier) {
                RecapDonut(entries = visualData.entries, accent = accent)
            }
        }
        visual == RecapVisual.HEATMAP && visualData is RecapVisualData.Matrix -> {
            RecapHeatmap(matrix = visualData.matrix, accent = accent, modifier = modifier)
        }
        visual == RecapVisual.RINGS && visualData is RecapVisualData.Rings -> {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = modifier) {
                visualData.values.forEach { ring ->
                    RecapRing(progress = ring.progress, caption = ring.caption, accent = accent)
                }
            }
        }
        visual == RecapVisual.STREAK && visualData is RecapVisualData.Streak -> {
            RecapStreakDots(flags = visualData.flags, accent = accent, modifier = modifier)
        }
        visual == RecapVisual.BEFORE_AFTER && visualData is RecapVisualData.Pair -> {
            RecapBeforeAfter(before = visualData.before, after = visualData.after, accent = accent, modifier = modifier)
        }
    }
}
