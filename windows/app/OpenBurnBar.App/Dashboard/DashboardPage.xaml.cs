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
/// Visibility of kernel vs Win2D is resolved by <see cref="KernelBackdropSelection"/> and
/// re-applied on host Ready/Failed so missing assets or WebView2 init failure fail over.
/// </summary>
public sealed partial class DashboardPage : Page
{
    private readonly DashboardBackdrop? _backdrop;
    private readonly KernelBackdropHost? _kernel;
    private readonly EasterEggCanvasHost? _egg;
    private readonly EasterEggController _controller = new();
    private readonly UISettings _uiSettings = new();
    private readonly bool _webView2Capable;
    private bool _kernelEnabled;

    public DashboardPage()
    {
        InitializeComponent();

        // Prefer WebGL2 kernel when the preference is on and WebView2 is available;
        // always keep Win2D swarm as the capable fallback (and when kernel is off / fails).
        _kernelEnabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, defaultValue: false);
        _webView2Capable = NativeCapability.IsWebView2Enabled(out _);

        if (_kernelEnabled && _webView2Capable)
        {
            try
            {
                _kernel = new KernelBackdropHost();
                _kernel.Ready += OnKernelReady;
                _kernel.Failed += OnKernelFailed;
                KernelHost.Children.Add(_kernel.Control);
                string kernelId = LiquidGlassEnvironment.Current.GetString(
                    KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);
                string theme = ActualTheme == ElementTheme.Light ? "light" : "dark";
                _ = _kernel.StartAsync(kernelId, theme);
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("dashboard.kernel", ex);
                // Construction failed — treat as non-capable for selection.
            }
        }

        // Win2D swarm: primary when kernel is off; standby when kernel is preferred so
        // we can fail over if WebGL/WebView2 dies permanently.
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

    // The Windows "show animations" system setting is the Reduce-Motion analog.
    private bool ReduceMotion => !_uiSettings.AnimationsEnabled;

    private bool HostReady => _kernel?.IsReady == true;

    private bool HostFailed =>
        _kernel is null
            ? _kernelEnabled && _webView2Capable // wanted kernel but construction failed
            : _kernel.IsFailed;

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
        _kernelEnabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, false);
        string kernelId = LiquidGlassEnvironment.Current.GetString(
            KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId);

        if (_kernel is not null && !_kernel.IsFailed)
        {
            _kernel.SetKernel(kernelId);
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
        }

        if (_egg is not null)
        {
            _egg.Finished -= OnEggFinished;
            _egg.Dispose();
        }

        _backdrop?.Dispose();
    }
}
