package com.openburnbar.ui.insights

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.openburnbar.data.insights.InsightCanvas
import com.openburnbar.data.insights.InsightCitation
import com.openburnbar.data.insights.InsightWidget
import com.openburnbar.data.insights.InsightLayout
import com.openburnbar.data.insights.InsightWidgetData
import com.openburnbar.data.insights.ValueFormat
import com.openburnbar.ui.insights.renderers.InsightWidgetRenderer
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
    val projectedLayout = remember(canvas) {
        // Default: phone uses 2 columns; tablet uses 6 in split, 12 full-width
        // TODO: use LocalConfiguration to determine actual column count
        canvas.layout.projectedTo(2)
    }

    Layout(
        content = {
            canvas.widgets.forEach { widget ->
                androidx.compose.runtime.key(widget.id) {
                    WidgetCard(
                        widget = widget,
                        isSelected = widget.id == selectedWidgetId,
                        onSelect = { onSelect(widget.id) },
                        onCitationTap = onCitationTap
                    )
                }
            }
        },
        modifier = modifier.fillMaxWidth()
    ) { measurables, constraints ->
        val columnCount = projectedLayout.columnCount.coerceAtLeast(1)
        val gap = projectedLayout.gap.dp.value.toInt() // approximate px
        val rowHeightPx = projectedLayout.rowHeight.dp.value.toInt()
        val columnWidth = (constraints.maxWidth - (columnCount - 1).coerceAtLeast(0) * gap) / columnCount

        // Match widgets to their placements by ID
        val widgetIds = canvas.widgets.map { it.id }
        val placements = projectedLayout.placements

        val placeables = measurables.mapIndexedNotNull { idx, measurable ->
            val widgetId = widgetIds.getOrElse(idx) { "" }
            val placement = placements[widgetId] ?: InsightLayout.CellPlacement(
                column = 0, row = idx, colSpan = 1, rowSpan = 1
            )
            val w = (placement.colSpan * columnWidth + (placement.colSpan - 1).coerceAtLeast(0) * gap)
                .coerceAtLeast(1)
            val h = (placement.rowSpan * rowHeightPx + (placement.rowSpan - 1).coerceAtLeast(0) * gap)
                .coerceAtLeast(1)
            Triple(widgetId, measurable.measure(Constraints.fixed(w, h)), placement)
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

@Composable
private fun WidgetCard(
    widget: InsightWidget,
    isSelected: Boolean,
    onSelect: () -> Unit,
    onCitationTap: (InsightCitation) -> Unit
) {
    val surfaceColor = if (isSelected) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.surfaceVariant
    }

    Card(
        modifier = Modifier.fillMaxWidth().padding(2.dp),
        colors = CardDefaults.cardColors(containerColor = surfaceColor),
        elevation = CardDefaults.cardElevation(defaultElevation = if (isSelected) 4.dp else 1.dp),
        onClick = onSelect
    ) {
        Box(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
            InsightWidgetRenderer(
                widget = widget,
                onCitationTap = onCitationTap
            )
        }
    }
}
