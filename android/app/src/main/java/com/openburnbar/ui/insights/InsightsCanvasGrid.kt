package com.openburnbar.ui.insights

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightTheme
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightLayout
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.InsightWidgetKind
import com.openburnbar.ui.insights.renderers.InsightWidgetRenderer
import com.openburnbar.ui.insights.renderers.formatValue
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Custom grid layout for Insight Canvas widgets. Mirrors the iOS
 * `InsightCanvasGrid` using Compose's `Layout` composable for deterministic
 * placement with cell-snap drag support.
 *
 * Phones use 2 columns; tablets use 6 in split mode, 12 when full-width.
 * The projection algorithm reflows widgets proportionally.
 */
@Composable
fun InsightsCanvasGrid(
    canvas: InsightCanvas,
    selectedWidgetId: String?,
    onSelect: (String) -> Unit,
    onMove: (String, Int, Int) -> Unit,
    onConfigure: (String) -> Unit,
    onCitationTap: (InsightCitation) -> Unit,
    modifier: Modifier = Modifier
) {
    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val targetColumns = when {
            maxWidth < 600.dp -> 1
            maxWidth < 840.dp -> 2
            else -> 6
        }
        val projectedLayout = remember(canvas.layout, targetColumns) {
            canvas.layout.projectedTo(targetColumns)
        }
        val isPhone = targetColumns == 1

        if (isPhone) {
            PhoneInsightsDeck(
                canvas = canvas,
                selectedWidgetId = selectedWidgetId,
                onSelect = onSelect,
                onCitationTap = onCitationTap
            )
            return@BoxWithConstraints
        }

        Layout(
            content = {
                canvas.widgets.forEach { widget ->
                    androidx.compose.runtime.key(widget.id) {
                        WidgetCard(
                            widget = widget,
                            theme = canvas.theme,
                            isSelected = widget.id == selectedWidgetId,
                            onSelect = { onSelect(widget.id) },
                            onCitationTap = onCitationTap
                        )
                    }
                }
            },
            modifier = Modifier.fillMaxWidth()
        ) { measurables, constraints ->
            val columnCount = projectedLayout.columnCount.coerceAtLeast(1)
            val gap = (if (isPhone) 10.dp else projectedLayout.gap.dp).roundToPx()
            val rowHeightPx = (if (isPhone) 74.dp else projectedLayout.rowHeight.dp).roundToPx()
            val columnWidth = (constraints.maxWidth - (columnCount - 1).coerceAtLeast(0) * gap) / columnCount

            val widgetIds = canvas.widgets.map { it.id }
            val placements = projectedLayout.placements

            val placeables = measurables.mapIndexed { idx, measurable ->
                val widgetId = widgetIds.getOrElse(idx) { "" }
                val placement = placements[widgetId] ?: InsightLayout.CellPlacement(
                    column = 0, row = idx, colSpan = 1, rowSpan = 1
                )
                val width = (placement.colSpan * columnWidth + (placement.colSpan - 1).coerceAtLeast(0) * gap)
                    .coerceAtLeast(1)
                val height = (placement.rowSpan * rowHeightPx + (placement.rowSpan - 1).coerceAtLeast(0) * gap)
                    .coerceAtLeast(1)
                Triple(widgetId, measurable.measure(Constraints.fixed(width, height)), placement)
            }

            val totalRow = placements.values.maxOfOrNull { it.row + it.rowSpan } ?: 0
            val height = (totalRow * rowHeightPx + (totalRow - 1).coerceAtLeast(0) * gap)
                .coerceAtLeast(rowHeightPx)

            layout(constraints.maxWidth, height) {
                placeables.forEach { (_, placeable, placement) ->
                    val x = placement.column * (columnWidth + gap)
                    val y = placement.row * (rowHeightPx + gap)
                    placeable.placeRelative(x, y)
                }
            }
        }
    }
}

@Composable
private fun PhoneInsightsDeck(
    canvas: InsightCanvas,
    selectedWidgetId: String?,
    onSelect: (String) -> Unit,
    onCitationTap: (InsightCitation) -> Unit
) {
    val kpiWidgets = canvas.widgets.filter { it.kind == InsightWidgetKind.KPI_TILE }
    val heroKpis = kpiWidgets.take(3)
    val supportingWidgets = canvas.widgets.filterNot { heroKpis.any { hero -> hero.id == it.id } }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (heroKpis.isNotEmpty()) {
            SnapshotCard(canvas = canvas, kpis = heroKpis)
        }
        supportingWidgets.forEach { widget ->
            androidx.compose.runtime.key(widget.id) {
                WidgetCard(
                    widget = widget,
                    theme = canvas.theme,
                    isSelected = widget.id == selectedWidgetId,
                    onSelect = { onSelect(widget.id) },
                    onCitationTap = onCitationTap
                )
            }
        }
    }
}

@Composable
private fun SnapshotCard(canvas: InsightCanvas, kpis: List<InsightWidget>) {
    val accent = InsightsColors.accentsFor(canvas.theme).first()
    val primary = kpis.firstOrNull { it.title.contains("cost", ignoreCase = true) } ?: kpis.first()
    val primaryData = primary.data as? InsightWidgetData.KPI
    val secondary = kpis.filterNot { it.id == primary.id }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
        shape = RoundedCornerShape(14.dp),
        border = BorderStroke(1.dp, accent.copy(alpha = 0.28f))
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    Brush.linearGradient(
                        listOf(
                            accent.copy(alpha = 0.18f),
                            MaterialTheme.colorScheme.surface.copy(alpha = 0f)
                        )
                    )
                )
                .padding(18.dp)
        ) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = canvas.title.ifBlank { "Today" },
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = primary.title,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(
                    text = "Fresh",
                    style = MaterialTheme.typography.labelLarge,
                    color = InsightsColors.freshnessFresh,
                    fontWeight = FontWeight.Bold
                )
            }

            Spacer(modifier = Modifier.height(10.dp))

            Text(
                text = primaryData?.let { formatValue(it.value, it.valueFormat) } ?: primary.title,
                style = MaterialTheme.typography.displayMedium,
                color = accent,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )

            if (secondary.isNotEmpty()) {
                Spacer(modifier = Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    secondary.forEach { widget ->
                        SnapshotMetric(widget = widget, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun SnapshotMetric(widget: InsightWidget, modifier: Modifier = Modifier) {
    val data = widget.data as? InsightWidgetData.KPI
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(MaterialTheme.colorScheme.background.copy(alpha = 0.42f))
            .padding(horizontal = 10.dp, vertical = 9.dp)
    ) {
        Text(
            text = widget.title,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        Text(
            text = data?.let { formatValue(it.value, it.valueFormat) } ?: "--",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurface,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun WidgetCard(
    widget: InsightWidget,
    theme: InsightTheme,
    isSelected: Boolean,
    onSelect: () -> Unit,
    onCitationTap: (InsightCitation) -> Unit
) {
    val surfaceColor = MaterialTheme.colorScheme.surface.copy(alpha = if (isSelected) 0.98f else 0.90f)
    val borderColor = if (isSelected) {
        MaterialTheme.colorScheme.primary.copy(alpha = 0.55f)
    } else {
        MaterialTheme.colorScheme.outline.copy(alpha = 0.12f)
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = surfaceColor),
        elevation = CardDefaults.cardElevation(defaultElevation = if (isSelected) 2.dp else 0.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, borderColor),
        onClick = onSelect
    ) {
        Box(modifier = Modifier.padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)) {
            InsightWidgetRenderer(
                widget = widget,
                onCitationTap = onCitationTap,
                theme = theme
            )
        }
    }
}
