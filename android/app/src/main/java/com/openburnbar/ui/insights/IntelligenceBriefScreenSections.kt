// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.insights

import com.openburnbar.data.models.AgentProvider
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightAnomaly
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightConfidence
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTheme as CanvasTheme
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.insights.renderers.InsightWidgetRenderer
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween

// ─── Mercury hairline ──────────────────────────────────────────────────────

@Composable
internal fun MercuryHairline(isDark: Boolean, reduceMotion: Boolean, shimmer: Boolean) {
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury
    val aureate = if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
    val baseBrush =
        remember(mercury, aureate) {
            Brush.linearGradient(listOf(mercury, aureate))
        }

    val phase = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(shimmer, reduceMotion) {
        if (shimmer && !reduceMotion) {
            phase.snapTo(0f)
            phase.animateTo(
                targetValue = 1f,
                animationSpec =
                androidx.compose.animation.core.tween(
                    durationMillis = AuroraMotion.mercuryShimmerDuration.toInt(),
                    easing = androidx.compose.animation.core.EaseInOut,
                ),
            )
        }
    }

    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .background(baseBrush)
            .drawWithContent {
                drawContent()
                if (!reduceMotion && phase.value > 0f && phase.value < 1f) {
                    val width = size.width
                    val bandWidth = width * 0.18f
                    val center = phase.value * (width + bandWidth) - bandWidth / 2f
                    val shimmerBrush =
                        Brush.linearGradient(
                            colors =
                            listOf(
                                Color.White.copy(alpha = 0.0f),
                                Color.White.copy(alpha = 0.25f),
                                Color.White.copy(alpha = 0.0f),
                            ),
                            start = Offset(center - bandWidth / 2f, 0f),
                            end = Offset(center + bandWidth / 2f, 0f),
                        )
                    drawRect(shimmerBrush)
                }
            }
            .semantics { contentDescription = "Mercury divider" },
    )
}
// ─── Findings ─────────────────────────────────────────────────────────────

@Composable
internal fun FindingsSection(findings: List<InsightFinding>, onCitationTap: (InsightCitation) -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_FINDINGS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        SectionHeader(title = SECTION_FINDINGS_TITLE)
        findings.take(3).forEachIndexed { index, finding ->
            FindingRow(
                ordinal = index + 1,
                finding = finding,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun FindingRowHeader(
    ordinal: Int,
    severityColor: Color,
    severityLabel: String,
    confidence: InsightConfidence,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "%02d".format(ordinal),
            style = AuroraType.monoSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
        )
        Text(
            text = severityLabel.uppercase(),
            style = AuroraType.monoTiny.copy(letterSpacing = 1.4.sp),
            color = severityColor,
        )
        Spacer(modifier = Modifier.weight(1f))
        ConfidenceDots(confidence = confidence)
    }
}

@Composable
internal fun FindingRow(ordinal: Int, finding: InsightFinding, onCitationTap: (InsightCitation) -> Unit) {
    val isDark = isSystemInDarkTheme()
    val (severityColor, severityLabel) = finding.severity.palette(isDark)
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        // 3dp leading severity bar — full row height — mirrors iOS FindingRow.
        Box(
            modifier =
            Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(severityColor),
        )
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            FindingRowHeader(
                ordinal = ordinal,
                severityColor = severityColor,
                severityLabel = severityLabel,
                confidence = finding.confidence,
            )
            Text(
                text = finding.title,
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (finding.whyItMatters.isNotBlank()) {
                Text(
                    text = finding.whyItMatters,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (finding.evidence.isNotEmpty()) {
                CitationChipRow(citations = finding.evidence, onTap = onCitationTap)
            }
            if (finding.recommendedAction.isNotBlank()) {
                ActionStripe(text = finding.recommendedAction)
            }
        }
    }
}

@Composable
internal fun ConfidenceDots(confidence: InsightConfidence) {
    val isDark = isSystemInDarkTheme()
    val whimsy = AuroraColors.whimsy(isDark)
    val filled =
        when (confidence) {
            InsightConfidence.LOW -> 1
            InsightConfidence.MEDIUM -> 2
            InsightConfidence.HIGH -> 3
        }
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier.semantics {
            contentDescription = "Confidence ${confidence.name.lowercase()}"
        },
    ) {
        repeat(3) { index ->
            Box(
                modifier =
                Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(if (index < filled) whimsy else whimsy.copy(alpha = 0.25f)),
            )
        }
    }
}

// ─── Anomaly Atlas ────────────────────────────────────────────────────────

@Composable
internal fun AnomalyAtlasSection(anomalies: List<InsightAnomaly>, onCitationTap: (InsightCitation) -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_ANOMALIES),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_ANOMALIES_TITLE)
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(end = AuroraSpacing.md.dp),
        ) {
            items(anomalies) { anomaly ->
                AnomalyInstrumentCell(anomaly = anomaly, onCitationTap = onCitationTap)
            }
        }
    }
}

