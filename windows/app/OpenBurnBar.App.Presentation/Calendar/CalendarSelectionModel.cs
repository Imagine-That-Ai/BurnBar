using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Owns the day selection for the Calendar surface. Port of macOS
/// <c>AgentLens/Views/Calendar/CalendarSelectionModel.swift</c> with days carried
/// as <see cref="DateOnly"/> (local calendar days) instead of start-of-day
/// instants — identical semantics, DST-safe by construction.
///
/// Interaction semantics mirror Finder/Photos multi-select:
/// plain click selects exactly one day and moves the anchor; Shift-click replaces
/// the selection with the contiguous anchor…day range; Ctrl-click toggles a single
/// day (the Windows peer of macOS ⌘-click); drag paints a contiguous range from
/// the day the press started on.
///
/// The model is deliberately view-free: the grid reads the click's modifier flags
/// and calls the matching verb, which keeps every branch unit-testable
/// (see <c>CalendarSelectionModelTests</c>).
/// </summary>
public sealed class CalendarSelectionModel
{
    private readonly HashSet<DateOnly> _selectedDays = new();
    private DateOnly? _anchor;
    private DateOnly? _dragAnchor;

    /// <summary>Selected days in ascending order.</summary>
    public IReadOnlyList<DateOnly> OrderedDays => _selectedDays.OrderBy(day => day).ToArray();

    /// <summary>The selected set as a read-only snapshot (day lookups for bucketing).</summary>
    public IReadOnlySet<DateOnly> SelectedDays => _selectedDays;

    public int Count => _selectedDays.Count;

    public bool IsEmpty => _selectedDays.Count == 0;

    public bool IsDragging { get; private set; }

    /// <summary>Earliest…latest selected day, or <c>null</c> when empty. Spans gaps of a Ctrl selection.</summary>
    public (DateOnly First, DateOnly Last)? Span =>
        _selectedDays.Count == 0 ? null : (_selectedDays.Min(), _selectedDays.Max());

    public bool IsSelected(DateOnly day) => _selectedDays.Contains(day);

    // MARK: Click verbs

    /// <summary>Plain click: reduce the selection to just this day.</summary>
    public void Select(DateOnly day)
    {
        _selectedDays.Clear();
        _selectedDays.Add(day);
        _anchor = day;
    }

    /// <summary>Ctrl-click (macOS ⌘): toggle this day in/out of the set without disturbing the rest.</summary>
    public void Toggle(DateOnly day)
    {
        if (!_selectedDays.Remove(day))
        {
            _selectedDays.Add(day);
        }
        _anchor = day;
    }

    /// <summary>
    /// Shift-click: replace the selection with the contiguous range from the anchor
    /// to this day. With no anchor yet, behaves like a plain click.
    /// </summary>
    public void ExtendTo(DateOnly day)
    {
        if (_anchor is not { } anchor)
        {
            Select(day);
            return;
        }

        _selectedDays.Clear();
        foreach (DateOnly contiguous in ContiguousDays(anchor, day))
        {
            _selectedDays.Add(contiguous);
        }
    }

    // MARK: Drag verbs

    /// <summary>Press landed on <paramref name="day"/>: start a fresh range there.</summary>
    public void BeginDrag(DateOnly day)
    {
        _dragAnchor = day;
        _anchor = day;
        _selectedDays.Clear();
        _selectedDays.Add(day);
        IsDragging = true;
    }

    /// <summary>Drag moved onto <paramref name="day"/>: repaint the range from the drag's start. Ignored outside an active drag.</summary>
    public void UpdateDrag(DateOnly day)
    {
        if (!IsDragging || _dragAnchor is not { } dragAnchor)
        {
            return;
        }

        _selectedDays.Clear();
        foreach (DateOnly contiguous in ContiguousDays(dragAnchor, day))
        {
            _selectedDays.Add(contiguous);
        }
    }

    public void EndDrag()
    {
        IsDragging = false;
        _dragAnchor = null;
    }

    public void Clear()
    {
        _selectedDays.Clear();
        _anchor = null;
        _dragAnchor = null;
        IsDragging = false;
    }

    // MARK: Range math

    /// <summary>
    /// Every local calendar day from <paramref name="a"/> to <paramref name="b"/>
    /// inclusive, in either direction. Calendar arithmetic keeps DST 23/25-hour
    /// days aligned. The cap mirrors the macOS paranoia guard (the grid only ever
    /// shows ~42 cells) against a malformed date pair.
    /// </summary>
    public static IReadOnlySet<DateOnly> ContiguousDays(DateOnly a, DateOnly b)
    {
        DateOnly cursor = a < b ? a : b;
        DateOnly end = a < b ? b : a;
        var days = new HashSet<DateOnly> { cursor };
        while (cursor < end && days.Count < 372)
        {
            cursor = cursor.AddDays(1);
            days.Add(cursor);
        }

        return days;
    }
}
