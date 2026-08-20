package com.openburnbar.ui.pulse.layout

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Living layout pure space solver unit tests.
 *
 * Directly mirrors the 24 tests in macOS HomeSpaceBudgetTests.swift.
 * Pure JVM JUnit tests without Android/Robolectric framework dependencies.
 */
class HomeSpaceBudgetTest {

    private fun slot(
        id: String,
        rank: Int = 0,
        floor: Float = 100f,
        ideal: Float? = null,
        stretch: Double = 0.0,
        rows: HomeSlot.RowAppetite? = null,
        ambient: Boolean = false,
        spans: Boolean = false,
    ): HomeSlot = HomeSlot(
        id = id,
        rank = rank,
        floor = floor,
        ideal = ideal ?: floor,
        stretch = stretch,
        rows = rows,
        isAmbient = ambient,
        spans = spans,
    )

    private fun appetite(available: Int, baseline: Int = 0, unit: Float = 20f, ceiling: Int = 99): HomeSlot.RowAppetite = HomeSlot.RowAppetite(
        available = available,
        baseline = baseline,
        unit = unit,
        ceiling = ceiling,
    )

    // MARK: - Columns

    @Test
    fun test_columnThresholds() {
        assertEquals(1, HomeSpaceBudget.columns(forWidth = 900f, current = 1, slots = 4))
        assertEquals(2, HomeSpaceBudget.columns(forWidth = 1200f, current = 1, slots = 4))
        assertEquals(3, HomeSpaceBudget.columns(forWidth = 1700f, current = 2, slots = 4))
    }

    @Test
    fun test_columnDeadBandsHoldTheCurrentCount() {
        // Inside the 1<->2 band (1080 +- 60).
        assertEquals(1, HomeSpaceBudget.columns(forWidth = 1080f, current = 1, slots = 4))
        assertEquals(2, HomeSpaceBudget.columns(forWidth = 1080f, current = 2, slots = 4))
        // Inside the 2<->3 band (1580 +- 60).
        assertEquals(2, HomeSpaceBudget.columns(forWidth = 1580f, current = 2, slots = 4))
        assertEquals(3, HomeSpaceBudget.columns(forWidth = 1580f, current = 3, slots = 4))
    }

    @Test
    fun test_columnsNeverExceedSlotCount() {
        assertEquals(2, HomeSpaceBudget.columns(forWidth = 2400f, current = 3, slots = 2))
        assertEquals(1, HomeSpaceBudget.columns(forWidth = 2400f, current = 3, slots = 1))
    }

    @Test
    fun test_zeroWidthHoldsRatherThanCollapsing() {
        assertEquals(3, HomeSpaceBudget.columns(forWidth = 0f, current = 3, slots = 4))
    }

    // MARK: - Feed before Breathe