@Composable
internal fun AnomalyInstrumentCell(anomaly: InsightAnomaly, onCitationTap: (InsightCitation) -> Unit) {
    val isDark = isSystemInDarkTheme()
    val accessibilityLabel = "Anomaly ${anomaly.title}, z score %.1f".format(anomaly.score)
    val markerColor =
        when {
            kotlin.math.abs(anomaly.score) >= 3.0 -> InsightsColors.kpiNegative
            kotlin.math.abs(anomaly.score) >= 2.0 -> AuroraColors.ember(isDark)
            else -> InsightsColors.kpiNeutral
        }
    Column(
        modifier =
        Modifier
            .width(220.dp)
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.md.dp),
            )
            .clickable {
                anomaly.evidence.firstOrNull()?.let(onCitationTap)
            }
            .padding(AuroraSpacing.md.dp)
            .semantics { contentDescription = accessibilityLabel },
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        Text(
            text = "z %.1f".format(anomaly.score),
            style = AuroraType.monoLarge.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
            color = markerColor,
        )
        ZScoreGauge(
            score = anomaly.score,
            markerColor = markerColor,
            rule = MaterialTheme.colorScheme.outlineVariant,
        )
        Text(
            text = anomaly.title,
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
        )
        if (anomaly.detail.isNotBlank()) {
            Text(
                text = anomaly.detail,
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
            )
        }
        ConfidenceChip(confidence = anomaly.confidence)
    }
}

/**
 * Slim instrument scale showing where the z-score lands relative to the
 * conventional ±2σ threshold. Single Canvas: hairline axis, faint warning
 * band beyond ±2σ, tick at z = 0, ticks at ±2σ, and a filled marker dot.
 *
 * Domain auto-extends so |z| > 3 still fits: domain = `max(3, ceil(|score|))`.
 */
