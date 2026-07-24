using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the Calendar day-selection interaction contract (parity: macOS
/// <c>CalendarSelectionModelTests</c>): plain click selects, Shift extends the
/// anchor range in either direction, Ctrl toggles, drag paints a contiguous
/// range, and the anchor survives across gestures.
/// </summary>
public sealed class CalendarSelectionModelTests
{
    private static readonly DateOnly Mon = new(2026, 7, 6);
    private static readonly DateOnly Tue = new(2026, 7, 7);
    private static readonly DateOnly Wed = new(2026, 7, 8);
    private static readonly DateOnly Thu = new(2026, 7, 9);
    private static readonly DateOnly Fri = new(2026, 7, 10);

    [Fact]
    public void Plain_click_selects_exactly_one_day()
    {
        var model = new CalendarSelectionModel();
        model.Select(Wed);
        model.Select(Fri);

        Assert.Equal(new[] { Fri }, model.OrderedDays);
        Assert.True(model.IsSelected(Fri));
        Assert.False(model.IsSelected(Wed));
        Assert.Equal(1, model.Count);
    }

    [Fact]
    public void Shift_click_extends_forward_from_anchor()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.ExtendTo(Thu);

        Assert.Equal(new[] { Mon, Tue, Wed, Thu }, model.OrderedDays);
    }

    [Fact]
    public void Shift_click_extends_backward_from_anchor()
    {
        var model = new CalendarSelectionModel();
        model.Select(Fri);
        model.ExtendTo(Tue);

        Assert.Equal(new[] { Tue, Wed, Thu, Fri }, model.OrderedDays);
    }

    [Fact]
    public void Shift_click_without_anchor_behaves_like_plain_click()
    {
        var model = new CalendarSelectionModel();
        model.ExtendTo(Wed);

        Assert.Equal(new[] { Wed }, model.OrderedDays);
    }

    [Fact]
    public void Shift_click_replaces_prior_selection()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.Toggle(Wed);
        model.Toggle(Fri);

        model.ExtendTo(Tue);

        // Anchor is the last toggled day (Fri); the range Fri…Tue replaces everything.
        Assert.Equal(new[] { Tue, Wed, Thu, Fri }, model.OrderedDays);
    }

    [Fact]
    public void Ctrl_click_toggles_days_in_and_out()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.Toggle(Wed);
        model.Toggle(Fri);

        Assert.Equal(new[] { Mon, Wed, Fri }, model.OrderedDays);

        model.Toggle(Wed);
        Assert.Equal(new[] { Mon, Fri }, model.OrderedDays);
    }

    [Fact]
    public void Span_covers_gaps_of_a_ctrl_selection()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.Toggle(Fri);

        Assert.Equal((Mon, Fri), model.Span);
    }

    [Fact]
    public void Drag_paints_contiguous_range_from_press_day()
    {
        var model = new CalendarSelectionModel();
        model.BeginDrag(Tue);
        Assert.True(model.IsDragging);
        Assert.Equal(new[] { Tue }, model.OrderedDays);

        model.UpdateDrag(Thu);
        Assert.Equal(new[] { Tue, Wed, Thu }, model.OrderedDays);

        // Dragging back across the press day repaints in the other direction.
        model.UpdateDrag(Mon);
        Assert.Equal(new[] { Mon, Tue }, model.OrderedDays);

        model.EndDrag();
        Assert.False(model.IsDragging);
    }

    [Fact]
    public void UpdateDrag_outside_active_drag_is_ignored()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.UpdateDrag(Fri);
        Assert.Equal(new[] { Mon }, model.OrderedDays);
    }

    [Fact]
    public void Drag_start_replaces_selection_and_moves_anchor()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.Toggle(Wed);

        model.BeginDrag(Fri);
        model.EndDrag();

        Assert.Equal(new[] { Fri }, model.OrderedDays);

        // Anchor moved to the drag start, so a later Shift-click extends from it.
        model.ExtendTo(Mon);
        Assert.Equal(new[] { Mon, Tue, Wed, Thu, Fri }, model.OrderedDays);
    }

    [Fact]
    public void Clear_resets_everything()
    {
        var model = new CalendarSelectionModel();
        model.Select(Mon);
        model.ExtendTo(Fri);
        model.Clear();

        Assert.True(model.IsEmpty);
        Assert.Null(model.Span);

        // Anchor is gone: Shift-click behaves like a plain click again.
        model.ExtendTo(Wed);
        Assert.Equal(new[] { Wed }, model.OrderedDays);
    }

    [Fact]
    public void ContiguousDays_caps_malformed_ranges()
    {
        var days = CalendarSelectionModel.ContiguousDays(
            new DateOnly(2026, 1, 1),
            new DateOnly(2028, 1, 1));

        Assert.Equal(372, days.Count);
        Assert.Equal(new DateOnly(2026, 1, 1), days.Min());
    }
}
