// Pure Living Layout Space Budget solver data models and algorithm.
// No Android UI / Robolectric dependencies — 100% pure JVM arithmetic.

package com.openburnbar.ui.pulse.layout

import kotlin.math.max
import kotlin.math.min

/**
 * One region a shell asks the canvas for.
 *
 * A slot describes appetite, never geometry: what it cannot go below, what it
 * would like, how many more rows it could honestly fill, and how willing it is
 * to absorb leftover height. The canvas decides the numbers.
 */
data class HomeSlot(
    val id: String,
    val rank: Int = 0,
    val floor: Float = 100f,
    val ideal: Float = floor,
    val stretch: Double = 0.0,
    val rows: RowAppetite? = null,
    val isAmbient: Boolean = false,
    val spans: Boolean = false,
) {
    /**
     * How much more real content a slot could show if the canvas can afford it.
     */
    class RowAppetite(
        available: Int,
        baseline: Int = 0,
        unit: Float = 20f,
        ceiling: Int = 99,
    ) {
        val available: Int = max(0, available)
        val baseline: Int = max(0, min(baseline, max(0, available)))
        val unit: Float = max(1f, unit)
        val ceiling: Int = max(0, ceiling)

        val cap: Int get() = min(available, ceiling)

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is RowAppetite) return false
            return available == other.available &&
                baseline == other.baseline &&
                unit == other.unit &&
                ceiling == other.ceiling
        }

        override fun hashCode(): Int {
            var result = available
            result = 31 * result + baseline
            result = 31 * result + unit.hashCode()
            result = 31 * result + ceiling
            return result
        }

        override fun toString(): String = "RowAppetite(available=$available, baseline=$baseline, unit=$unit, ceiling=$ceiling)"
    }
}

/**
 * What the canvas granted, ready to be rendered without further arithmetic.
 */
data class HomeSpacePlan(
    val placements: List<Placement>,
    val columns: Int,
    val overflows: Boolean,
    val spanningIDs: List<String>,
) {
    data class Placement(
        val id: String,
        val height: Float?,
        val rowCount: Int,
        val column: Int,
        val isVisible: Boolean,
    )

    fun placement(id: String): Placement? = placements.firstOrNull { it.id == id }

    fun rowCount(id: String, fallback: Int = 0): Int = placement(id)?.rowCount ?: fallback

    fun height(id: String): Float? = placement(id)?.height

    fun isVisible(id: String): Boolean = placement(id)?.isVisible ?: true

    val columnGroups: List<List<String>>
        get() {
            if (columns <= 0) return emptyList()
            val spanning = spanningIDs.toSet()
            return (0 until columns).map { column ->
                placements
                    .filter { it.column == column && it.isVisible && it.id !in spanning }
                    .map { it.id }
            }
        }

    val visibleSpanningIDs: List<String>
        get() = spanningIDs.filter { isVisible(it) }

    companion object {
        val EMPTY = HomeSpacePlan(
            placements = emptyList(),
            columns = 1,
            overflows = false,
            spanningIDs = emptyList(),
        )
    }
}

/**
 * Resolves slot appetite against a canvas.
 */
object HomeSpaceBudget {
    const val TWO_COLUMN_WIDTH: Float = 1080f
    const val THREE_COLUMN_WIDTH: Float = 1580f
    const val COLUMN_DEAD_BAND: Float = 60f

    fun columns(forWidth: Float, current: Int, slots: Int): Int {
        if (forWidth <= 0f) {
            return max(1, min(current, max(1, slots)))
        }

        val ceiling = max(1, min(3, slots))
        val target: Int = when {
            forWidth >= THREE_COLUMN_WIDTH + COLUMN_DEAD_BAND -> 3
            forWidth <= THREE_COLUMN_WIDTH - COLUMN_DEAD_BAND -> {
                when {
                    forWidth >= TWO_COLUMN_WIDTH + COLUMN_DEAD_BAND -> 2
                    forWidth <= TWO_COLUMN_WIDTH - COLUMN_DEAD_BAND -> 1
                    else -> min(max(current, 1), 2)
                }
            }
            else -> min(max(current, 2), 3)
        }
        return min(target, ceiling)
    }

