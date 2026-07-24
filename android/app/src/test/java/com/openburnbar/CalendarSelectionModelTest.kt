package com.openburnbar

import com.openburnbar.ui.calendar.CalendarSelectionModel
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarSelectionModelTest {
    private val monday = LocalDate.of(2026, 7, 6)

    @Test
    fun `tap on empty selection selects the day`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        assertEquals(setOf(monday), model.selectedDays)
        assertFalse(model.isEmpty)
        assertEquals(1, model.count)
    }

    @Test
    fun `tapping more days builds a multi-selection`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.toggle(monday.plusDays(2))
        model.toggle(monday.plusDays(4))
        assertEquals(setOf(monday, monday.plusDays(2), monday.plusDays(4)), model.selectedDays)
        assertEquals(listOf(monday, monday.plusDays(2), monday.plusDays(4)), model.orderedDays)
    }

    @Test
    fun `tapping a selected day deselects it without disturbing the rest`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.toggle(monday.plusDays(1))
        model.toggle(monday)
        assertEquals(setOf(monday.plusDays(1)), model.selectedDays)
    }

    @Test
    fun `tapping the only selected day clears the selection`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.toggle(monday)
        assertTrue(model.isEmpty)
        assertNull(model.span)
    }

    @Test
    fun `select replaces the selection with exactly one day`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.toggle(monday.plusDays(1))
        model.select(monday.plusDays(3))
        assertEquals(setOf(monday.plusDays(3)), model.selectedDays)
    }

    @Test
    fun `extend replaces the selection with the contiguous anchor range`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.extend(to = monday.plusDays(3))
        assertEquals(
            setOf(monday, monday.plusDays(1), monday.plusDays(2), monday.plusDays(3)),
            model.selectedDays,
        )
    }

    @Test
    fun `extend without an anchor selects exactly the day`() {
        val model = CalendarSelectionModel()
        model.extend(to = monday)
        assertEquals(setOf(monday), model.selectedDays)
    }

    @Test
    fun `drag paints a contiguous range from the press day`() {
        val model = CalendarSelectionModel()
        model.beginDrag(on = monday)
        assertTrue(model.isDragging)
        model.updateDrag(to = monday.plusDays(2))
        model.updateDrag(to = monday.plusDays(4))
        assertEquals(
            setOf(monday, monday.plusDays(1), monday.plusDays(2), monday.plusDays(3), monday.plusDays(4)),
            model.selectedDays,
        )
        model.endDrag()
        assertFalse(model.isDragging)
    }

    @Test
    fun `drag backwards paints the same contiguous range`() {
        val model = CalendarSelectionModel()
        model.beginDrag(on = monday.plusDays(4))
        model.updateDrag(to = monday)
        assertEquals(
            setOf(monday, monday.plusDays(1), monday.plusDays(2), monday.plusDays(3), monday.plusDays(4)),
            model.selectedDays,
        )
    }

    @Test
    fun `drag replaces a prior multi-selection`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.toggle(monday.plusDays(5))
        model.beginDrag(on = monday.plusDays(1))
        model.updateDrag(to = monday.plusDays(2))
        assertEquals(setOf(monday.plusDays(1), monday.plusDays(2)), model.selectedDays)
    }

    @Test
    fun `updateDrag is ignored outside an active drag`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.updateDrag(to = monday.plusDays(3))
        assertEquals(setOf(monday), model.selectedDays)
    }

    @Test
    fun `clear empties everything and stops dragging`() {
        val model = CalendarSelectionModel()
        model.beginDrag(on = monday)
        model.updateDrag(to = monday.plusDays(2))
        model.clear()
        assertTrue(model.isEmpty)
        assertFalse(model.isDragging)
    }

    @Test
    fun `span covers the gaps of a non-contiguous selection`() {
        val model = CalendarSelectionModel()
        model.toggle(monday)
        model.toggle(monday.plusDays(6))
        assertEquals(monday..monday.plusDays(6), model.span)
    }

    @Test
    fun `contiguousDays crosses a month boundary`() {
        val jan30 = LocalDate.of(2026, 1, 30)
        val days = CalendarSelectionModel.contiguousDays(jan30, LocalDate.of(2026, 2, 2))
        assertEquals(
            setOf(
                LocalDate.of(2026, 1, 30),
                LocalDate.of(2026, 1, 31),
                LocalDate.of(2026, 2, 1),
                LocalDate.of(2026, 2, 2),
            ),
            days,
        )
    }

    @Test
    fun `contiguousDays works in either direction`() {
        val a = LocalDate.of(2026, 3, 10)
        val b = LocalDate.of(2026, 3, 6)
        assertEquals(CalendarSelectionModel.contiguousDays(b, a), CalendarSelectionModel.contiguousDays(a, b))
    }

    @Test
    fun `contiguousDays is capped as a paranoia guard`() {
        val start = LocalDate.of(2026, 1, 1)
        val days = CalendarSelectionModel.contiguousDays(start, start.plusYears(3))
        assertEquals(372, days.size)
        assertTrue(days.contains(start))
    }
}
