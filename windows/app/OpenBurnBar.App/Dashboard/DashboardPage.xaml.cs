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
/// controller. Kernel host is constructed lazily when the preference is enabled at runtime.
/// Visibility is resolved by <see cref="KernelBackdropSelection"/>; Win2D stays visible until kernel Ready.
/// </summary>
public sealed partial class DashboardPage : Page
{
    private readonly DashboardBackdrop? _backdrop;
    private KernelBackdropHost? _kernel;
    private readonly EasterEggCanvasHost? _egg;
    private readonly EasterEggController _controller = new();
    private readonly UISettings _uiSettings = new();
    private readonly bool _webView2Capable;
    private bool _kernelEnabled;
    /// <summary>True only after an attempted kernel construction failed (not "never tried").</summary>
    private bool _kernelConstructionFailed;

    public DashboardPage()
    {
        InitializeComponent();

        _kernelEnabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, defaultValue: false);
        _webView2Capable = NativeCapability.IsWebView2Enabled(out _);

        if (_kernelEnabled)
        {
            EnsureKernelHostStarted();
        }

        if (NativeCapability.IsWin2DEnabled(out _))
        {
            try
            {
                _backdrop = new DashboardBackdrop();
                BackdropHost.Children.Add(_backdrop.Control);
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.win2d", ex);
            }
        }

        ApplyBackdropLayers();

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
    private bool ReduceMotion => !_uiSettings.AnimationsEnabled;
    private bool HostReady => _kernel?.IsReady == true;
    private bool HostFailed =>
        _kernel is not null
            ? _kernel.IsFailed
            : _kernelConstructionFailed;

    private void EnsureKernelHostStarted()
    {
        if (!_webView2Capable || _kernel is not null || _kernelConstructionFailed)
        {
            return;
        }

        try
        {
            var host = new KernelBackdropHost();
            host.Ready += OnKernelReady;
            host.Failed += OnKernelFailed;
            KernelHost.Children.Add(host.Control);
            _kernel = host;
            string kernelId = LiquidGlassEnvironment.Current.GetString(
                KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);
            string theme = ActualTheme == ElementTheme.Light ? "light" : "dark";
            _ = host.StartAsync(kernelId, theme);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("dashboard.kernel", ex);
            _kernelConstructionFailed = true;
            _kernel = null;
        }
    }

    private void ApplyBackdropLayers()
    {
        DashboardBackdropLayer layer = KernelBackdropSelection.Resolve(
            kernelEnabled: _kernelEnabled,
            webView2Capable: _webView2Capable && _kernel is not null,
            hostReady: HostReady,
            hostFailed: HostFailed,
            win2DAvailable: _backdrop is not null);

        KernelHost.Visibility = layer == DashboardBackdropLayer.Kernel
            ? Visibility.Visible
            : Visibility.Collapsed;
        BackdropHost.Visibility = layer == DashboardBackdropLayer.Win2D
            ? Visibility.Visible
            : Visibility.Collapsed;

        if (layer == DashboardBackdropLayer.Kernel)
        {
            _kernel?.SetBackdropActive(true);
        }
        else
        {
            _kernel?.SetBackdropActive(false);
        }
    }

    private void OnKernelReady(object? sender, EventArgs e) => ApplyBackdropLayers();

    private void OnKernelFailed(object? sender, string reason)
    {
        AppDiagnostics.LogEvent("dashboard.kernel-failover", reason);
        ApplyBackdropLayers();
    }

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
        _kernelEnabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, false);
        string kernelId = LiquidGlassEnvironment.Current.GetString(
            KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);

        if (_kernelEnabled)
        {
            EnsureKernelHostStarted();
            if (_kernel is not null && !_kernel.IsFailed)
            {
                _kernel.SetKernel(kernelId);
            }
        }

        ApplyBackdropLayers();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        LiquidGlassEnvironment.PreferencesChanged -= OnGlassPreferencesChanged;
        ActualThemeChanged -= OnActualThemeChanged;
        _controller.EventPresented -= OnEventPresented;
        Switcher.LayoutChanged -= OnLayoutChanged;
        if (_kernel is not null)
        {
            _kernel.Ready -= OnKernelReady;
            _kernel.Failed -= OnKernelFailed;
            _kernel.Dispose();
            _kernel = null;
        }

        if (_egg is not null)
        {
            _egg.Finished -= OnEggFinished;
            _egg.Dispose();
        }

        _backdrop?.Dispose();
    }
}