@Composable
internal fun ZScoreGauge(score: Double, markerColor: Color, rule: Color) {
    val domain = maxOf(3.0, kotlin.math.ceil(kotlin.math.abs(score)))
    val clamped = score.coerceIn(-domain, domain).toFloat()
    val warningTint = markerColor.copy(alpha = 0.10f)
    androidx.compose.foundation.Canvas(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(12.dp),
    ) {
        val width = size.width
        val height = size.height
        val centerY = height / 2f
        val fraction = (clamped + domain.toFloat()) / (2f * domain.toFloat())
        val zeroX = width * 0.5f
        val markerX = (width * fraction).coerceIn(2.dp.toPx(), width - 2.dp.toPx())
        val thresholdOffset = 2f / domain.toFloat() * (width / 2f)

        // Warning bands (|z| ≥ 2σ)
        drawRect(
            color = warningTint,
            topLeft = Offset(0f, centerY - 4.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(zeroX - thresholdOffset, 8.dp.toPx()),
        )
        drawRect(
            color = warningTint,
            topLeft = Offset(zeroX + thresholdOffset, centerY - 4.dp.toPx()),
            size = androidx.compose.ui.geometry.Size(width - (zeroX + thresholdOffset), 8.dp.toPx()),
        )

        // Axis
        drawLine(
            color = rule,
            start = Offset(0f, centerY),
            end = Offset(width, centerY),
            strokeWidth = 0.5.dp.toPx(),
        )

        // Zero tick
        drawLine(
            color = rule,
            start = Offset(zeroX, centerY - 4.dp.toPx()),
            end = Offset(zeroX, centerY + 4.dp.toPx()),
            strokeWidth = 0.75.dp.toPx(),
        )

        // ±2σ ticks (subtle, half-height)
        listOf(zeroX - thresholdOffset, zeroX + thresholdOffset).forEach { tickX ->
            drawLine(
                color = rule.copy(alpha = 0.6f),
                start = Offset(tickX, centerY - 2.5.dp.toPx()),
                end = Offset(tickX, centerY + 2.5.dp.toPx()),
                strokeWidth = 0.5.dp.toPx(),
            )
        }

        // Marker dot
        drawCircle(
            color = markerColor,
            radius = 2.dp.toPx(),
            center = Offset(markerX, centerY),
        )
    }
}

// ─── Recommendations ──────────────────────────────────────────────────────

@Composable
internal fun RecommendationsSection(recommendations: List<InsightRecommendation>, isDark: Boolean, onCitationTap: (InsightCitation) -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_RECOMMENDATIONS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_RECOMMENDATIONS_TITLE)
        recommendations.forEach { rec ->
            RecommendationCard(
                recommendation = rec,
                isDark = isDark,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun RecommendationCardHeader(
    recommendation: InsightRecommendation,
    isDark: Boolean,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Top,
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SeverityChip(severity = recommendation.severity)
            ConfidenceChip(confidence = recommendation.confidence)
        }
        EmberSeal(severity = recommendation.severity, isDark = isDark)
    }
}

@Composable
private fun RecommendationImpactLine(impact: String, isDark: Boolean) {
    val impactVisual = impactArrow(impact = impact, isDark = isDark)
    Text(
        text = "${impactVisual.arrow} $impact",
        style = AuroraType.monoSmall,
        color = impactVisual.color,
        modifier =
        Modifier.semantics {
            contentDescription = "Estimated impact, ${impactVisual.descLabel} $impact"
        },
    )
}

@Composable
internal fun RecommendationCard(recommendation: InsightRecommendation, isDark: Boolean, onCitationTap: (InsightCitation) -> Unit) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.md.dp),
            )
            .padding(AuroraSpacing.md.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            RecommendationCardHeader(recommendation = recommendation, isDark = isDark)
            Text(
                text = recommendation.title,
                style = AuroraType.headline,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (recommendation.rationale.isNotBlank()) {
                Text(
                    text = recommendation.rationale,
                    style = AuroraType.body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (recommendation.recommendedAction.isNotBlank()) {
                ActionStripe(text = recommendation.recommendedAction)
            }
            recommendation.estimatedImpact
                ?.takeIf { it.isNotBlank() }
                ?.let { impact -> RecommendationImpactLine(impact = impact, isDark = isDark) }
            if (recommendation.evidence.isNotEmpty()) {
                CitationChipRow(citations = recommendation.evidence, onTap = onCitationTap)
            }
        }
    }
}

/**
 * Sign-aware impact arrow + color, mirroring the iOS audit row
 * "Recommendation impact arrow infers direction from sign":
 *   - leading `−` / `-` (e.g. `−$54/week`): `↘` + success green (savings)
 *   - leading `+` (e.g. `+$120/week`): `↗` + ember warning (cost increase)
 *   - otherwise (e.g. `$54/week saved`, `Restores ~$12/day`): `↗` + success
 *     green, because the brief only emits non-prefixed strings for net
 *     positive recommendations. This avoids rewarding cost increases with
 *     the same green used for savings.
 *
 * Returned `descLabel` feeds the accessibility description so TalkBack
 * announces "savings of $54/week" or "increase of $120/week" instead of
 * the raw glyph.
 */
internal data class ImpactArrow(val arrow: String, val color: Color, val descLabel: String)

@Composable
internal fun impactArrow(impact: String, isDark: Boolean): ImpactArrow {
    val trimmed = impact.trim()
    return when {
        trimmed.startsWith("−") || trimmed.startsWith("-") ->
            ImpactArrow(
                arrow = "↘",
                color = if (isDark) AuroraColors.successDark else AuroraColors.success,
                descLabel = "savings of",
            )
        trimmed.startsWith("+") ->
            ImpactArrow(
                arrow = "↗",
                color = AuroraColors.ember(isDark),
                descLabel = "increase of",
            )
        else ->
            ImpactArrow(
                arrow = "↗",
                color = if (isDark) AuroraColors.successDark else AuroraColors.success,
                descLabel = "estimated",
            )
    }
}

/**
 * Severity-aware ember seal. HIGH/CRITICAL recommendations get a full
 * ember→blaze gradient — they're the ones the reader's eye should jump
 * to. MEDIUM/LOW/INFO get a muted ring so the seal stays informative
 * rather than decorative.
 */
@Composable
internal fun EmberSeal(severity: InsightSeverity, isDark: Boolean) {
    val ember = AuroraColors.ember(isDark)
    val blaze = AuroraColors.blaze
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val border = MaterialTheme.colorScheme.outlineVariant
    val highImpact = severity == InsightSeverity.HIGH || severity == InsightSeverity.CRITICAL
    val accessibilityLabel =
        if (highImpact) {
            "High-impact recommendation"
        } else {
            "Recommendation seal, severity ${severity.name.lowercase()}"
        }
    Box(
        modifier =
        Modifier
            .size(16.dp)
            .clip(CircleShape)
            .drawBehind {
                if (highImpact) {
                    drawCircle(
                        brush =
                        Brush.linearGradient(
                            colors = listOf(ember, blaze),
                            start = Offset.Zero,
                            end = Offset(size.width, size.height),
                        ),
                    )
                    drawCircle(
                        color = border,
                        radius = size.minDimension / 2f,
                        style = Stroke(width = 0.5.dp.toPx()),
                    )
                } else {
                    drawCircle(
                        color = muted.copy(alpha = 0.08f),
                    )
                    drawCircle(
                        color = muted.copy(alpha = 0.5f),
                        radius = size.minDimension / 2f,
                        style = Stroke(width = 0.5.dp.toPx()),
                    )
                }
            }
            .semantics { contentDescription = accessibilityLabel },
    )
}

// ─── Generated views ──────────────────────────────────────────────────────

@Composable
internal fun GeneratedViewsSection(
    generated: List<InsightGeneratedWidget>,
    figureStart: Int,
    theme: CanvasTheme,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_GENERATED),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_GENERATED_TITLE)
        generated.forEachIndexed { index, item ->
            GeneratedView(
                figureOrdinal = figureStart + index,
                generated = item,
                theme = theme,
                isDark = isDark,
                onPin = onPin,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
internal fun GeneratedView(
    figureOrdinal: Int,
    generated: InsightGeneratedWidget,
    theme: CanvasTheme,
    isDark: Boolean,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.md.dp),
            )
            .padding(AuroraSpacing.md.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            ) {
                Text(
                    text = "Fig. %02d".format(figureOrdinal),
                    style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = generated.widget.title,
                    style = AuroraType.headline,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { onPin(generated) },
                    modifier = Modifier.semantics { contentDescription = "Pin to canvas" },
                ) {
                    Text(
                        text = "Pin",
                        style = AuroraType.monoSmall,
                    )
                }
            }
            InsightWidgetRenderer(
                widget = generated.widget,
                onCitationTap = onCitationTap,
                theme = theme,
                showHeader = false,
            )
            if (generated.citations.isNotEmpty()) {
                CitationChipRow(
                    citations = generated.citations,
                    onTap = onCitationTap,
                )
            }
            if (generated.reason.isNotBlank()) {
                FigureCaption(reason = generated.reason, isDark = isDark)
            }
        }
    }
}

