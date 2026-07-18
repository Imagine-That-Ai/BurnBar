using System;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Data;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Flyout;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;
using Windows.Graphics;
using Windows.UI;

namespace OpenBurnBar.App;

/// <summary>
/// Tray flyout — Windows peer of macOS <c>MenuBarPopoverView</c> (header, freshness,
/// quotas, summary/providers/insights, cloud strip, action bar).
/// </summary>
public sealed partial class FlyoutWindow : Window
{
    private const double DefaultWidth = 340;
    private const double DefaultHeight = 540;
    private const double MinWidth = 320;
    private const double MaxWidth = 560;
    private const double MinHeight = 500;
    private const double MaxHeight = 760;

    private readonly AppStatePersistence _persistence;
    private readonly AppWindow _appWindow;
    private readonly IUsageRuntime? _usageRuntime;

    private double _width;
    private double _height;
    private bool _isOpen;

    public FlyoutWindow(AppStatePersistence persistence, IUsageRuntime? usageRuntime)
    {
        _persistence = persistence;
        _usageRuntime = usageRuntime;

        InitializeComponent();

        _width = Clamp(persistence.State.FlyoutWidth, MinWidth, MaxWidth, DefaultWidth);
        _height = Clamp(persistence.State.FlyoutHeight, MinHeight, MaxHeight, DefaultHeight);

        LiquidGlass.ApplyWindowBackdrop(this, LiquidGlassEnvironment.Current);
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);
        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;

        _appWindow = WindowChrome.GetAppWindow(this);
        WindowChrome.ConfigureAsFlyout(_appWindow);
        _appWindow.Hide();

        ViewModel = new FlyoutViewModel(persistence);
        ApplySnapshot(LoadSnapshot());

        if (_usageRuntime is not null)
        {
            _usageRuntime.StateChanged += OnUsageRuntimeStateChanged;
        }

