package com.openburnbar.ui.insights

import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
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
import com.openburnbar.data.insights.InsightContextBudgetReport
import com.openburnbar.data.insights.InsightFinding
import com.openburnbar.data.insights.InsightFollowUpQuestion
import com.openburnbar.data.insights.InsightGeneratedWidget
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.data.insights.InsightRecommendation
import com.openburnbar.data.insights.InsightSeverity
import com.openburnbar.data.insights.InsightTheme as CanvasTheme
import com.openburnbar.data.insights.InsightTimeWindow
import com.openburnbar.data.insights.InsightTokenUsage
import com.openburnbar.ui.insights.renderers.InsightWidgetRenderer
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraMotion
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlinx.coroutines.delay

/**
 * Editorial Observatory rewrite of the Intelligence Brief surface.
 *
 * Single-column layout, generous margins, footnote citation chips, mono
 * ordinal findings, anomaly instrument tray, ember-seal recommendations,
 * inline ClickableText follow-ups, and a mercury-hairline audit footer.
 *
 * Cross-platform parity with `IntelligenceBriefView` (Swift): identical
 * section order, copy, chip labels, accessibility order, and motion
 * behavior. The function signature is intentionally unchanged so the host
 * `InsightsScreen` keeps wiring through `(result = it)`.
 *
 * Story arc (no exceptions):
 *  1. Hero — eyebrow + time-window subtitle + 22sp headline + mono meta
 *     strip + mercury hairline (one shimmer sweep on appear).
 *  2. Top findings — mono ordinals (01/02/03…).
 *  3. Anomalies — `LazyRow` "instrument tray" with mono z-score numerals.
 *  4. Recommendations — ember seal top-right + mono impact arrow.
 *  5. Generated views — inline widget renderer + pin action.
 *  6. Follow-up questions — inline whimsy `ClickableText` segments.
 *  7. Audit footer — full-width mercury hairline + mono meta.
 */