/**
 * Editorial-print figure caption: a 1.5dp tall mercury rule on the leading
 * edge with mono caption text. Replaces the previous bare text line for the
 * generated-view reason.
 */
@Composable
internal fun FigureCaption(reason: String, isDark: Boolean) {
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury
    val aureate = if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Box(
            modifier =
            Modifier
                .width(1.5.dp)
                .height(AuroraSpacing.lg.dp)
                .background(Brush.verticalGradient(listOf(mercury, aureate))),
        )
        Text(
            text = reason,
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ─── Follow-ups ───────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun FollowUpSection(questions: List<InsightFollowUpQuestion>, isDark: Boolean, onTap: (InsightFollowUpQuestion) -> Unit) {
    val whimsy = AuroraColors.whimsy(isDark)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_FOLLOWUPS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_FOLLOWUPS_TITLE)
        FlowRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        ) {
            questions.forEachIndexed { index, question ->
                if (index > 0) {
                    Text(
                        text = SEPARATOR,
                        style = AuroraType.body,
                        color = muted,
                    )
                }
                FollowUpClickable(
                    question = question,
                    color = whimsy,
                    onTap = onTap,
                )
            }
        }
    }
}

@Composable
internal fun FollowUpClickable(question: InsightFollowUpQuestion, color: Color, onTap: (InsightFollowUpQuestion) -> Unit) {
    val annotated =
        remember(question, color) {
            buildAnnotatedString {
                withStyle(
                    SpanStyle(
                        color = color,
                        textDecoration = TextDecoration.Underline,
                        fontFamily = FontFamily.SansSerif,
                        fontWeight = FontWeight.Medium,
                    ),
                ) {
                    append(question.question)
                }
            }
        }
    Text(
        text = annotated,
        style = AuroraType.body,
        modifier =
        Modifier
            .clickable { onTap(question) }
            .semantics { contentDescription = "Ask: ${question.question}" },
    )
}

