// WINDOWS-ONLY / CI-DEFERRED (Win2D + WinUI). See InsightChartPainters.cs header.

using System;
using Microsoft.Graphics.Canvas.UI.Xaml;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using WinColor = Windows.UI.Color;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// A Win2D <see cref="CanvasControl"/> host that draws one Insights chart. It is the Windows
/// analog of a single SwiftUI chart renderer view (e.g. <c>InsightRankingView</c>): assign
/// <see cref="Data"/> + a theme, and the control redraws by handing its bounds to the
/// parity-tested geometry engines and forwarding the result to
/// <see cref="InsightChartPainters"/>.
/// </summary>
/// <remarks>
/// A retained-mode <c>CanvasControl</c> (not the vsync-driven animated control the particle
/// substrate uses) — charts are static and only invalidate on data/size change. Windows-only:
/// the render is GPU-bound and CI-deferred; the geometry it consumes is macOS-tested.
/// </remarks>
public sealed class InsightChartCanvas : IDisposable
{
    private const double Padding = 12;

    private InsightWidgetData? _data;
    private InsightTheme _theme = InsightTheme.Aurora;

    public InsightChartCanvas()
    {
        Control = new CanvasControl
        {
            ClearColor = WinColor.FromArgb(0, 0, 0, 0),
        };
        Control.Draw += OnDraw;
    }

    /// <summary>The XAML element to place in the visual tree.</summary>
    public CanvasControl Control { get; }

    /// <summary>Assign the chart's data + theme and request a redraw.</summary>
    public void SetContent(InsightWidgetData? data, InsightTheme theme)
    {
        _data = data;
        _theme = theme;
        Control.Invalidate();
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        if (_data is null)
        {
            return;
        }

        double width = Math.Max(0, sender.Size.Width - (2 * Padding));
        double height = Math.Max(0, sender.Size.Height - (2 * Padding));
        if (width <= 0 || height <= 0)
        {
            return;
        }

        var rect = new PlotRect(Padding, Padding, width, height);
        InsightChartPainters.Paint(args.DrawingSession, sender, _data, rect, _theme);
    }

    public void Dispose()
    {
        Control.Draw -= OnDraw;
        Control.RemoveFromVisualTree();
    }
}
