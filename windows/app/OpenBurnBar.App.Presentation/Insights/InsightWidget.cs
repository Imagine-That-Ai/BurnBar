using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Insights;

/// <summary>Accent theme a canvas / template renders under (port of the macOS <c>InsightTheme</c>).</summary>
public enum InsightTheme
{
    Aurora,
    Ember,
    Whimsy,
    Mercury,
}

/// <summary>
/// A single widget on a canvas — the Windows-port analog of the macOS <c>InsightWidget</c>.
/// The pair (<see cref="Kind"/>, <see cref="Data"/>) is everything a chart needs to render;
/// <see cref="Data"/> is null until the (later) Insights data engine computes it, in which
/// case the tile shows a skeleton.
/// </summary>
public sealed record InsightWidget(
    Guid Id,
    InsightWidgetKind Kind,
    string Title,
    InsightWidgetData? Data = null,
    string? Subtitle = null)
{
    /// <summary>Convenience factory that assigns a fresh id.</summary>
    public static InsightWidget Create(
        InsightWidgetKind kind,
        string title,
        InsightWidgetData? data = null,
        string? subtitle = null)
        => new(Guid.NewGuid(), kind, title, data, subtitle);

    /// <summary>Default grid span for this widget's kind.</summary>
    public (int Columns, int Rows) DefaultSpan => InsightWidgetKindInfo.DefaultSpan(Kind);
}

/// <summary>
/// A fully-instantiated, editable canvas: an ordered widget list plus the grid layout that
/// positions them. Port of the macOS <c>InsightCanvas</c> (the subset this UI-parity lane
/// renders — the sync/audit metadata arrives with the data engine lane).
/// </summary>
public sealed record InsightCanvas(
    Guid Id,
    string Title,
    string Summary,
    string Glyph,
    InsightTheme Theme,
    IReadOnlyList<InsightWidget> Widgets,
    InsightLayout Layout,
    string? OriginTemplateId = null);

/// <summary>
/// A stamp-from-the-shelf canvas blueprint — port of the macOS <c>InsightCanvasTemplate</c>.
/// <see cref="Instantiate"/> renumbers every widget and rebuilds the layout so two instances
/// of the same template never clash, exactly like the Swift <c>instantiate()</c>.
/// </summary>
public sealed record InsightCanvasTemplate(
    string Id,
    string Title,
    string Summary,
    string Glyph,
    InsightTheme Theme,
    IReadOnlyList<InsightWidget> Widgets)
{
    /// <summary>Widget count shown on the gallery card.</summary>
    public int WidgetCount => Widgets.Count;

    /// <summary>
    /// Stamp this template into a fresh canvas: re-id every widget, translate any explicit
    /// placements, then auto-place (row-major first-fit) any widget lacking one. Deterministic
    /// given the template's widget order.
    /// </summary>
    public InsightCanvas Instantiate()
    {
        var layout = new InsightLayout(columnCount: 12, rowHeight: 96, gap: 12);
        var renumbered = new List<InsightWidget>(Widgets.Count);

        foreach (InsightWidget w in Widgets)
        {
            InsightWidget copy = w with { Id = Guid.NewGuid() };
            renumbered.Add(copy);
        }

        foreach (InsightWidget widget in renumbered.Where(widget => !layout.Placements.ContainsKey(widget.Id)))
        {
            layout.PlaceNew(widget.Id, widget.DefaultSpan);
        }

        return new InsightCanvas(
            Id: Guid.NewGuid(),
            Title: Title,
            Summary: Summary,
            Glyph: Glyph,
            Theme: Theme,
            Widgets: renumbered,
            Layout: layout,
            OriginTemplateId: Id);
    }
}
