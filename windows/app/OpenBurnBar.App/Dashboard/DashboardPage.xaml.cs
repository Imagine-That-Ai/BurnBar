using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Dashboard.EasterEgg;
using OpenBurnBar.App.Dashboard.Layout;
using OpenBurnBar.App.Dashboard.Layouts;
using OpenBurnBar.App.Theme;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Code-behind for the Dashboard surface. Owns the WebGL2 kernel backdrop (when enabled),
/// the Win2D swarm fallback, the easter-egg overlay canvas, and the scroll-reversal
/// controller. Selecting a concept swaps the content view AND the Win2D backdrop family;
/// kernel selection is driven by <see cref="KernelBackdropPreferences"/>.
/// </summary>
public sealed partial class DashboardPage : Page
{
    private readonly DashboardBackdrop? _backdrop;
    private readonly KernelBackdropHost? _kernel;
    private readonly EasterEggCanvasHost? _egg;
    private readonly EasterEggController _controller = new();
    private readonly UISettings _uiSettings = new();
    private bool _kernelEnabled;

    public DashboardPage()
    {
        InitializeComponent();

        // Prefer WebGL2 kernel when the preference is on and WebView2 is available;
        // always keep Win2D swarm as the capable fallback (and when kernel is off).
        _kernelEnabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, defaultValue: false);

        if (_kernelEnabled && NativeCapability.IsWebView2Enabled(out _))
        {
            try
            {
                _kernel = new KernelBackdropHost();
                KernelHost.Children.Add(_kernel.Control);
                KernelHost.Visibility = Visibility.Visible;
                BackdropHost.Visibility = Visibility.Collapsed;
                string kernelId = LiquidGlassEnvironment.Current.GetString(
                    KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);
                string theme = ActualTheme == ElementTheme.Light ? "light" : "dark";
                _ = _kernel.StartAsync(kernelId, theme);
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.kernel", ex);
                _kernel = null;
                KernelHost.Visibility = Visibility.Collapsed;
            }
        }

        // Win2D swarm: always available as fallback when kernel is off or failed.
        if (_kernel is null && NativeCapability.IsWin2DEnabled(out _))
        {
            try
            {
                _backdrop = new DashboardBackdrop();
                BackdropHost.Children.Add(_backdrop.Control);
                BackdropHost.Visibility = Visibility.Visible;
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.win2d", ex);
                _backdrop = null;
            }
        }
        else if (_kernel is not null && NativeCapability.IsWin2DEnabled(out _))
        {
            // Kernel is primary; still construct Win2D so we can fail over if WebGL dies.
            try
            {
                _backdrop = new DashboardBackdrop();
                BackdropHost.Children.Add(_backdrop.Control);
                BackdropHost.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.win2d-fallback", ex);
                _backdrop = null;
            }
        }

        if (NativeCapability.IsWin2DEnabled(out _))
        {
            try
            {
                _egg = new EasterEggCanvasHost();
                EggHost.Children.Add(_egg.Control);
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.egg", ex);
            }
        }

        Switcher.LayoutChanged += OnLayoutChanged;
        _controller.EventPresented += OnEventPresented;
        if (_egg is not null)
        {
            _egg.Finished += OnEggFinished;
        }

        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;
        ActualThemeChanged += OnActualThemeChanged;

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

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        _kernel?.SetTheme(ActualTheme == ElementTheme.Light ? "light" : "dark");
    }

    private void OnGlassPreferencesChanged(object? sender, EventArgs e)
    {
        bool enabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, false);
        string kernelId = LiquidGlassEnvironment.Current.GetString(
            KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);

        if (_kernel is not null)
        {
            if (enabled)
            {
                KernelHost.Visibility = Visibility.Visible;
                BackdropHost.Visibility = Visibility.Collapsed;
                _kernel.SetKernel(kernelId);
                _kernel.SetBackdropActive(true);
            }
            else
            {
                KernelHost.Visibility = Visibility.Collapsed;
                BackdropHost.Visibility = _backdrop is not null ? Visibility.Visible : Visibility.Collapsed;
                _kernel.SetBackdropActive(false);
            }
        }
        else if (enabled && _backdrop is not null)
        {
            // Kernel host never started (WebView2 unavailable) — keep Win2D visible.
            BackdropHost.Visibility = Visibility.Visible;
        }

        _kernelEnabled = enabled;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        LiquidGlassEnvironment.PreferencesChanged -= OnGlassPreferencesChanged;
        ActualThemeChanged -= OnActualThemeChanged;
        _controller.EventPresented -= OnEventPresented;
        Switcher.LayoutChanged -= OnLayoutChanged;
        if (_egg is not null)
        {
            _egg.Finished -= OnEggFinished;
            _egg.Dispose();
        }

        _kernel?.Dispose();
        _backdrop?.Dispose();
    }
}
