package com.openburnbar.ui.calendar

import java.time.LocalDate

// MARK: - Calendar Selection Model
//
// Owns the day selection for the Calendar surface. Days are plain
// [LocalDate]s, so a selection never depends on the time-of-day or timezone
// the gesture carried — bucketing follows the device's local zone upstream in
// `CalendarStore`.
//
// Touch interaction semantics (mirrors the macOS `CalendarSelectionModel`,
// adapted from modifier-key clicks to touch gestures):
// - tap toggles a single day in/out of the set (multi-selection),
// - long-press then drag paints a contiguous range from the day the press
//   started on, replacing the current selection.
//
// The model is deliberately view-free (no Compose): the grid maps pixel
// offsets to dates and calls the matching verb, which keeps every branch
// unit-testable (see `CalendarSelectionModelTest`).
class CalendarSelectionModel {

    /** Selected days, in no particular order (read [orderedDays] for sorted). */
    var selectedDays: Set<LocalDate> = emptySet()
        private set

    /** The day gestures extend from (tap or drag start). */
    private var anchor: LocalDate? = null

    /** Anchor captured when the current drag began; cleared on drag end. */
    private var dragAnchor: LocalDate? = null

    var isDragging: Boolean = false
        private set

    // MARK: Derived state

    /** Selected days in ascending order. */
    val orderedDays: List<LocalDate>
        get() = selectedDays.sorted()

    val count: Int
        get() = selectedDays.size

    val isEmpty: Boolean
        get() = selectedDays.isEmpty()

    /** Earliest…latest selected day, or null when empty. Spans a
     *  non-contiguous multi-selection across its gaps. */
    val span: ClosedRange<LocalDate>?
        get() {
            val first = selectedDays.minOrNull() ?: return null
            val last = selectedDays.maxOrNull() ?: return null
            return first..last
        }

    fun isSelected(day: LocalDate): Boolean = selectedDays.contains(day)

    // MARK: Tap verbs

    /** Tap: toggle this day in/out of the set without disturbing the rest. */
    fun toggle(day: LocalDate) {
        selectedDays =
            if (selectedDays.contains(day)) {
                selectedDays - day
            } else {
                selectedDays + day
            }
        anchor = day
    }

    /** Replace the selection with exactly this day (e.g. the "Today" button). */
    fun select(day: LocalDate) {
        selectedDays = setOf(day)
        anchor = day
    }

    /** Replace the selection with the contiguous range from the anchor to
     *  this day. With no anchor yet, behaves like [select]. */
    fun extend(to: LocalDate) {
        val anchor = anchor
        if (anchor == null) {
            select(to)
            return
        }
        selectedDays = contiguousDays(anchor, to)
    }

    // MARK: Drag verbs

    /** Long-press landed on [day]: start a fresh range there. */
    fun beginDrag(on: LocalDate) {
        dragAnchor = on
        anchor = on
        selectedDays = setOf(on)
        isDragging = true
    }

    /** Drag moved onto [day]: repaint the contiguous range from the drag's
     *  starting day. Ignored outside an active drag. */
    fun updateDrag(to: LocalDate) {
        val dragAnchor = dragAnchor
        if (!isDragging || dragAnchor == null) return
        selectedDays = contiguousDays(dragAnchor, to)
    }

    fun endDrag() {
        isDragging = false
        dragAnchor = null
    }

    fun clear() {
        selectedDays = emptySet()
        anchor = null
        dragAnchor = null
        isDragging = false
    }

    companion object {
        /** Paranoia guard against a malformed date pair — the grid only ever
         *  shows ~42 cells, so this is never a real limit. Mirrors the macOS
         *  `CalendarSelectionModel` cap. */
        private const val MAX_RANGE_DAYS = 372

        /** Every calendar day from [a] to [b] inclusive, in either direction.
         *  `LocalDate` arithmetic keeps DST 23/25-hour days aligned. */
        fun contiguousDays(a: LocalDate, b: LocalDate): Set<LocalDate> {
            val start = minOf(a, b)
            val end = maxOf(a, b)
            val days = LinkedHashSet<LocalDate>()
            var cursor = start
            while (!cursor.isAfter(end) && days.size < MAX_RANGE_DAYS) {
                days.add(cursor)
                cursor = cursor.plusDays(1)
            }
            return days
        }
    }
}