        Activated += OnActivated;
        Closed += OnClosed;
    }

    /// <summary>Legacy module order store (still used for persistence compatibility).</summary>
    public FlyoutViewModel ViewModel { get; }

    public void ToggleNearTray()
    {
        if (_isOpen)
        {
            Hide();
            return;
        }

        ApplySnapshot(LoadSnapshot());
        WindowChrome.MoveToTrayCorner(_appWindow, CurrentSize);
        _appWindow.Show();
        Activate();
        _isOpen = true;
    }

    private SizeInt32 CurrentSize => new((int)Math.Round(_width), (int)Math.Round(_height));

    private void Hide()
    {
        _appWindow.Hide();
        _isOpen = false;
    }

    private FlyoutTraySnapshot LoadSnapshot()
    {
        if (RuntimeDataMode.SampleModeEnabled)
        {
            return FlyoutTraySampleData.Snapshot();
        }

        return _usageRuntime is null
            ? FlyoutTraySnapshot.Empty with
            {
                FreshnessLabel = "Encrypted storage needs attention. Open Data & Privacy settings.",
            }
            : UsageRuntimePresentationMapper.ToFlyoutSnapshot(
                _usageRuntime.State,
                WindowsGeneralSettingsComposition.Load());
    }

    private void ApplySnapshot(FlyoutTraySnapshot snap)
    {
        ScanButton.IsEnabled = _usageRuntime is not null && _usageRuntime.State.IsScanning is false;
        FreshnessText.Text = snap.FreshnessLabel;
        FreshnessMetric.Text = snap.TodayMetricLabel;
        FreshnessSessions.Text = $"{snap.SessionCount} session{(snap.SessionCount == 1 ? string.Empty : "s")}";
        SummaryToday.Text = snap.TodayMetricLabel;
        SummaryWeek.Text = snap.WeekMetricLabel;
        SummaryMonth.Text = snap.MonthMetricLabel;
        DrawSpark(SummarySpark, snap.Sparkline);

        QuotaHost.Children.Clear();
        int q = 0;
        foreach (DashboardProviderSidebarRow row in snap.Providers)
        {
            if (q++ >= 4)
            {
                break;
            }

            QuotaHost.Children.Add(BuildQuotaRow(row));
        }

        if (QuotaHost.Children.Count == 0)
        {
            QuotaHost.Children.Add(Muted("No connected providers"));
        }

        ProviderHost.Children.Clear();
        int p = 0;
        foreach (DashboardProviderSidebarRow row in snap.Providers)
        {
            if (p++ >= 5)
            {
                break;
            }

            ProviderHost.Children.Add(BuildProviderRow(row));
        }

        if (ProviderHost.Children.Count == 0)
        {
            ProviderHost.Children.Add(Muted("No providers in this window"));
        }

        InsightHost.Children.Clear();
        foreach (FlyoutInsightCard card in snap.Insights)
        {
            InsightHost.Children.Add(BuildInsight(card));
        }

        if (InsightHost.Children.Count == 0)
        {
            InsightHost.Children.Add(Muted("No insights yet"));
        }
    }

    private static TextBlock Muted(string text) => new()
    {
        Text = text,
        FontSize = 11,
        Opacity = 0.55,
    };

    private static Border BuildQuotaRow(DashboardProviderSidebarRow row)
    {
        var bar = new Border
        {
            Height = 4,
            CornerRadius = new CornerRadius(2),
            Background = new SolidColorBrush(Color.FromArgb(0x44, 0xFA, 0x6B, 0x06)),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 80 + Math.Min(120, row.TotalCostUsd),
            Margin = new Thickness(0, 4, 0, 0),
        };
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(new TextBlock
        {
            Text = row.DisplayName,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        stack.Children.Add(new TextBlock
        {
            Text = $"{row.MetricLabel} · {row.SessionCount} sessions",
            FontSize = 11,
            Opacity = 0.6,
        });
        stack.Children.Add(bar);
        return new Border
        {
            Child = stack,
            Padding = new Thickness(0, 2, 0, 2),
        };
    }

    private static Border BuildProviderRow(DashboardProviderSidebarRow row)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        char initial = row.DisplayName.Length > 0 ? row.DisplayName[0] : '?';
        var disc = new Border
        {
            Width = 32,
            Height = 32,
            CornerRadius = new CornerRadius(16),
            Background = new SolidColorBrush(Color.FromArgb(0x33, 0xFA, 0x6B, 0x06)),
            Child = new TextBlock
            {
                Text = initial.ToString(),
                FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        Grid.SetColumn(disc, 0);

        var labels = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(new TextBlock { Text = row.DisplayName, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        labels.Children.Add(new TextBlock { Text = $"{row.SessionCount} sessions", FontSize = 11, Opacity = 0.55 });
        Grid.SetColumn(labels, 1);

        var metric = new TextBlock
        {
            Text = row.MetricLabel,
            FontSize = 12,
            FontFamily = BrandFonts.Mono,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06)),
        };
        Grid.SetColumn(metric, 2);

        grid.Children.Add(disc);
        grid.Children.Add(labels);
        grid.Children.Add(metric);

        return new Border
        {
            Child = grid,
            Padding = new Thickness(8, 6, 8, 6),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
            Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
        };
    }

    private static Border BuildInsight(FlyoutInsightCard card)
    {
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(new TextBlock
        {
            Text = card.Title,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        stack.Children.Add(new TextBlock
        {
            Text = card.Detail,
            FontSize = 11,
            Opacity = 0.65,
            TextWrapping = TextWrapping.Wrap,
        });
        return new Border
        {
            Child = stack,
            Padding = new Thickness(10, 8, 10, 8),
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x28, 0xFF, 0xFF, 0xFF)),
        };
    }

    private static void DrawSpark(Canvas canvas, System.Collections.Generic.IReadOnlyList<double> series)
    {
        canvas.Children.Clear();
        if (series.Count < 2)
        {
            return;
        }

        double w = canvas.ActualWidth > 1 ? canvas.ActualWidth : 280;
        double h = canvas.Height;
        double min = double.MaxValue, max = double.MinValue;
        foreach (double v in series)
        {
            min = Math.Min(min, v);
            max = Math.Max(max, v);
        }

        double range = Math.Max(1e-6, max - min);
        var geo = new PathGeometry();
        var fig = new PathFigure { IsClosed = false };
        for (int i = 0; i < series.Count; i++)
        {
            double x = i * (w - 2) / (series.Count - 1) + 1;
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
        canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = geo,
            Stroke = new SolidColorBrush(Color.FromArgb(0xFF, 0xFA, 0x6B, 0x06)),
            StrokeThickness = 1.5,
        });
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _isOpen)
        {
            Hide();
        }
    }

    private void OnGlassPreferencesChanged(object? sender, EventArgs e) =>
        LiquidGlassWindowBlend.ApplyScrim(WindowBlendScrim, LiquidGlassEnvironment.Current);

    private void OnClosed(object sender, WindowEventArgs args)
    {
        LiquidGlassEnvironment.PreferencesChanged -= OnGlassPreferencesChanged;
        if (_usageRuntime is not null)
        {
            _usageRuntime.StateChanged -= OnUsageRuntimeStateChanged;
        }
    }

    private void OnUsageRuntimeStateChanged(object? sender, UsageRuntimeStateChangedEventArgs args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!RuntimeDataMode.SampleModeEnabled)
            {
                ApplySnapshot(UsageRuntimePresentationMapper.ToFlyoutSnapshot(
                    args.Current,
                    WindowsGeneralSettingsComposition.Load()));
            }
        });
    }

    private void OpenFull_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        App.Current.ShowMainWindowFromFlyout();
    }

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        App.Current.ShowMainWindowFromFlyout();
        App.Current.MainWindowShell?.Navigate("settings");
    }

    private async void Scan_Click(object sender, RoutedEventArgs e)
    {
        if (_usageRuntime is null || _usageRuntime.State.IsScanning)
        {
            return;
        }

        try
        {
            await _usageRuntime.ScanAsync(UsageScanReason.Manual);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            Diagnostics.AppDiagnostics.LogException("usage-runtime.manual-scan", ex);
        }
    }

    private void Quit_Click(object sender, RoutedEventArgs e) => App.Current.RequestExit();

    private void ResizeGrip_DragDelta(object sender, DragDeltaEventArgs e)
    {
        _width = Clamp(_width + e.HorizontalChange, MinWidth, MaxWidth, _width);
        _height = Clamp(_height + e.VerticalChange, MinHeight, MaxHeight, _height);
        WindowChrome.MoveToTrayCorner(_appWindow, CurrentSize);
    }

    private void ResizeGrip_DragCompleted(object sender, DragCompletedEventArgs e)
    {
        _persistence.State.FlyoutWidth = _width;
        _persistence.State.FlyoutHeight = _height;
        _persistence.Save();
    }

    private static double Clamp(double value, double min, double max, double fallback)
    {
        if (double.IsNaN(value) || value <= 0)
        {
            return fallback;
        }

        return Math.Max(min, Math.Min(max, value));
    }
}
