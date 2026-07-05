using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Dashboard.EasterEgg;
using OpenBurnBar.App.Dashboard.Layout;
using OpenBurnBar.App.Dashboard.Layouts;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Code-behind for the Dashboard surface. Owns the landed-engine backdrop, the
/// easter-egg overlay canvas, and the scroll-reversal controller, and wires them to the
/// portable switcher state so selecting a concept swaps the content view AND the backdrop
/// family, while rapid scroll reversals summon the frame-stepped easter-egg physics.
/// </summary>
public sealed partial class DashboardPage : Page
{
    private readonly DashboardBackdrop? _backdrop;
    private readonly EasterEggCanvasHost? _egg;
    private readonly EasterEggController _controller = new();
    private readonly UISettings _uiSettings = new();

    public DashboardPage()
    {
        InitializeComponent();

        if (NativeCapability.IsWin2DEnabled(out _))
        {
            try
            {
                _backdrop = new DashboardBackdrop();
                _egg = new EasterEggCanvasHost();
                BackdropHost.Children.Add(_backdrop.Control);
                EggHost.Children.Add(_egg.Control);
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.win2d", ex);
                _backdrop = null;
                _egg = null;
            }
        }

        Switcher.LayoutChanged += OnLayoutChanged;
        _controller.EventPresented += OnEventPresented;
        if (_egg is not null)
        {
            _egg.Finished += OnEggFinished;
        }

        ShowLayout(Switcher.State.Selection);
        Unloaded += OnUnloaded;
    }

    private bool IsDark => ActualTheme == ElementTheme.Dark;

    // The Windows "show animations" system setting is the Reduce-Motion analog.
    private bool ReduceMotion => !_uiSettings.AnimationsEnabled;

    private void OnLayoutChanged(object? sender, DashboardLayout layout) => ShowLayout(layout);

    private void ShowLayout(DashboardLayout layout)
    {
        ContentHost.Content = CreateLayoutView(layout);
        _backdrop?.SetLayout(layout);
        ContentScroll.ChangeView(null, 0, null, true);
    }

    private static UIElement CreateLayoutView(DashboardLayout layout) => layout switch
    {
        DashboardLayout.Atelier => new AtelierLayoutView(),
        DashboardLayout.Aurora => new AuroraLayoutView(),
        DashboardLayout.Nebula => new NebulaLayoutView(),
        DashboardLayout.Constellation => new ConstellationLayoutView(),
        DashboardLayout.Cockpit => new CockpitLayoutView(),
        DashboardLayout.Classic => new ClassicLayoutView(),
        _ => new AtelierLayoutView(),
    };

    private void OnContentScrollViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        // WinUI reports VerticalOffset >= 0 growing downward; the controller expects the
        // SwiftUI convention (0 at the top, negative as the user scrolls down).
        double offset = -ContentScroll.VerticalOffset;
        _controller.RegisterScrollMetrics(
            offset: offset,
            contentHeight: ContentScroll.ExtentHeight,
            viewportHeight: ContentScroll.ViewportHeight,
            isDark: IsDark,
            reduceMotion: ReduceMotion);
    }

    private void OnEventPresented(object? sender, EasterEggEvent easterEgg) =>
        _egg?.Play(easterEgg, ReduceMotion);

    private void OnEggFinished(object? sender, Guid id) => _controller.EventDidFinish(id);

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _controller.EventPresented -= OnEventPresented;
        Switcher.LayoutChanged -= OnLayoutChanged;
        if (_egg is not null)
        {
            _egg.Finished -= OnEggFinished;
            _egg.Dispose();
        }

        _backdrop?.Dispose();
    }
}
