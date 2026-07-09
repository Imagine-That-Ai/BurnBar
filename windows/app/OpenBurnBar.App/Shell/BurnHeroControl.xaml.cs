using System;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Dashboard;
using Windows.UI;

namespace OpenBurnBar.App.Shell;

/// <summary>BURN telemetry capsule — Linux DeckBurnHero / macOS BurnRailTelemetryHero.</summary>
public sealed partial class BurnHeroControl : UserControl
{
    public BurnHeroControl()
    {
        InitializeComponent();
        Loaded += (_, _) => ApplySampleOrEmpty();
    }

    public void SetValue(string display, double[]? sparkline = null)
    {
        ValueText.Text = display;
        DrawSpark(sparkline ?? SampleSpark());
    }

    private void ApplySampleOrEmpty()
    {
        if (RuntimeDataMode.SampleModeEnabled)
        {
            DashboardUsageSummary summary = DashboardUsageSampleData.Summary();
            SetValue($"${summary.SpendThisMonthUsd:0.00}", SampleSpark());
            // H0 honesty: the capsule is rendering sample spend, so label it as such.
            SampleChip.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
        }
        else
        {
            SetValue("—", Array.Empty<double>());
            SampleChip.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        }
    }

    private static double[] SampleSpark() =>
        new[] { 0.22, 0.28, 0.25, 0.40, 0.55, 0.48, 0.72, 0.68, 0.85, 0.78, 0.92, 1.0 };

    private void DrawSpark(double[] series)
    {
        SparkCanvas.Children.Clear();
        if (series.Length < 2)
        {
            return;
        }

        double w = SparkCanvas.Width;
        double h = SparkCanvas.Height;
        double min = double.MaxValue, max = double.MinValue;
        foreach (double v in series)
        {
            min = Math.Min(min, v);
            max = Math.Max(max, v);
        }

        double range = Math.Max(1e-6, max - min);
        var geo = new PathGeometry();
        var fig = new PathFigure { IsClosed = false };
        for (int i = 0; i < series.Length; i++)
        {
            double x = series.Length == 1 ? 0 : i * (w - 2) / (series.Length - 1) + 1;
            double y = h - 2 - ((series[i] - min) / range) * (h - 4);
            var pt = new Windows.Foundation.Point(x, y);
            if (i == 0)
            {
                fig.StartPoint = pt;
            }
            else
            {
                fig.Segments.Add(new LineSegment { Point = pt });
            }
        }

        geo.Figures.Add(fig);
        SparkCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = geo,
            Stroke = new SolidColorBrush(Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06)),
            StrokeThickness = 1.5,
            StrokeLineJoin = PenLineJoin.Round,
        });
    }
}