    /**
     * Resolve a full plan for a canvas.
     *
     * reason: `canvasWidth` is deliberately unread — column count is resolved separately
     * by `resolveColumns(forWidth:)`. The parameter stays so this signature matches its
     * Swift (`LivingSpaceBudget`), C# and TypeScript twins; dropping it on one platform
     * only is how the four ports quietly diverge.
     */
    // reason: canvasWidth is intentionally unread — kept for signature parity with the Swift/C#/TS twins.
    @Suppress("UnusedParameter")
    fun resolve(canvasWidth: Float, canvasHeight: Float, slots: List<HomeSlot>, gutter: Float, columns: Int = 1): HomeSpacePlan {
        if (slots.isEmpty()) return HomeSpacePlan.EMPTY

        val requested = max(1, columns)
        val spanning = if (requested > 1) slots.filter { it.spans } else emptyList()
        val columnar = if (requested > 1) slots.filter { !it.spans } else slots
        val spanningIDs = spanning.map { it.id }

        val columnCount = max(1, min(requested, max(1, columnar.size)))
        val assignment = deal(slots = columnar, into = columnCount)

        if (canvasHeight <= 0f) {
            return unmeasuredPlan(slots, assignment, columnCount, spanningIDs)
        }

        val bandHeight = spanning.sumOf { it.ideal.toDouble() }.toFloat() +
            gutter * spanning.size.toFloat()
        val columnarResult = columnarPlacements(
            columnar = columnar,
            assignment = assignment,
            columnCount = columnCount,
            height = canvasHeight - bandHeight,
            gutter = gutter,
        )

        val placements = bandPlacements(spanning) + columnarResult.placements
        val anyColumnOverflows = columnarResult.overflows

        // An overflowing column drops every measured height: the plan reverts to intrinsic
        // sizing rather than shipping heights that do not fit.
        val finalPlacements = if (anyColumnOverflows) {
            placements.map { it.copy(height = null) }
        } else {
            placements
        }

        val order = slots.withIndex().associate { it.value.id to it.index }

        return HomeSpacePlan(
            placements = finalPlacements.sortedBy { order[it.id] ?: 0 },
            columns = columnCount,
            overflows = anyColumnOverflows,
            spanningIDs = spanningIDs,
        )
    }

    // / No measured canvas yet — every slot is visible at its baseline and the plan
    // / declares itself overflowing so callers fall back to intrinsic sizing.
    private fun unmeasuredPlan(slots: List<HomeSlot>, assignment: Map<String, Int>, columnCount: Int, spanningIDs: List<String>): HomeSpacePlan = HomeSpacePlan(
        placements = slots.map { slot ->
            HomeSpacePlan.Placement(
                id = slot.id,
                height = null,
                rowCount = slot.rows?.baseline ?: 0,
                column = assignment[slot.id] ?: 0,
                isVisible = true,
            )
        },
        columns = columnCount,
        overflows = true,
        spanningIDs = spanningIDs,
    )

    // / Full-width slots, which always sit in column 0 at their ideal height.
    private fun bandPlacements(spanning: List<HomeSlot>): List<HomeSpacePlan.Placement> = spanning.map { slot ->
        HomeSpacePlan.Placement(
            id = slot.id,
            height = slot.ideal,
            rowCount = slot.rows?.baseline ?: 0,
            column = 0,
            isVisible = true,
        )
    }

    private data class ColumnarResult(
        val placements: List<HomeSpacePlan.Placement>,
        val overflows: Boolean,
    )

    private fun columnarPlacements(columnar: List<HomeSlot>, assignment: Map<String, Int>, columnCount: Int, height: Float, gutter: Float): ColumnarResult {
        val placements = mutableListOf<HomeSpacePlan.Placement>()
        var overflows = false
        for (column in 0 until columnCount) {
            val members = columnar.filter { assignment[it.id] == column }
            if (members.isEmpty()) continue
            val resolved = resolveColumn(members, height = height, gutter = gutter)
            overflows = overflows || resolved.overflows
            placements.addAll(
                resolved.placements.map {
                    HomeSpacePlan.Placement(
                        id = it.id,
                        height = it.height,
                        rowCount = it.rowCount,
                        column = column,
                        isVisible = it.isVisible,
                    )
                },
            )
        }
        return ColumnarResult(placements, overflows)
    }