// ─── Audit footer ─────────────────────────────────────────────────────────

@Composable
internal fun AuditFooterSection(result: InsightAnalysisResult, isDark: Boolean, onShowAudit: (() -> Unit)?) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_AUDIT),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        MercuryHairline(isDark = isDark, reduceMotion = true, shimmer = false)
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = IntelligenceBriefFormatting.auditFooter(result),
                style = AuroraType.monoSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
                maxLines = 2,
            )
            if (onShowAudit != null) {
                TextButton(
                    onClick = onShowAudit,
                    modifier = Modifier.semantics { contentDescription = "Open audit log" },
                ) {
                    Text(text = "Audit log", style = AuroraType.monoSmall)
                }
            }
        }
    }
}

// ─── Shared section header ────────────────────────────────────────────────

@Composable
internal fun SectionHeader(title: String) {
    Text(
        text = title,
        style = AuroraType.caption.copy(letterSpacing = 2.0.sp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.semantics { heading() },
    )
}

// ─── Chips ────────────────────────────────────────────────────────────────

@Composable
internal fun SeverityChip(severity: InsightSeverity) {
    val isDark = isSystemInDarkTheme()
    val (color, label) = severity.palette(isDark)
    Box(
        modifier =
        Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, color.copy(alpha = 0.6f)),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Severity ${label.lowercase()}" },
    ) {
        Text(
            text = label.uppercase(),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.Bold),
            color = color,
        )
    }
}

