// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.calendar

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.CalendarDayCost
import com.openburnbar.data.stores.CalendarModelCost
import com.openburnbar.data.stores.CalendarProjectCost
import com.openburnbar.data.stores.CalendarProviderShare
import com.openburnbar.data.stores.CalendarSelectionSnapshot
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ModelLogo
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.util.Formatting
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt
import kotlin.math.sqrt

// MARK: - Calendar Analytics Panel
//
// The selection-driven half of the Calendar surface: a three-column flow of
// Aurora glass cards. All aggregation is already prepared inside
// `CalendarSelectionSnapshot`; cards perform zero math of their own beyond
// share fractions. Mirrors the macOS `CalendarAnalyticsPanel`.

/**
 * Greedily packs visible card configs into rows whose span sums to at most 3
 * columns (S=1, M=2, L=3). Pure; unit-tested.
 */
internal fun packCalendarRows(configs: List<CalendarCardConfig>): List<List<CalendarCardConfig>> {
    val rows = mutableListOf<List<CalendarCardConfig>>()
    var current = mutableListOf<CalendarCardConfig>()
    var currentSpan = 0
    for (config in configs) {
        val span = config.span.columns
        if (currentSpan + span > 3 && current.isNotEmpty()) {
            rows.add(current)
            current = mutableListOf()
            currentSpan = 0
        }
        current.add(config)
        currentSpan += span
    }
    if (current.isNotEmpty()) rows.add(current)
    return rows
}

@Composable
fun CalendarAnalyticsPanel(
    layout: CalendarPageLayout,
    snapshot: CalendarSelectionSnapshot,
    editing: Boolean,
    onMove: (CalendarCardKind, Int) -> Unit,
    onHide: (CalendarCardKind) -> Unit,
    onCycleSpan: (CalendarCardKind) -> Unit,
) {
    val rows = packCalendarRows(layout.visibleConfigs)
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        rows.forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
            ) {
                row.forEach { config ->
                    CalendarCardFrame(
                        config = config,
                        editing = editing,
                        isFirst = layout.configs.firstOrNull()?.kind == config.kind,
                        isLast = layout.configs.lastOrNull()?.kind == config.kind,
                        onMove = { delta -> onMove(config.kind, delta) },
                        onHide = { onHide(config.kind) },
                        onCycleSpan = { onCycleSpan(config.kind) },
                        modifier = Modifier.weight(config.span.columns.toFloat()),
                    ) {
                        CalendarCardBody(kind = config.kind, snapshot = snapshot)
                    }
                }
            }
        }
    }
}

// MARK: - Card frame

