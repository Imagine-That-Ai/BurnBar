using System;
using System.Globalization;
using System.Linq;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Data;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.UsageRuntime;
using Windows.UI;

namespace OpenBurnBar.App.Shell;

/// <summary>BURN telemetry capsule — Linux DeckBurnHero / macOS BurnRailTelemetryHero.</summary>
public sealed partial class BurnHeroControl : UserControl
{
    private IUsageRuntime? _runtime;
    private bool _isLoaded;

    public BurnHeroControl()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public void Bind(IUsageRuntime? runtime)
    {
        if (ReferenceEquals(_runtime, runtime))
        {
            return;
        }

        if (_isLoaded && _runtime is not null)
        {
            _runtime.StateChanged -= OnRuntimeStateChanged;
        }
        _runtime = runtime;
        if (_isLoaded && _runtime is not null)
        {
            _runtime.StateChanged += OnRuntimeStateChanged;
        }
        ApplyCurrent();
    }

    public void SetValue(string display, double[]? sparkline = null)
    {
        ValueText.Text = display;
        DrawSpark(sparkline ?? SampleSpark());
    }

    private void OnLoaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _isLoaded = true;
        if (_runtime is not null)
        {
            _runtime.StateChanged += OnRuntimeStateChanged;
        }
        ApplyCurrent();
    }

    private void OnUnloaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (_runtime is not null)
        {
            _runtime.StateChanged -= OnRuntimeStateChanged;
        }
        _isLoaded = false;
    }

    private void OnRuntimeStateChanged(object? sender, UsageRuntimeStateChangedEventArgs args)
    {
        if (!args.Current.IsScanning)
        {
            DispatcherQueue.TryEnqueue(ApplyCurrent);
        }
    }

    private void ApplyCurrent()
    {
        GeneralSettingsSnapshot settings = WindowsGeneralSettingsComposition.Load();
        if (RuntimeDataMode.SampleModeEnabled)
        {
            DashboardUsageSummary summary = DashboardUsageSampleData.Summary();
            string display = settings.UsageDisplayMode == GeneralUsageDisplayMode.Tokens
                ? FormatTokens(summary.TotalTokens)
                : summary.TotalCostUsd.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
            SetValue(display, SampleSpark());
            // H0 honesty: the capsule is rendering sample spend, so label it as such.
            SampleChip.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
        }
        else if (_runtime is not null && _runtime.State.Snapshot.Usages.Count > 0)
        {
            DashboardCommandSnapshot command = UsageRuntimePresentationMapper.ToDashboardCommandSnapshot(
                _runtime.State,
                settings);
            var flyout = UsageRuntimePresentationMapper.ToFlyoutSnapshot(_runtime.State, settings);
            SetValue(command.OverviewMetricLabel, flyout.Sparkline.ToArray());
            SampleChip.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        }
        else
        {
            SetValue("—", Array.Empty<double>());
            SampleChip.Visibility = Microsoft.UI.Xaml.Visibility.Collapsed;
        }
    }

    private static double[] SampleSpark() =>
        new[] { 0.22, 0.28, 0.25, 0.40, 0.55, 0.48, 0.72, 0.68, 0.85, 0.78, 0.92, 1.0 };

    private static string FormatTokens(long tokens)
    {
        if (tokens >= 1_000_000_000) return $"{tokens / 1_000_000_000.0:0.##}B";
        if (tokens >= 1_000_000) return $"{tokens / 1_000_000.0:0.##}M";
        if (tokens >= 1_000) return $"{tokens / 1_000.0:0.#}K";
        return tokens.ToString(CultureInfo.InvariantCulture);
    }

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