    @Test
    fun test_slackBecomesRowsBeforeItBecomesSpace() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 600f,
            slots = listOf(slot("list", floor = 100f, rows = appetite(available = 40, baseline = 2))),
            gutter = 12f,
        )

        // 500pt of slack at 20pt a row: the list should have eaten it as rows.
        assertEquals(2 + 25, plan.rowCount("list"))
        assertEquals(600f, plan.height("list") ?: 0f, 0.01f)
    }

    @Test
    fun test_rowsAreFedRoundRobinAcrossSlots() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 260f,
            slots = listOf(
                slot("greedy", rank = 0, floor = 100f, rows = appetite(available = 40, baseline = 0)),
                slot("modest", rank = 1, floor = 100f, rows = appetite(available = 40, baseline = 0)),
            ),
            gutter = 20f,
        )

        // 260 - 200 floors - 20 gutter = 40pt of slack = two rows, one each.
        assertEquals(1, plan.rowCount("greedy"))
        assertEquals(1, plan.rowCount("modest"))
    }

    @Test
    fun test_rowsNeverExceedAvailableData() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 2000f,
            slots = listOf(slot("list", floor = 100f, rows = appetite(available = 3, baseline = 0))),
            gutter = 12f,
        )

        assertEquals(3, plan.rowCount("list"))
        assertEquals(2000f, plan.height("list") ?: 0f, 0.01f)
    }

    @Test
    fun test_rowCeilingCapsAnEnormousCanvas() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 4000f,
            slots = listOf(slot("list", floor = 100f, rows = appetite(available = 500, baseline = 0, ceiling = 12))),
            gutter = 12f,
        )

        assertEquals(12, plan.rowCount("list"))
    }

    // MARK: - Overflow

    @Test
    fun test_shortCanvasOverflowsRatherThanDroppingContent() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 150f,
            slots = listOf(
                slot("a", rank = 0, floor = 100f),
                slot("b", rank = 1, floor = 100f),
                slot("c", rank = 2, floor = 100f),
            ),
            gutter = 12f,
        )

        assertTrue(plan.overflows)
        assertEquals(3, plan.placements.size)
        assertTrue(plan.placements.all { it.isVisible })
        assertTrue(plan.placements.all { it.height == null })
    }

    @Test
    fun test_ambientSlotYieldsBeforeOverflow() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 230f,
            slots = listOf(
                slot("ribbon", rank = 9, floor = 60f, ambient = true),
                slot("a", rank = 0, floor = 100f),
                slot("b", rank = 1, floor = 100f),
            ),
            gutter = 12f,
        )

        assertFalse(plan.overflows)
        assertFalse(plan.isVisible("ribbon"))
        assertTrue(plan.isVisible("a"))
        assertFalse(plan.columnGroups.flatten().contains("ribbon"))
    }

    // MARK: - No dead space

    @Test
    fun test_resolvedHeightsConsumeTheWholeCanvas() {
        val canvasHeight = 777f
        val gutter = 14f
        val slots = listOf(
            slot("head", rank = 0, floor = 90f, ideal = 120f),
            slot("list", rank = 1, floor = 80f, ideal = 300f, stretch = 1.0, rows = appetite(available = 5, baseline = 1, unit = 26f)),
            slot("tail", rank = 2, floor = 70f, ideal = 90f),
        )

        val plan = HomeSpaceBudget.resolve(canvasWidth = 900f, canvasHeight = canvasHeight, slots = slots, gutter = gutter)

        assertFalse(plan.overflows)
        val total = plan.placements.mapNotNull { it.height }.sum()
        assertEquals(canvasHeight, total + gutter * (slots.size - 1), 0.01f)
    }

    @Test
    fun test_residualIsSpreadWhenNothingStretches() {
        val canvasHeight = 500f
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = canvasHeight,
            slots = listOf(
                slot("a", rank = 0, floor = 100f, ideal = 100f),
                slot("b", rank = 1, floor = 100f, ideal = 300f),
            ),
            gutter = 0f,
        )

        val a = plan.height("a") ?: 0f
        val b = plan.height("b") ?: 0f
        assertEquals(canvasHeight, a + b, 0.01f)
        assertTrue(b > a)
    }

    @Test
    fun test_stretchTakesTheResidual() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 500f,
            slots = listOf(
                slot("rigid", rank = 0, floor = 100f, stretch = 0.0),
                slot("elastic", rank = 1, floor = 100f, stretch = 1.0),
            ),
            gutter = 0f,
        )

        assertEquals(100f, plan.height("rigid") ?: 0f, 0.01f)
        assertEquals(400f, plan.height("elastic") ?: 0f, 0.01f)
    }

    // MARK: - Column dealing

    @Test
    fun test_dealBalancesColumnsByIdealHeight() {
        val assignment = HomeSpaceBudget.deal(
            slots = listOf(
                slot("tall", rank = 0, floor = 100f, ideal = 300f),
                slot("short", rank = 1, floor = 100f, ideal = 100f),
                slot("mid", rank = 2, floor = 100f, ideal = 150f),
            ),
            into = 2,
        )

        assertEquals(0, assignment["tall"])
        assertEquals(1, assignment["short"])
        assertEquals(1, assignment["mid"])
    }

    @Test
    fun test_dealIsDeterministicOnTies() {
        val slots = (0 until 4).map { slot("s$it", rank = it, floor = 100f, ideal = 100f) }
        val first = HomeSpaceBudget.deal(slots = slots, into = 2)
        val second = HomeSpaceBudget.deal(slots = slots, into = 2)
        assertEquals(first, second)
        assertEquals(0, first["s0"])
        assertEquals(1, first["s1"])
    }

    @Test
    fun test_singleColumnPutsEverythingInColumnZero() {
        val assignment = HomeSpaceBudget.deal(slots = listOf(slot("a"), slot("b")), into = 1)
        assertEquals(mapOf("a" to 0, "b" to 0), assignment)
    }

    @Test
    fun test_columnsEachGetTheFullHeight() {
        val slots = listOf(
            slot("a", rank = 0, floor = 400f, ideal = 400f),
            slot("b", rank = 1, floor = 400f, ideal = 400f),
        )

        val stacked = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 500f,
            slots = slots,
            gutter = 12f,
            columns = 1,
        )
        assertTrue(stacked.overflows)

        val sideBySide = HomeSpaceBudget.resolve(
            canvasWidth = 1400f,
            canvasHeight = 500f,
            slots = slots,
            gutter = 12f,
            columns = 2,
        )
        assertFalse(sideBySide.overflows)
        assertEquals(500f, sideBySide.height("a") ?: 0f, 0.01f)
        assertEquals(500f, sideBySide.height("b") ?: 0f, 0.01f)
    }

    // MARK: - Ordering

    @Test
    fun test_placementsKeepTheDeclaredOrder() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 1400f,
            canvasHeight = 900f,
            slots = listOf(
                slot("first", rank = 2, floor = 100f),
                slot("second", rank = 0, floor = 100f),
                slot("third", rank = 1, floor = 100f),
            ),
            gutter = 12f,
            columns = 2,
        )

        assertEquals(listOf("first", "second", "third"), plan.placements.map { it.id })
    }

    // MARK: - Spanning band

    @Test
    fun test_spanningSlotKeepsFullWidthAboveTheColumns() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 1400f,
            canvasHeight = 800f,
            slots = listOf(
                slot("field", rank = 0, floor = 92f, ideal = 104f, spans = true),
                slot("context", rank = 1, floor = 90f, stretch = 1.0, rows = appetite(available = 20, baseline = 3, unit = 30f)),
                slot("suggestions", rank = 2, floor = 60f, rows = appetite(available = 5, baseline = 2, unit = 28f)),
            ),
            gutter = 16f,
            columns = 2,
        )

        assertEquals(listOf("field"), plan.spanningIDs)
        assertFalse(plan.columnGroups.flatten().contains("field"))
        assertEquals(2, plan.columnGroups.size)
        assertTrue(plan.columnGroups.all { it.isNotEmpty() })
    }

    @Test
    fun test_spanningBandIsRigidAndColumnsTakeTheRemainder() {
        val canvasHeight = 800f
        val gutter = 16f
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 1400f,
            canvasHeight = canvasHeight,
            slots = listOf(
                slot("field", rank = 0, floor = 92f, ideal = 104f, spans = true),
                slot("context", rank = 1, floor = 90f, stretch = 1.0, rows = appetite(available = 20, baseline = 3, unit = 30f)),
                slot("suggestions", rank = 2, floor = 60f, rows = appetite(available = 5, baseline = 2, unit = 28f)),
            ),
            gutter = gutter,
            columns = 2,
        )

        assertEquals(104f, plan.height("field") ?: 0f, 0.01f)
        val columnBudget = canvasHeight - 104f - gutter
        assertEquals(columnBudget, plan.height("context") ?: 0f, 0.01f)
        assertEquals(columnBudget, plan.height("suggestions") ?: 0f, 0.01f)
    }

    @Test
    fun test_spanningIsInertInASingleColumn() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 800f,
            slots = listOf(
                slot("field", rank = 0, floor = 92f, ideal = 104f, spans = true),
                slot("context", rank = 1, floor = 90f, stretch = 1.0),
            ),
            gutter = 16f,
            columns = 1,
        )

        assertTrue(plan.spanningIDs.isEmpty())
        assertEquals(listOf(listOf("field", "context")), plan.columnGroups)
        val total = plan.placements.mapNotNull { it.height }.sum()
        assertEquals(800f, total + 16f, 0.01f)
    }

    // MARK: - Degenerate input

    @Test
    fun test_emptySlotsResolveToTheEmptyPlan() {
        val plan = HomeSpaceBudget.resolve(canvasWidth = 900f, canvasHeight = 600f, slots = emptyList(), gutter = 12f)
        assertEquals(HomeSpacePlan.EMPTY, plan)
    }

    @Test
    fun test_zeroHeightCanvasHugsContent() {
        val plan = HomeSpaceBudget.resolve(
            canvasWidth = 900f,
            canvasHeight = 0f,
            slots = listOf(slot("a", rows = appetite(available = 9, baseline = 3))),
            gutter = 12f,
        )

        assertTrue(plan.overflows)
        assertNull(plan.height("a"))
        assertEquals(3, plan.rowCount("a"))
    }

    @Test
    fun test_appetiteClampsBaselineToAvailable() {
        val clamped = HomeSlot.RowAppetite(available = 2, baseline = 8, unit = 20f, ceiling = 10)
        assertEquals(2, clamped.baseline)
        assertEquals(2, clamped.cap)
    }
}
