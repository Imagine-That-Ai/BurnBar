package com.openburnbar.ui.insights.verdict

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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.Canvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.verdict.InsightVerdict
import com.openburnbar.data.insights.verdict.ProviderTint
import com.openburnbar.data.insights.verdict.VerdictAcceptAction
import com.openburnbar.data.insights.verdict.VerdictBullet
import com.openburnbar.data.insights.verdict.VerdictBulletType
import com.openburnbar.data.insights.verdict.VerdictRecommendation
import com.openburnbar.data.insights.verdict.VerdictRing
import kotlin.math.roundToInt

/**
 * Compose mirror of the SwiftUI `VerdictHeroView`.
 *
 * Plan §5.1 — pinned above the canvas grid on every platform. Layout:
 *   chip row → headline → subhead → provenance pill → rings strip →
 *   bullets → optional recommendation card → follow-ups.
 *
 * Cross-platform parity: rendered identically modulo platform chrome
 * (Material 3 surface colors here vs UnifiedDesignSystem.Colors on
 * Apple).
 */
@Composable
fun VerdictHeroSection(
    verdict: InsightVerdict,
    isStale: Boolean = false,
    isDemo: Boolean = false,
    onRefresh: () -> Unit = {},
    onCitationTap: (InsightCitation) -> Unit = {},
    onAcceptAction: (VerdictAcceptAction) -> Unit = {},
    onFollowUpTap: (String) -> Unit = {},
    onTraceTap: (String) -> Unit = {},
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .border(
                width = 1.dp,
                color = verdict.moodSwatch.toComposeColor().copy(alpha = 0.25f),
                shape = RoundedCornerShape(16.dp)
            )
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        ChipRow(
            window = verdict.window.displayLabel,
            isStale = isStale,
            isDemo = isDemo,
            confidence = verdict.confidence.name,
            onRefresh = onRefresh
        )
        Text(
            text = verdict.headline,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        verdict.subhead?.let { sub ->
            Text(
                text = sub,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        ProvenancePill(
            providerKey = verdict.provenance.providerKey,
            displayName = verdict.provenance.displayName,
            egressTier = verdict.provenance.egressTier.displayLabel
        )
        RingsStrip(rings = verdict.rings)
        if (verdict.bullets.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                verdict.bullets.forEach { bullet ->
                    BulletRow(
                        bullet = bullet,
                        onCitationTap = onCitationTap,
                        onAcceptAction = onAcceptAction
                    )
                }
            }
        }
        verdict.recommendation?.let { rec ->
            RecommendationCard(
                recommendation = rec,
                onCitationTap = onCitationTap,
                onAcceptAction = onAcceptAction
            )
        }
        if (verdict.followUps.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "ASK NEXT",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                verdict.followUps.forEach { q ->
                    TextButton(
                        onClick = { onFollowUpTap(q) },
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)
                    ) {
                        Text("→ $q", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    }
}

@Composable
private fun ChipRow(
    window: String,
    isStale: Boolean,
    isDemo: Boolean,
    confidence: String,
    onRefresh: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Pill(text = window, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        when {
            isDemo -> Pill(text = "Demo verdict", tint = MaterialTheme.colorScheme.tertiary)
            isStale -> TextButton(onClick = onRefresh) {
                Text("Stale · Refresh", style = MaterialTheme.typography.labelSmall)
            }
        }
        Spacer(Modifier.weight(1f))
        Text(
            "Confidence · ${confidence.lowercase()}",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun Pill(text: String, tint: Color) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 4.dp)
    ) {
        Text(text, style = MaterialTheme.typography.labelSmall, color = tint)
    }
}

@Composable
private fun ProvenancePill(providerKey: String, displayName: String, egressTier: String) {
    val tint = when (providerKey) {
        "local-rules" -> MaterialTheme.colorScheme.secondary
        "burnbar-demo" -> MaterialTheme.colorScheme.tertiary
        else -> MaterialTheme.colorScheme.primary
    }
    val text = when (providerKey) {
        "local-rules" -> "Authored locally · Rule engine · $egressTier"
        "burnbar-demo" -> "Demo verdict · $egressTier"
        else -> "Authored by $displayName · $egressTier"
    }
    Pill(text = text, tint = tint)
}

@Composable
private fun RingsStrip(rings: List<VerdictRing>) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        rings.forEach { ring ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(modifier = Modifier.size(56.dp)) {
                    Canvas(modifier = Modifier.size(56.dp)) {
                        val stroke = 9.dp.toPx()
                        val color = ring.tint.toComposeColor()
                        drawCircle(
                            color = color.copy(alpha = 0.15f),
                            radius = size.minDimension / 2 - stroke / 2,
                            style = Stroke(width = stroke)
                        )
                        val sweep = (ring.progress.coerceAtMost(1.0) * 360).toFloat()
                        drawArc(
                            color = color,
                            startAngle = -90f,
                            sweepAngle = sweep,
                            useCenter = false,
                            topLeft = Offset(stroke / 2, stroke / 2),
                            size = Size(
                                width = size.width - stroke,
                                height = size.height - stroke
                            ),
                            style = Stroke(width = stroke)
                        )
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        ring.label.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        ring.valueLabel,
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    ring.delta?.let { d ->
                        val arrow = if (d.value == 0.0) "·" else if (d.value > 0) "↑" else "↓"
                        Text(
                            "$arrow ${kotlin.math.abs(d.value).roundToInt()}% ${d.baseline}",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (d.isFavorable)
                                MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BulletRow(
    bullet: VerdictBullet,
    onCitationTap: (InsightCitation) -> Unit,
    onAcceptAction: (VerdictAcceptAction) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top
    ) {
        Text(
            text = bullet.type.glyph(),
            style = MaterialTheme.typography.bodyMedium,
            color = bullet.type.tint()
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                bullet.claim,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface
            )
            if (bullet.citations.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    bullet.citations.forEach { cite ->
                        TextButton(
                            onClick = { onCitationTap(cite) },
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                                horizontal = 6.dp, vertical = 2.dp
                            )
                        ) {
                            Text(cite.label, style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
        }
        bullet.acceptAction?.let { action ->
            TextButton(onClick = { onAcceptAction(action) }) {
                Text("${action.label} →", style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun RecommendationCard(
    recommendation: VerdictRecommendation,
    onCitationTap: (InsightCitation) -> Unit,
    onAcceptAction: (VerdictAcceptAction) -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.06f))
            .border(
                width = 1.dp,
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.25f),
                shape = RoundedCornerShape(12.dp)
            )
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("✦ ${recommendation.headline}",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.weight(1f))
            Text(recommendation.expectedImpact,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.primary)
        }
        Text(recommendation.rationale,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment = Alignment.CenterVertically) {
            recommendation.citations.forEach { cite ->
                TextButton(onClick = { onCitationTap(cite) },
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = 6.dp, vertical = 2.dp
                    )) {
                    Text(cite.label, style = MaterialTheme.typography.labelSmall)
                }
            }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { onAcceptAction(recommendation.acceptAction) }) {
                Text("${recommendation.acceptAction.label} →",
                    style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

private fun ProviderTint.toComposeColor(): Color = when (this) {
    ProviderTint.ember -> Color(0xFFD25A2A)
    ProviderTint.whimsy -> Color(0xFF6B5BFF)
    ProviderTint.silver -> Color(0xFF8B8B8B)
    ProviderTint.mercury -> Color(0xFF6E8898)
    ProviderTint.prism -> Color(0xFF7A5AFF)
    ProviderTint.ember_alt -> Color(0xFFE39B5C)
    ProviderTint.neutral -> Color(0xFF9A9A9A)
}

private fun VerdictBulletType.glyph(): String = when (this) {
    VerdictBulletType.reflective_fact -> "●"
    VerdictBulletType.comparison -> "↔"
    VerdictBulletType.pattern -> "≈"
    VerdictBulletType.anomaly -> "⚠"
    VerdictBulletType.recommendation -> "✦"
    VerdictBulletType.discovery -> "✧"
    VerdictBulletType.forecast -> "↗"
    VerdictBulletType.achievement -> "★"
    VerdictBulletType.risk -> "⚑"
    VerdictBulletType.story -> "▸"
}

@Composable
private fun VerdictBulletType.tint(): Color = when (this) {
    VerdictBulletType.anomaly, VerdictBulletType.risk -> MaterialTheme.colorScheme.error
    VerdictBulletType.recommendation,
    VerdictBulletType.achievement,
    VerdictBulletType.discovery -> MaterialTheme.colorScheme.primary
    VerdictBulletType.forecast -> MaterialTheme.colorScheme.tertiary
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