@Composable
private fun CalendarCardFrame(
    config: CalendarCardConfig,
    editing: Boolean,
    isFirst: Boolean,
    isLast: Boolean,
    onMove: (Int) -> Unit,
    onHide: () -> Unit,
    onCycleSpan: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    AuroraGlassCard(modifier = modifier, contentPadding = AuroraSpacing.MD.dp) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = config.kind.title,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (editing) {
                IconButton(onClick = { onMove(-1) }, enabled = !isFirst, modifier = Modifier.size(26.dp)) {
                    Icon(
                        Icons.Filled.ExpandLess,
                        contentDescription = "Move up",
                        tint = MaterialTheme.colorScheme.onSurface.copy(alpha = if (isFirst) 0.25f else 0.7f),
                        modifier = Modifier.size(16.dp),
                    )
                }
                IconButton(onClick = { onMove(1) }, enabled = !isLast, modifier = Modifier.size(26.dp)) {
                    Icon(
                        Icons.Filled.ExpandMore,
                        contentDescription = "Move down",
                        tint = MaterialTheme.colorScheme.onSurface.copy(alpha = if (isLast) 0.25f else 0.7f),
                        modifier = Modifier.size(16.dp),
                    )
                }
                SpanBadge(span = config.span, onClick = onCycleSpan)
                IconButton(onClick = onHide, modifier = Modifier.size(26.dp)) {
                    Icon(
                        Icons.Filled.VisibilityOff,
                        contentDescription = "Hide card",
                        tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
        Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
        content()
        Spacer(modifier = Modifier.height(AuroraSpacing.SM.dp))
        Text(
            text = config.kind.whyItMatters,
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
        )
    }
}

@Composable
private fun SpanBadge(span: CalendarCardSpan, onClick: () -> Unit) {
    Box(
        modifier =
        Modifier
            .padding(horizontal = 2.dp)
            .size(22.dp)
            .clip(CircleShape)
            .background(AuroraColors.teal.copy(alpha = 0.18f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = span.shortLabel,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = AuroraColors.teal,
        )
    }
}

@Composable
private fun CalendarCardBody(kind: CalendarCardKind, snapshot: CalendarSelectionSnapshot) {
    when (kind) {
        CalendarCardKind.KPIS -> CalendarKpiTiles(snapshot)
        CalendarCardKind.BURN_OVER_SELECTION -> CalendarBurnBars(dailyBurn = snapshot.dailyBurn)
        CalendarCardKind.PROVIDER_MIX -> CalendarProviderMix(shares = snapshot.providerShares)
        CalendarCardKind.MODEL_MIX -> CalendarModelMix(models = snapshot.topModels)
        CalendarCardKind.HOUR_OF_DAY_HEATMAP -> CalendarHourHeatmap(snapshot)
        CalendarCardKind.PROJECT_FOCUS -> CalendarProjectFocus(projects = snapshot.projectShares)
        CalendarCardKind.CACHE_ROI -> CalendarCacheTiles(snapshot)
        CalendarCardKind.REASONING_SHARE -> CalendarReasoningTiles(snapshot)
    }
}

// MARK: - KPI tiles

@Composable
private fun CalendarKpiTiles(snapshot: CalendarSelectionSnapshot) {
    val tiles =
        listOf(
            "Cost" to Formatting.formatCurrency(snapshot.totalCost),
            "Tokens" to Formatting.formatTokens(snapshot.totalTokens),
            "Sessions" to snapshot.sessionCount.toString(),
            "Active days" to "${snapshot.activeDays}/${snapshot.selectedDays.size}",
            "Avg cost/day" to Formatting.formatCurrency(snapshot.averageCostPerDay),
        )
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            tiles.take(3).forEach { (label, value) -> KpiTile(label, value, Modifier.weight(1f)) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            tiles.drop(3).forEach { (label, value) -> KpiTile(label, value, Modifier.weight(1f)) }
            Spacer(modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun KpiTile(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier =
        modifier
            .clip(RoundedCornerShape(AuroraRadius.MD.dp))
            .background(AuroraColors.teal.copy(alpha = 0.08f))
            .padding(horizontal = AuroraSpacing.SM.dp, vertical = AuroraSpacing.SM.dp),
    ) {
        Text(
            text = value,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = label,
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
        )
    }
}

// MARK: - Burn over selection (per-day cost bars)

@Composable
private fun CalendarBurnBars(dailyBurn: List<CalendarDayCost>) {
    if (dailyBurn.isEmpty()) return
    val peak = dailyBurn.maxOf { it.cost }.takeIf { it > 0.0 } ?: 1.0
    val barBrush =
        Brush.verticalGradient(
            colors = listOf(AuroraColors.ember, AuroraColors.amber.copy(alpha = 0.8f)),
        )
    val silentColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.15f)
    Canvas(modifier = Modifier.fillMaxWidth().height(72.dp)) {
        val count = dailyBurn.size
        val slot = size.width / count
        val barWidth = (slot * 0.62f).coerceAtLeast(1.5f)
        val corner = CornerRadius(barWidth * 0.35f)
        dailyBurn.forEachIndexed { index, dayCost ->
            val fraction = (dayCost.cost / peak).toFloat().coerceIn(0f, 1f)
            val x = index * slot + (slot - barWidth) / 2f
            if (fraction <= 0f) {
                // Silent day — baseline tick so the gap stays visible.
                drawRect(
                    color = silentColor,
                    topLeft = Offset(x, size.height - 2f),
                    size = Size(barWidth, 2f),
                )
            } else {
                val barHeight = (size.height * fraction).coerceAtLeast(3f)
                val path =
                    Path().apply {
                        addRoundRect(
                            RoundRect(
                                Rect(Offset(x, size.height - barHeight), Size(barWidth, barHeight)),
                                corner,
                            ),
                        )
                    }
                drawPath(path = path, brush = barBrush)
            }
        }
    }
    Spacer(modifier = Modifier.height(2.dp))
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        val labelFormat = DateTimeFormatter.ofPattern("MMM d")
        Text(
            text = dailyBurn.first().day.format(labelFormat),
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        )
        Text(
            text = "peak ${Formatting.formatCompactCurrency(peak)}",
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        )
        Text(
            text = dailyBurn.last().day.format(labelFormat),
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        )
    }
}

// MARK: - Provider mix

@Composable
private fun CalendarProviderMix(shares: List<CalendarProviderShare>) {
    if (shares.isEmpty()) {
        CalendarEmptyCardText("No provider spend in this selection.")
        return
    }
    val max = shares.maxOf { it.cost }.takeIf { it > 0.0 } ?: 1.0
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        shares.take(MAX_MIX_ROWS).forEach { share ->
            CalendarShareRow(
                label = share.displayName,
                cost = share.cost,
                fraction = (share.cost / max).toFloat(),
                barColor = share.provider?.let { Color(it.brandColor) } ?: AuroraColors.teal,
            ) {
                if (share.provider != null) {
                    ProviderLogo(provider = share.provider, size = 16.dp, circular = true)
                } else {
                    Box(modifier = Modifier.size(16.dp).clip(CircleShape).background(AuroraColors.teal.copy(alpha = 0.3f)))
                }
            }
        }
    }
}

// MARK: - Model mix

@Composable
private fun CalendarModelMix(models: List<CalendarModelCost>) {
    if (models.isEmpty()) {
        CalendarEmptyCardText("No model usage in this selection.")
        return
    }
    val max = models.maxOf { it.cost }.takeIf { it > 0.0 } ?: 1.0
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        models.forEach { model ->
            CalendarShareRow(
                label = model.model,
                cost = model.cost,
                fraction = (model.cost / max).toFloat(),
                barColor = AuroraColors.whimsy,
            ) {
                ModelLogo(modelKey = model.model, size = 16.dp, circular = true)
            }
        }
    }
}

// MARK: - Project focus

@Composable
private fun CalendarProjectFocus(projects: List<CalendarProjectCost>) {
    if (projects.isEmpty()) {
        CalendarEmptyCardText("No project spend in this selection.")
        return
    }
    val max = projects.maxOf { it.cost }.takeIf { it > 0.0 } ?: 1.0
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        projects.forEach { project ->
            CalendarShareRow(
                label = project.name,
                cost = project.cost,
                fraction = (project.cost / max).toFloat(),
                barColor = AuroraColors.amber,
            ) {
                Box(
                    modifier = Modifier.size(16.dp).clip(CircleShape).background(AuroraColors.amber.copy(alpha = 0.25f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = project.name.take(1).uppercase(),
                        fontSize = 9.sp,
                        fontWeight = FontWeight.Bold,
                        color = AuroraColors.blaze,
                    )
                }
            }
        }
    }
}

@Composable
private fun CalendarShareRow(label: String, cost: Double, fraction: Float, barColor: Color, leading: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            leading()
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = label,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = Formatting.formatCurrency(cost),
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
            )
        }
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)),
        ) {
            Box(
                modifier =
                Modifier
                    .fillMaxWidth(fraction.coerceIn(0f, 1f))
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(2.dp))
                    .background(barColor.copy(alpha = 0.75f)),
            )
        }
    }
}