@Composable
fun IntelligenceBriefScreen(
    result: InsightAnalysisResult,
    modifier: Modifier = Modifier,
    onCitationTap: (InsightCitation) -> Unit = {},
    onFollowUpTap: (InsightFollowUpQuestion) -> Unit = {},
    onPinWidget: (InsightGeneratedWidget) -> Unit = {},
    onConfigureModel: (() -> Unit)? = null,
    onShowAudit: (() -> Unit)? = null,
    theme: CanvasTheme = CanvasTheme.AURORA,
) {
    val isDark = isSystemInDarkTheme()
    val reduceMotion = rememberReduceMotion()

    // Section visibility — one boolean per story-arc slot. Cascade-in is
    // driven by a single LaunchedEffect that flips entries with a 40ms
    // stagger. Reduce-motion paints everything instantly.
    val visibility = rememberSectionVisibility(reduceMotion)

    // Pull the first chart-bearing widget up into the hero so a graph
    // lives ABOVE THE FOLD. Remaining widgets stay in the Generated views
    // section right after the hero. KPI/Time-Series/Ranking/Donut are
    // first-class chart kinds; we prefer them in that order so the hero
    // always leads with a chart, not a narrative card.
    val featuredWidget = result.generatedWidgets.firstOrNull { it.widget.isChart }
    val remainingWidgets = result.generatedWidgets.filterNot { it === featuredWidget }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.lg.dp)
            .padding(top = AuroraSpacing.md.dp, bottom = AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xl.dp),
    ) {
        AnimatedSection(visible = visibility[0], reduceMotion = reduceMotion) {
            HeroSection(
                result = result,
                featuredWidget = featuredWidget,
                isDark = isDark,
                reduceMotion = reduceMotion,
                onConfigureModel = onConfigureModel,
                onPinWidget = onPinWidget,
                onCitationTap = onCitationTap,
                theme = theme,
            )
        }

        // CHARTS NEXT — the remaining generated widgets render right after
        // the hero so graphs stay front and center. Findings + anomalies +
        // recommendations sit below, supporting the picture you just saw.
        if (remainingWidgets.isNotEmpty()) {
            AnimatedSection(visible = visibility[1], reduceMotion = reduceMotion) {
                GeneratedViewsSection(
                    generated = remainingWidgets,
                    theme = theme,
                    onPin = onPinWidget,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.findings.isNotEmpty()) {
            AnimatedSection(visible = visibility[2], reduceMotion = reduceMotion) {
                FindingsSection(
                    findings = result.findings,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.anomalies.isNotEmpty()) {
            AnimatedSection(visible = visibility[3], reduceMotion = reduceMotion) {
                AnomalyAtlasSection(
                    anomalies = result.anomalies,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.recommendations.isNotEmpty()) {
            AnimatedSection(visible = visibility[4], reduceMotion = reduceMotion) {
                RecommendationsSection(
                    recommendations = result.recommendations,
                    isDark = isDark,
                    onCitationTap = onCitationTap,
                )
            }
        }

        if (result.followUpQuestions.isNotEmpty()) {
            AnimatedSection(visible = visibility[5], reduceMotion = reduceMotion) {
                FollowUpSection(
                    questions = result.followUpQuestions,
                    isDark = isDark,
                    onTap = onFollowUpTap,
                )
            }
        }

        AnimatedSection(visible = visibility[6], reduceMotion = reduceMotion) {
            AuditFooterSection(
                result = result,
                isDark = isDark,
                onShowAudit = onShowAudit,
            )
        }
    }
}

/**
 * Chart-bearing widget kinds — the ones that paint a graph rather than a
 * narrative or table. Used to choose the hero featured widget so the
 * surface always leads with a picture, not prose.
 */
private val InsightWidget.isChart: Boolean
    get() = when (kind) {
        InsightWidgetKind.TIME_SERIES_LINE,
        InsightWidgetKind.TIME_SERIES_AREA,
        InsightWidgetKind.STREAM_GRAPH,
        InsightWidgetKind.BAR_RANKING,
        InsightWidgetKind.DONUT,
        InsightWidgetKind.TREEMAP,
        InsightWidgetKind.HEATMAP,
        InsightWidgetKind.SCATTER,
        InsightWidgetKind.SANKEY,
        InsightWidgetKind.RADAR,
        InsightWidgetKind.COHORT,
        InsightWidgetKind.FUNNEL,
        InsightWidgetKind.QUOTA_PULSE,
        InsightWidgetKind.FORECAST,
        InsightWidgetKind.AGENT_FOCUS_MATRIX,
        InsightWidgetKind.MODEL_FOCUS_MATRIX,
        InsightWidgetKind.KPI_TILE -> true
        else -> false
    }

// ─── Section visibility cascade ────────────────────────────────────────────

@Composable
private fun rememberSectionVisibility(reduceMotion: Boolean): SnapshotStateList<Boolean> {
    val state = remember { MutableList(SECTION_COUNT) { false }.toMutableStateList() }
    LaunchedEffect(reduceMotion) {
        if (reduceMotion) {
            for (i in 0 until SECTION_COUNT) state[i] = true
        } else {
            for (i in 0 until SECTION_COUNT) {
                state[i] = true
                delay(40L)
            }
        }
    }
    return state
}

private const val SECTION_COUNT = 7

@Composable
private fun AnimatedSection(
    visible: Boolean,
    reduceMotion: Boolean,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    if (reduceMotion) {
        // No motion: paint synchronously, identical visual outcome.
        content()
        return
    }
    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(
            animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f),
            initialOffsetY = { with(density) { 8.dp.roundToPx() } },
        ) + fadeIn(animationSpec = spring(stiffness = Spring.StiffnessLow, dampingRatio = 0.85f)),
    ) {
        content()
    }
}

// ─── Hero ─────────────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HeroSection(
    result: InsightAnalysisResult,
    featuredWidget: InsightGeneratedWidget?,
    isDark: Boolean,
    reduceMotion: Boolean,
    onConfigureModel: (() -> Unit)?,
    onPinWidget: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
    theme: CanvasTheme,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_HERO),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Text(
            text = EYEBROW,
            style = AuroraType.tiny.copy(
                letterSpacing = 1.4.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.semantics { contentDescription = EYEBROW_DESCRIPTION },
        )
        Text(
            text = IntelligenceBriefFormatting.windowLabel(result.timeWindow),
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Text(
            text = result.executiveSummary,
            style = AuroraType.title.copy(
                fontFamily = FontFamily.SansSerif,
                fontSize = 22.sp,
                lineHeight = 30.8.sp, // 1.4× line-height
                fontWeight = FontWeight.SemiBold,
            ),
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.semantics { heading() },
        )
        if (featuredWidget != null) {
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            HeroChartFrame(
                generated = featuredWidget,
                theme = theme,
                isDark = isDark,
                onPin = onPinWidget,
                onCitationTap = onCitationTap,
            )
        }
        MetaStrip(
            modelTag = result.modelTag,
            budget = result.contextBudget,
            tokenUsage = result.tokenUsage,
            costUSD = result.estimatedCostUSD,
            onConfigureModel = onConfigureModel,
        )
        MercuryHairline(
            isDark = isDark,
            reduceMotion = reduceMotion,
            shimmer = true,
        )
    }
}

/**
 * Above-the-fold hero chart. Same renderer the Generated Views section
 * uses, wrapped in a borderless figure-style frame so it reads as part
 * of the editorial lede instead of a card. A mercury figure caption
 * underneath ties the chart to the executive summary above.
 */
@Composable
private fun HeroChartFrame(
    generated: InsightGeneratedWidget,
    theme: CanvasTheme,
    isDark: Boolean,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_HERO_CHART),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            Text(
                text = "Fig. 01 · ${generated.widget.title}",
                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = { onPin(generated) },
                modifier = Modifier.semantics { contentDescription = "Pin chart to canvas" },
            ) {
                Text(text = "Pin", style = AuroraType.monoSmall)
            }
        }
        // Render the chart only — pass showHeader=false so the renderer
        // doesn't repeat the title we already drew with the Fig. ordinal.
        InsightWidgetRenderer(
            widget = generated.widget,
            onCitationTap = onCitationTap,
            theme = theme,
            showHeader = false,
        )
        if (generated.reason.isNotBlank()) {
            FigureCaption(reason = generated.reason, isDark = isDark)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MetaStrip(
    modelTag: InsightModelTag,
    budget: InsightContextBudgetReport,
    tokenUsage: InsightTokenUsage?,
    costUSD: Double?,
    onConfigureModel: (() -> Unit)?,
) {
    val parts = buildList {
        add(modelTag.displayName)
        add(modelTag.egressTier.displayLabel)
        add(IntelligenceBriefFormatting.budgetLabel(budget))
        if (tokenUsage != null) add(IntelligenceBriefFormatting.tokenUsageLabel(tokenUsage, costUSD))
    }
    // Append the `·` separator to the END of every non-final token (glued
    // with NBSP so it never wraps off its preceding word). `FlowRow` wraps
    // between children, so this keeps the dot trailing the line above
    // instead of orphaning at the start of the next line.
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        parts.forEachIndexed { index, label ->
            val text = if (index < parts.size - 1) "$label\u00A0·" else label
            Text(
                text = text,
                style = AuroraType.monoSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (onConfigureModel != null) {
            TextButton(
                onClick = onConfigureModel,
                modifier = Modifier.semantics { contentDescription = "Adjust model" },
            ) {
                Text(text = "Adjust", style = AuroraType.monoSmall)
            }
        }
    }
}

// ─── Mercury hairline ──────────────────────────────────────────────────────

@Composable
private fun MercuryHairline(
    isDark: Boolean,
    reduceMotion: Boolean,
    shimmer: Boolean,
) {
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury
    val aureate = if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
    val baseBrush = remember(mercury, aureate) {
        Brush.linearGradient(listOf(mercury, aureate))
    }

    val phase = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(shimmer, reduceMotion) {
        if (shimmer && !reduceMotion) {
            phase.snapTo(0f)
            phase.animateTo(
                targetValue = 1f,
                animationSpec = androidx.compose.animation.core.tween(
                    durationMillis = AuroraMotion.mercuryShimmerDuration.toInt(),
                    easing = androidx.compose.animation.core.EaseInOut,
                ),
            )
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .background(baseBrush)
            .drawWithContent {
                drawContent()
                if (!reduceMotion && phase.value > 0f && phase.value < 1f) {
                    val width = size.width
                    val bandWidth = width * 0.18f
                    val center = phase.value * (width + bandWidth) - bandWidth / 2f
                    val shimmerBrush = Brush.linearGradient(
                        colors = listOf(
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
private fun FindingsSection(
    findings: List<InsightFinding>,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_FINDINGS),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_FINDINGS_TITLE)
        findings.forEachIndexed { index, finding ->
            if (index > 0) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(0.5.dp)
                        .background(MaterialTheme.colorScheme.outlineVariant),
                )
            }
            FindingRow(
                ordinal = index + 1,
                finding = finding,
                onCitationTap = onCitationTap,
            )
        }
    }
}

@Composable
private fun FindingRow(
    ordinal: Int,
    finding: InsightFinding,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        Text(
            text = "%02d".format(ordinal),
            style = AuroraType.monoTiny.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(28.dp),
        )
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SeverityChip(severity = finding.severity)
                ConfidenceChip(confidence = finding.confidence)
            }
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

// ─── Anomaly Atlas ────────────────────────────────────────────────────────

@Composable
private fun AnomalyAtlasSection(
    anomalies: List<InsightAnomaly>,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
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
private fun AnomalyInstrumentCell(
    anomaly: InsightAnomaly,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val accessibilityLabel = "Anomaly ${anomaly.title}, z score %.1f".format(anomaly.score)
    val markerColor = when {
        kotlin.math.abs(anomaly.score) >= 3.0 -> InsightsColors.kpiNegative
        kotlin.math.abs(anomaly.score) >= 2.0 -> AuroraColors.ember(isDark)
        else -> InsightsColors.kpiNeutral
    }
    Column(
        modifier = Modifier
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
private fun ZScoreGauge(
    score: Double,
    markerColor: Color,
    rule: Color,
) {
    val domain = maxOf(3.0, kotlin.math.ceil(kotlin.math.abs(score)))
    val clamped = score.coerceIn(-domain, domain).toFloat()
    val warningTint = markerColor.copy(alpha = 0.10f)
    androidx.compose.foundation.Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(12.dp),
    ) {
        val width = size.width
        val height = size.height
        val centerY = height / 2f
        val fraction = (clamped + domain.toFloat()) / (2f * domain.toFloat())
        val zeroX = width * 0.5f
        val markerX = (width * fraction).coerceIn(2.dp.toPx(), width - 2.dp.toPx())
        val thresholdOffset = (2f / domain.toFloat()) * (width / 2f)

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
private fun RecommendationsSection(
    recommendations: List<InsightRecommendation>,
    isDark: Boolean,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Column(
        modifier = Modifier
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
private fun RecommendationCard(
    recommendation: InsightRecommendation,
    isDark: Boolean,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Box(
        modifier = Modifier
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
                ?.let { impact ->
                    val (arrow, color, descLabel) = impactArrow(
                        impact = impact,
                        isDark = isDark,
                    )
                    Text(
                        text = "$arrow $impact",
                        style = AuroraType.monoSmall,
                        color = color,
                        modifier = Modifier.semantics {
                            contentDescription = "Estimated impact, $descLabel $impact"
                        },
                    )
                }
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
private data class ImpactArrow(val arrow: String, val color: Color, val descLabel: String)

@Composable
private fun impactArrow(impact: String, isDark: Boolean): ImpactArrow {
    val trimmed = impact.trim()
    return when {
        trimmed.startsWith("−") || trimmed.startsWith("-") -> ImpactArrow(
            arrow = "↘",
            color = if (isDark) AuroraColors.successDark else AuroraColors.success,
            descLabel = "savings of",
        )
        trimmed.startsWith("+") -> ImpactArrow(
            arrow = "↗",
            color = AuroraColors.ember(isDark),
            descLabel = "increase of",
        )
        else -> ImpactArrow(
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
private fun EmberSeal(severity: InsightSeverity, isDark: Boolean) {
    val ember = AuroraColors.ember(isDark)
    val blaze = AuroraColors.blaze
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val border = MaterialTheme.colorScheme.outlineVariant
    val highImpact = severity == InsightSeverity.HIGH || severity == InsightSeverity.CRITICAL
    val accessibilityLabel = if (highImpact) {
        "High-impact recommendation"
    } else {
        "Recommendation seal, severity ${severity.name.lowercase()}"
    }
    Box(
        modifier = Modifier
            .size(16.dp)
            .clip(CircleShape)
            .drawBehind {
                if (highImpact) {
                    drawCircle(
                        brush = Brush.linearGradient(
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
private fun GeneratedViewsSection(
    generated: List<InsightGeneratedWidget>,
    theme: CanvasTheme,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(SECTION_TAG_GENERATED),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        SectionHeader(title = SECTION_GENERATED_TITLE)
        generated.forEachIndexed { index, item ->
            GeneratedView(
                figureOrdinal = index + 1,
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
private fun GeneratedView(
    figureOrdinal: Int,
    generated: InsightGeneratedWidget,
    theme: CanvasTheme,
    isDark: Boolean,
    onPin: (InsightGeneratedWidget) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
) {
    Box(
        modifier = Modifier
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
private fun FigureCaption(reason: String, isDark: Boolean) {
    val mercury = if (isDark) AuroraColors.hermesMercuryDark else AuroraColors.hermesMercury
    val aureate = if (isDark) AuroraColors.hermesAureateDark else AuroraColors.hermesAureate
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
    ) {
        Box(
            modifier = Modifier
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
private fun FollowUpSection(
    questions: List<InsightFollowUpQuestion>,
    isDark: Boolean,
    onTap: (InsightFollowUpQuestion) -> Unit,
) {
    val whimsy = AuroraColors.whimsy(isDark)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        modifier = Modifier
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
private fun FollowUpClickable(
    question: InsightFollowUpQuestion,
    color: Color,
    onTap: (InsightFollowUpQuestion) -> Unit,
) {
    val annotated = remember(question, color) {
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
        modifier = Modifier
            .clickable { onTap(question) }
            .semantics { contentDescription = "Ask: ${question.question}" },
    )
}

// ─── Audit footer ─────────────────────────────────────────────────────────

@Composable
private fun AuditFooterSection(
    result: InsightAnalysisResult,
    isDark: Boolean,
    onShowAudit: (() -> Unit)?,
) {
    Column(
        modifier = Modifier
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
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.semantics { heading() },
    )
}

// ─── Chips ────────────────────────────────────────────────────────────────

@Composable
private fun SeverityChip(severity: InsightSeverity) {
    val isDark = isSystemInDarkTheme()
    val (color, label) = severity.palette(isDark)
    Box(
        modifier = Modifier
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

private fun InsightSeverity.palette(isDark: Boolean): Pair<Color, String> = when (this) {
    InsightSeverity.INFO -> (if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary) to "info"
    InsightSeverity.LOW -> AuroraColors.whimsy(isDark) to "low"
    InsightSeverity.MEDIUM -> InsightsColors.kpiNeutral to "medium"
    InsightSeverity.HIGH -> AuroraColors.ember(isDark) to "high"
    InsightSeverity.CRITICAL -> InsightsColors.kpiNegative to "critical"
}

@Composable
private fun ConfidenceChip(confidence: InsightConfidence) {
    val isDark = isSystemInDarkTheme()
    val whimsy = AuroraColors.whimsy(isDark)
    val dots = when (confidence) {
        InsightConfidence.LOW -> 1
        InsightConfidence.MEDIUM -> 2
        InsightConfidence.HIGH -> 3
    }
    val label = when (confidence) {
        InsightConfidence.LOW -> "low"
        InsightConfidence.MEDIUM -> "medium"
        InsightConfidence.HIGH -> "high"
    }
    Row(
        modifier = Modifier
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
                modifier = Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(if (index < dots) whimsy else whimsy.copy(alpha = 0.2f)),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CitationChipRow(
    citations: List<InsightCitation>,
    onTap: (InsightCitation) -> Unit,
) {
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
                modifier = Modifier
                    .padding(horizontal = 8.dp, vertical = 2.dp)
                    .semantics { contentDescription = "$overflow more citations" },
            )
        }
    }
}

@Composable
private fun CitationChip(
    citation: InsightCitation,
    onTap: (InsightCitation) -> Unit,
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .border(
                BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(AuroraRadius.full.dp),
            )
            .clickable { onTap(citation) }
            .padding(horizontal = 8.dp, vertical = 2.dp)
            .semantics { contentDescription = "Citation ${citation.label}" },
    ) {
        Text(
            text = citation.label,
            style = AuroraType.monoTiny,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
    }
}

@Composable
private fun ActionStripe(text: String) {
    Text(
        text = "→ $text",
        style = AuroraType.body.copy(fontWeight = FontWeight.Medium),
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = "Recommended action: $text" }
            .padding(top = 2.dp),
    )
}

// ─── Reduce motion ────────────────────────────────────────────────────────

@Composable
private fun rememberReduceMotion(): Boolean {
    val auroraReduce = LocalAuroraReduceMotion.current
    val context = LocalContext.current
    val accessibilityReduce = remember(context) {
        runCatching {
            val am = context.getSystemService(AccessibilityManager::class.java)
            am?.isEnabled == true && am.isTouchExplorationEnabled
        }.getOrDefault(false)
    }
    return auroraReduce || accessibilityReduce
}

// ─── Strings & test tags ──────────────────────────────────────────────────

private const val EYEBROW = "INTELLIGENCE BRIEF"
private const val EYEBROW_DESCRIPTION = "Intelligence Brief"

internal const val SECTION_FINDINGS_TITLE = "Top findings"
internal const val SECTION_ANOMALIES_TITLE = "Anomalies"
internal const val SECTION_RECOMMENDATIONS_TITLE = "Recommendations"
internal const val SECTION_GENERATED_TITLE = "Generated views"
internal const val SECTION_FOLLOWUPS_TITLE = "Follow-up questions"

internal const val SECTION_TAG_HERO = "section-hero"
internal const val SECTION_TAG_HERO_CHART = "section-hero-chart"
internal const val SECTION_TAG_FINDINGS = "section-findings"
internal const val SECTION_TAG_ANOMALIES = "section-anomalies"
internal const val SECTION_TAG_RECOMMENDATIONS = "section-recommendations"
internal const val SECTION_TAG_GENERATED = "section-generated"
internal const val SECTION_TAG_FOLLOWUPS = "section-followups"
internal const val SECTION_TAG_AUDIT = "section-audit"

/** Em-space between follow-up question segments. */
private const val SEPARATOR = "\u2003"

// ─── Formatting helpers ───────────────────────────────────────────────────

/**
 * Shared formatting helpers — exposed so tests and the audit screen render
 * the same chip labels as the brief itself.
 */
object IntelligenceBriefFormatting {
    fun windowLabel(window: InsightTimeWindow): String = when (window) {
        InsightTimeWindow.Today -> "Today"
        InsightTimeWindow.Last24h -> "Last 24 hours"
        InsightTimeWindow.Last7d -> "Last 7 days"
        InsightTimeWindow.Last30d -> "Last 30 days"
        InsightTimeWindow.Last90d -> "Last 90 days"
        InsightTimeWindow.Last365d -> "Last 365 days"
        InsightTimeWindow.AllTime -> "All time"
        is InsightTimeWindow.Custom -> "${window.start} – ${window.end}"
    }

    fun budgetLabel(budget: InsightContextBudgetReport): String {
        val kb = (budget.encodedBytes / 1024).coerceAtLeast(1)
        val tokens = budget.estimatedPromptTokens
        val base = "~$kb KB · ~$tokens tokens"
        return if (budget.truncatedDataSources.isEmpty()) base else "$base · trimmed"
    }

    fun tokenUsageLabel(usage: InsightTokenUsage, cost: Double?): String {
        val total = usage.totalTokens
        return if (cost != null) "$total tokens · $%.4f".format(cost) else "$total tokens"
    }

    fun auditFooter(result: InsightAnalysisResult): String {
        val auditPrefix = result.auditID?.let { "Audit ${it.take(8)}" } ?: "Local run"
        val hash = result.resultHash.take(8)
        return "$auditPrefix · result $hash · ${result.modelTag.egressTier.displayLabel}"
    }
}