internal fun InsightSeverity.palette(isDark: Boolean): Pair<Color, String> = when (this) {
    InsightSeverity.INFO -> (if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary) to "info"
    InsightSeverity.LOW -> AuroraColors.whimsy(isDark) to "low"
    InsightSeverity.MEDIUM -> InsightsColors.kpiNeutral to "medium"
    InsightSeverity.HIGH -> AuroraColors.ember(isDark) to "high"
    InsightSeverity.CRITICAL -> InsightsColors.kpiNegative to "critical"
}

@Composable
internal fun ConfidenceChip(confidence: InsightConfidence) {
    val isDark = isSystemInDarkTheme()
    val whimsy = AuroraColors.whimsy(isDark)
    val dots =
        when (confidence) {
            InsightConfidence.LOW -> 1
            InsightConfidence.MEDIUM -> 2
            InsightConfidence.HIGH -> 3
        }
    val label =
        when (confidence) {
            InsightConfidence.LOW -> "low"
            InsightConfidence.MEDIUM -> "medium"
            InsightConfidence.HIGH -> "high"
        }
    Row(
        modifier =
        Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, whimsy.copy(alpha = 0.5f)),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Confidence $label" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        repeat(3) { index ->
            Box(
                modifier =
                Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(if (index < dots) whimsy else whimsy.copy(alpha = 0.2f)),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun CitationChipRow(citations: List<InsightCitation>, onTap: (InsightCitation) -> Unit) {
    val visible = citations.take(6)
    val overflow = citations.size - visible.size
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        visible.forEach { citation ->
            CitationChip(citation = citation, onTap = onTap)
        }
        if (overflow > 0) {
            Text(
                text = "…+$overflow",
                style = AuroraType.monoTiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier =
                Modifier
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .semantics { contentDescription = "$overflow more citations" },
            )
        }
    }
}

internal fun citationProvider(citation: InsightCitation): AgentProvider? =
    when (val kind = citation.kind) {
        is InsightCitation.Kind.Agent -> AgentProvider.fromKey(kind.provider)
        is InsightCitation.Kind.Session -> kind.provider?.let { AgentProvider.fromKey(it) }
        is InsightCitation.Kind.Quota -> AgentProvider.fromKey(kind.provider)
        else -> null
    }

@Composable
internal fun CitationChip(citation: InsightCitation, onTap: (InsightCitation) -> Unit) {
    val provider = citationProvider(citation)
    Row(
        modifier =
        Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .clickable { onTap(citation) }
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Citation ${citation.label}" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (provider != null) {
            ProviderLogo(
                provider = provider,
                size = 12.dp,
            )
        }
        Text(
            text = citation.label,
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
    }
}

@Composable
internal fun ActionStripe(text: String) {
    Text(
        text = "→ $text",
        style = AuroraType.body.copy(fontWeight = FontWeight.Medium),
        color = MaterialTheme.colorScheme.onSurface,
        modifier =
        Modifier
            .fillMaxWidth()
            .semantics { contentDescription = "Recommended action: $text" }
            .padding(top = 2.dp),
    )
}

internal const val SECTION_FINDINGS_TITLE = "TOP FINDINGS"
internal const val SECTION_MISSIONS_TITLE = "MISSION BOARD"
internal const val SECTION_ANOMALIES_TITLE = "ANOMALY ATLAS"
internal const val SECTION_RECOMMENDATIONS_TITLE = "RECOMMENDATIONS"
internal const val SECTION_GENERATED_TITLE = "GENERATED VIEWS"
internal const val SECTION_FOLLOWUPS_TITLE = "FOLLOW-UP QUESTIONS"

internal const val SECTION_TAG_FINDINGS = "section-findings"
internal const val SECTION_TAG_MISSIONS = "section-missions"
internal const val SECTION_TAG_ANOMALIES = "section-anomalies"
internal const val SECTION_TAG_RECOMMENDATIONS = "section-recommendations"
internal const val SECTION_TAG_GENERATED = "section-generated"
internal const val SECTION_TAG_FOLLOWUPS = "section-followups"
internal const val SECTION_TAG_AUDIT = "section-audit"

private const val SEPARATOR = "\u2003"