// MARK: - Hour-of-day heatmap

private val WEEKDAY_ROW_LABELS = listOf("S", "M", "T", "W", "T", "F", "S")

@Composable
private fun CalendarHourHeatmap(snapshot: CalendarSelectionSnapshot) {
    val matrix = snapshot.hourWeekdayCost
    val peakValue = matrix.flatten().maxOrNull() ?: 0.0
    Row(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(top = 1.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            WEEKDAY_ROW_LABELS.forEach { label ->
                Box(modifier = Modifier.height(14.dp), contentAlignment = Alignment.Center) {
                    Text(
                        text = label,
                        fontSize = 8.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.width(12.dp),
                    )
                }
            }
        }
        Spacer(modifier = Modifier.width(4.dp))
        Canvas(modifier = Modifier.weight(1f).height((14 * 7 + 2 * 6).dp)) {
            val slotW = size.width / CalendarSelectionSnapshot.HOURS_PER_DAY
            val slotH = size.height / CalendarSelectionSnapshot.WEEKDAYS
            val cellW = slotW - 1.5f
            val cellH = slotH - 2f
            val corner = CornerRadius(2f, 2f)
            matrix.forEachIndexed { weekday, hours ->
                hours.forEachIndexed { hour, value ->
                    val fraction = if (peakValue > 0.0) (value / peakValue).toFloat().coerceIn(0f, 1f) else 0f
                    val color =
                        if (fraction <= 0f) {
                            Color(0xFF888888).copy(alpha = 0.08f)
                        } else {
                            // sqrt ramp matches ChartKitHeatmap.fill(for:peak:).
                            AuroraColors.ember.copy(alpha = 0.14f + 0.78f * sqrt(fraction))
                        }
                    drawRoundRect(
                        color = color,
                        topLeft = Offset(hour * slotW, weekday * slotH),
                        size = Size(cellW, cellH),
                        cornerRadius = corner,
                    )
                }
            }
        }
    }
    val peakWeekday = snapshot.peakWeekdayIndex
    val peakHour = snapshot.peakHour
    if (peakWeekday != null && peakHour != null) {
        Spacer(modifier = Modifier.height(2.dp))
        Text(
            text = "Peak: ${WEEKDAY_ROW_LABELS[peakWeekday]} ${"%02d:00".format(peakHour)}",
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
        )
    }
}

// MARK: - Cache / reasoning tiles

@Composable
private fun CalendarCacheTiles(snapshot: CalendarSelectionSnapshot) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            KpiTile("Cache hit rate", "${(snapshot.cacheHitRate * 100).roundToInt()}%", Modifier.weight(1f))
            KpiTile("Cache reads", Formatting.formatTokens(snapshot.cacheReadTokens), Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            KpiTile("Savings (est.)", Formatting.formatCurrency(snapshot.cacheSavingsEstimate), Modifier.weight(1f))
            Spacer(modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun CalendarReasoningTiles(snapshot: CalendarSelectionSnapshot) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        KpiTile("Reasoning share", "${(snapshot.reasoningShare * 100).roundToInt()}%", Modifier.weight(1f))
        KpiTile("Reasoning tokens", Formatting.formatTokens(snapshot.reasoningTokens), Modifier.weight(1f))
    }
}

@Composable
private fun CalendarEmptyCardText(message: String) {
    Text(
        text = message,
        fontSize = 10.sp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
    )
}

private const val MAX_MIX_ROWS = 8
