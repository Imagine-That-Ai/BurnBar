using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Presentation.MissionControl;
using Windows.Foundation;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Code-behind for the Mission Control FAB gauge. Renders a
/// <see cref="MissionGaugeConfiguration"/> using the portable
/// <see cref="MissionFabGaugeState"/> for every decision — arc color, center glyph, tick
/// colors + angles, and the burn readout — so the paint here carries no business logic.
/// </summary>
public sealed partial class MissionFabGaugeView : UserControl
{
    private MissionGaugeConfiguration _configuration = MissionGaugeConfiguration.Idle;

    public MissionFabGaugeView()
    {
        InitializeComponent();
        Loaded += (_, _) => Render();
    }

    /// <summary>The gauge state to draw. Setting it re-renders.</summary>
    public MissionGaugeConfiguration Configuration
    {
        get => _configuration;
        set
        {
            _configuration = value ?? MissionGaugeConfiguration.Idle;
            if (IsLoaded)
            {
                Render();
            }
        }
    }

    private void Render()
    {
        MissionGaugeConfiguration c = _configuration;

        double diameter = MissionGaugeSizeInfo.Diameter(c.Size);
        double thickness = MissionGaugeSizeInfo.RingThickness(c.Size);
        double tickLength = MissionGaugeSizeInfo.TickLength(c.Size);

        Root.Width = diameter;
        Root.Height = diameter;

        TrackRing.StrokeThickness = thickness;
        BurnArc.StrokeThickness = thickness;

        var arcBrush = new SolidColorBrush(MissionPalette.ForRole(MissionFabGaugeState.PrimaryArcColor(c)));
        BurnArc.Stroke = arcBrush;
        BurnArc.Data = BuildArcGeometry(diameter, thickness, c.BurnSweep);

        RenderTicks(c, diameter, thickness, tickLength);

        CenterGlyph.Glyph = MissionFabGaugeState.GlyphName(c);
        CenterGlyph.FontSize = MissionGaugeSizeInfo.GlyphSize(c.Size);
        CenterGlyph.Foreground = arcBrush;
        AutomationProperties.SetName(this, MissionFabGaugeState.AccessibilityLabel(c));

        if (c.Size == MissionGaugeSize.Hero)
        {
            BurnReadout.Text = MissionFabGaugeState.BurnReadout(c);
            BurnReadout.Visibility = Visibility.Visible;
        }
        else
        {
            BurnReadout.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>Builds a circular arc from the top (12 o'clock) sweeping clockwise for
    /// <paramref name="sweep"/> (0..1) of the perimeter — the WinUI analog of SwiftUI's
    /// <c>Circle().trim(from:0,to:sweep).rotationEffect(-90)</c>.</summary>
    private static Geometry? BuildArcGeometry(double diameter, double thickness, double sweep)
    {
        if (sweep <= 0)
        {
            return null;
        }

        double radius = (diameter / 2.0) - (thickness / 2.0);
        double centerX = diameter / 2.0;
        double centerY = diameter / 2.0;

        // Clamp just under a full turn — an ArcSegment cannot express a 360° sweep.
        double sweepDegrees = Math.Min(sweep, 0.9999) * 360.0;

        var start = new Point(centerX, centerY - radius); // top
        double endAngleRad = (-90.0 + sweepDegrees) * Math.PI / 180.0;
        var end = new Point(
            centerX + (radius * Math.Cos(endAngleRad)),
            centerY + (radius * Math.Sin(endAngleRad)));

        var figure = new PathFigure { StartPoint = start, IsClosed = false };
        figure.Segments.Add(new ArcSegment
        {
            Point = end,
            Size = new Size(radius, radius),
            RotationAngle = 0,
            IsLargeArc = sweepDegrees > 180.0,
            SweepDirection = SweepDirection.Clockwise,
        });

        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>Draws one capsule tick per in-flight mission, evenly distributed around the
    /// perimeter, colored by <see cref="MissionFabGaugeState.TickColor"/>.</summary>
    private void RenderTicks(MissionGaugeConfiguration c, double diameter, double thickness, double tickLength)
    {
        TicksLayer.Children.Clear();
        TicksLayer.Width = diameter;
        TicksLayer.Height = diameter;

        if (!MissionFabGaugeState.TicksVisible(c))
        {
            return;
        }

        double centerX = diameter / 2.0;
        double centerY = diameter / 2.0;
        double radius = (diameter / 2.0) - thickness - 1.0;
        var angles = MissionFabGaugeState.TickAngles(c);

        for (int i = 0; i < angles.Count; i++)
        {
            var tick = new Rectangle
            {
                Width = 2,
                Height = tickLength,
                RadiusX = 1,
                RadiusY = 1,
                Fill = new SolidColorBrush(MissionPalette.ForRole(MissionFabGaugeState.TickColor(c, i))),
            };

            // Position the tick's center at the top of the dial, then rotate about the hub.
            double left = centerX - 1.0;
            double top = centerY - radius - (tickLength / 2.0);
            Canvas.SetLeft(tick, left);
            Canvas.SetTop(tick, top);
            tick.RenderTransformOrigin = new Point(0.5, 0.5);
            tick.RenderTransform = new RotateTransform
            {
                Angle = angles[i],
                CenterX = 1.0,
                CenterY = radius + (tickLength / 2.0),
            };

            TicksLayer.Children.Add(tick);
        }
    }
}
