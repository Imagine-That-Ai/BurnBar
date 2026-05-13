package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * A deterministic, columnar grid layout for the widgets on a canvas.
 * Mirrors Swift InsightLayout. Android phones use 2 columns,
 * tablets use 6 in split mode, 12 when full-width.
 */
@Serializable
data class InsightLayout(
    val columnCount: Int = 12,
    val rowHeight: Double = 96.0,
    val gap: Double = 12.0,
    val placements: Map<String, CellPlacement> = emptyMap(),
    val revision: Int = 0
) {
    @Serializable
    data class CellPlacement(
        val column: Int = 0,
        val row: Int = 0,
        val colSpan: Int = 1,
        val rowSpan: Int = 1
    )

    val rowCount: Int
        get() = placements.values.maxOfOrNull { it.row + it.rowSpan } ?: 0

    fun placeNew(widgetID: String, defaultSpan: Pair<Int, Int>): InsightLayout {
        val cols = defaultSpan.first.coerceIn(1, columnCount)
        val rows = maxOf(1, defaultSpan.second)
        val occupancy = makeOccupancyGrid()
        val (c, r) = firstFreeCell(occupancy, cols, rows)
        val newPlacements = placements.toMutableMap()
        newPlacements[widgetID] = CellPlacement(column = c, row = r, colSpan = cols, rowSpan = rows)
        return copy(placements = newPlacements, revision = revision + 1)
    }

    fun move(widgetID: String, toColumn: Int, toRow: Int): InsightLayout {
        val current = placements[widgetID] ?: return this
        val newCol = toColumn.coerceIn(0, columnCount - current.colSpan)
        val newRow = maxOf(0, toRow)
        val newPlacements = placements.toMutableMap()
        newPlacements[widgetID] = current.copy(column = newCol, row = newRow)
        return copy(placements = newPlacements, revision = revision + 1)
    }

    fun remove(widgetID: String): InsightLayout {
        val newPlacements = placements.toMutableMap()
        val existed = newPlacements.remove(widgetID) != null
        return if (existed) copy(placements = newPlacements, revision = revision + 1) else this
    }

    /** Resize a widget by setting new spans. Clamped to fit columnCount. Bumps `revision`. */
    fun resize(widgetID: String, colSpan: Int, rowSpan: Int): InsightLayout {
        val current = placements[widgetID] ?: return this
        val newCol = maxOf(1, minOf(colSpan, columnCount))
        val newRow = maxOf(1, rowSpan)
        val newColumn = minOf(current.column, maxOf(0, columnCount - newCol))
        val newPlacements = placements.toMutableMap()
        newPlacements[widgetID] = current.copy(colSpan = newCol, rowSpan = newRow, column = newColumn)
        return copy(placements = newPlacements, revision = revision + 1)
    }

    /** Project to a different column count, preserving widget order proportionally. */
    fun projectedTo(targetCols: Int): InsightLayout {
        val target = maxOf(1, targetCols)
        if (target == columnCount) return this
        val ordered = placements.entries.sortedWith(
            compareBy<Map.Entry<String, CellPlacement>>(
                { it.value.row },
                { it.value.column },
                { it.key }
            )
        )
        val projected = mutableMapOf<String, CellPlacement>()
        var cursorCol = 0
        var cursorRow = 0
        var rowMaxHeight = 0
        for ((id, p) in ordered) {
            val proportional = p.colSpan.toDouble() * target / maxOf(1, columnCount).toDouble()
            val span = maxOf(1, minOf(target, proportional.toInt()))
            if (cursorCol + span > target) {
                cursorRow += maxOf(1, rowMaxHeight)
                cursorCol = 0
                rowMaxHeight = 0
            }
            projected[id] = CellPlacement(
                column = cursorCol,
                row = cursorRow,
                colSpan = span,
                rowSpan = p.rowSpan
            )
            cursorCol += span
            rowMaxHeight = maxOf(rowMaxHeight, p.rowSpan)
        }
        return copy(columnCount = target, placements = projected)
    }

    private fun makeOccupancyGrid(): List<List<Boolean>> {
        val rows = rowCount + 1
        val grid = List(maxOf(rows, 1)) { MutableList(columnCount) { false } }
        for (p in placements.values) {
            for (r in p.row until minOf(p.row + p.rowSpan, grid.size)) {
                for (c in p.column until minOf(p.column + p.colSpan, columnCount)) {
                    grid[r][c] = true
                }
            }
        }
        return grid
    }

    private fun firstFreeCell(occupancy: List<List<Boolean>>, colSpan: Int, rowSpan: Int): Pair<Int, Int> {
        val rows = occupancy.size
        for (r in 0 until rows) {
            if (r + rowSpan > rows) break
            for (c in 0 until columnCount) {
                if (c + colSpan > columnCount) break
                if (rangeIsFree(occupancy, c, r, colSpan, rowSpan)) return c to r
            }
        }
        return 0 to rowCount
    }

    private fun rangeIsFree(occupancy: List<List<Boolean>>, c: Int, r: Int, colSpan: Int, rowSpan: Int): Boolean {
        for (rr in r until (r + rowSpan)) {
            for (cc in c until (c + colSpan)) {
                if (occupancy.getOrElse(rr) { emptyList() }.getOrElse(cc) { true }) return false
            }
        }
        return true
    }
}