    // / Spend slack on real rows, one round-robin pass at a time, cheapest slot first.
    // /
    // / Round-robin rather than greedy so a single hungry slot cannot eat the whole
    // / budget before a lower-ranked one gets its first row. Returns the slack left over,
    // / which the caller then distributes as breathing room.
    private fun feedRows(kept: List<HomeSlot>, rowCounts: MutableMap<String, Int>, initialSlack: Float): Float {
        var slack = initialSlack
        val feeding = kept.filter { it.rows != null }.sortedBy { it.rank }
        var fed = true
        while (slack > 0f && fed) {
            fed = false
            for (slot in feeding) {
                val appetite = slot.rows ?: continue
                val current = rowCounts[slot.id] ?: 0
                val canGrow = current < appetite.cap && slack >= appetite.unit
                if (canGrow) {
                    rowCounts[slot.id] = current + 1
                    slack -= appetite.unit
                    fed = true
                }
            }
        }
        return slack
    }

    private data class ColumnResult(
        val placements: List<RawPlacement>,
        val overflows: Boolean,
    )

    private data class RawPlacement(
        val id: String,
        val height: Float?,
        val rowCount: Int,
        val isVisible: Boolean,
    )

    private fun resolveColumn(slots: List<HomeSlot>, height: Float, gutter: Float): ColumnResult {
        val kept = slots.toMutableList()
        var chrome = gutter * max(0, kept.size - 1)
        var floors = kept.sumOf { it.floor.toDouble() }.toFloat()

        while (floors + chrome > height && kept.any { it.isAmbient }) {
            val victim = kept.indexOfLast { it.isAmbient }
            if (victim == -1) break
            floors -= kept[victim].floor
            kept.removeAt(victim)
            chrome = gutter * max(0, kept.size - 1)
        }

        val keptIds = kept.map { it.id }.toSet()
        val withheld = slots.filter { it.id !in keptIds }

        if (floors + chrome > height) {
            val placements = kept.map { RawPlacement(it.id, null, it.rows?.baseline ?: 0, true) } +
                withheld.map { RawPlacement(it.id, 0f, 0, false) }
            return ColumnResult(placements, overflows = true)
        }

        val rowCounts = kept.associate { it.id to (it.rows?.baseline ?: 0) }.toMutableMap()
        var slack = feedRows(kept, rowCounts, height - floors - chrome)

        val totalStretch = kept.sumOf { it.stretch }
        val totalIdeal = kept.sumOf { it.ideal.toDouble() }.toFloat()

        val placements = mutableListOf<RawPlacement>()
        for (slot in kept) {
            val bought = (rowCounts[slot.id] ?: 0) - (slot.rows?.baseline ?: 0)
            val earned = bought.toFloat() * (slot.rows?.unit ?: 0f)
            val share: Float = when {
                totalStretch > 0.0 -> (slack.toDouble() * (slot.stretch / totalStretch)).toFloat()
                totalIdeal > 0f -> slack * (slot.ideal / totalIdeal)
                kept.isNotEmpty() -> slack / kept.size.toFloat()
                else -> 0f
            }
            placements.add(
                RawPlacement(
                    id = slot.id,
                    height = slot.floor + earned + share,
                    rowCount = rowCounts[slot.id] ?: 0,
                    isVisible = true,
                ),
            )
        }

        for (slot in withheld) {
            placements.add(RawPlacement(slot.id, 0f, 0, false))
        }

        return ColumnResult(placements, overflows = false)
    }

    fun deal(slots: List<HomeSlot>, into: Int): Map<String, Int> {
        if (into <= 1) {
            return slots.associate { it.id to 0 }
        }

        val loads = FloatArray(into) { 0f }
        val assignment = mutableMapOf<String, Int>()

        for (slot in slots.sortedBy { it.rank }) {
            var target = 0
            for (column in 1 until into) {
                if (loads[column] < loads[target] - 0.5f) {
                    target = column
                }
            }
            assignment[slot.id] = target
            loads[target] += slot.ideal
        }
        return assignment
    }
}
