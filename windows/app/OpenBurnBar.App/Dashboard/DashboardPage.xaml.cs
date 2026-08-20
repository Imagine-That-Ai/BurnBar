using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Data;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Dashboard.EasterEgg;
using OpenBurnBar.App.Dashboard.Layout;
using OpenBurnBar.App.Dashboard.Layouts;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.UsageRuntime;
using Windows.UI.ViewManagement;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Dashboard surface — macOS <c>DashboardView</c> parity:
/// NavigationSplitView with Command sidebar (<c>DashboardSidebarView</c>) + concept detail.
/// Owns native kernel/substrate layers, the layout switcher, and easter-egg overlay.
/// </summary>
public sealed partial class DashboardPage : Page
{
    private readonly DashboardBackdrop? _backdrop;
    private KernelBackdropHost? _kernel;
    private readonly EasterEggCanvasHost? _egg;
    private readonly EasterEggController _controller = new();
    private readonly UISettings _uiSettings = new();
    private readonly bool _nativeKernelCapable;
    private bool _kernelEnabled;
    /// <summary>True only after an attempted kernel construction failed (not "never tried").</summary>
    private bool _kernelConstructionFailed;
    private DashboardCommandSnapshot _commandSnapshot = DashboardCommandSnapshot.Empty;
    private DashboardCommandSelection _commandSelection = DashboardCommandSelection.Overview();
    private bool _compactDashboard;
    private const double CompactDashboardBreakpoint = 900;

    public DashboardPage()
    {
        InitializeComponent();

        _nativeKernelCapable = NativeCapability.IsWin2DEnabled(out _);
        // Sample/dev guest builds should show the living native kernel field without a
        // Settings dig — product default stays off when no preference is set
        // outside sample mode (macOS @AppStorage default false).
        if (RuntimeDataMode.SampleModeEnabled
            && !LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, false))
        {
            // Prefer GetBool with sentinel: if user never toggled, enable for sample.
            LiquidGlassEnvironment.Current.SetBool(KernelBackdropPreferences.EnabledKey, true);
        }

        _kernelEnabled = LiquidGlassEnvironment.Current.GetBool(KernelBackdropPreferences.EnabledKey, defaultValue: false);

        if (_kernelEnabled)
        {
            EnsureKernelHostStarted();
        }

        if (NativeCapability.IsWin2DEnabled(out _))
        {
            try
            {
                _backdrop = new DashboardBackdrop();
                _backdrop.SetTheme(ActualTheme == ElementTheme.Light ? "light" : "dark");
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
        CommandSidebar.SelectionChanged += OnCommandSelectionChanged;
        CommandSidebar.ViewModeChanged += OnCommandViewModeChanged;
        _controller.EventPresented += OnEventPresented;
        if (_egg is not null)
        {
            _egg.Finished += OnEggFinished;
        }

        LiquidGlassEnvironment.PreferencesChanged += OnGlassPreferencesChanged;
        ActualThemeChanged += OnActualThemeChanged;

        LoadCommandSnapshot();
        ShowLayout(Switcher.State.Selection);
        if (App.Current.UsageRuntime is { } usageRuntime)
        {
            usageRuntime.StateChanged += OnUsageRuntimeStateChanged;
        }
        Unloaded += OnUnloaded;
    }

    private void LoadCommandSnapshot()
    {
        _commandSnapshot = RuntimeDataMode.SampleModeEnabled
            ? DashboardCommandSampleData.Snapshot()
            : App.Current.UsageRuntime is { } usageRuntime
                ? UsageRuntimePresentationMapper.ToDashboardCommandSnapshot(
                    usageRuntime.State,
                    WindowsGeneralSettingsComposition.Load())
                : DashboardCommandSnapshot.Empty;
        CommandSidebar.ApplySnapshot(_commandSnapshot);
        ApplyDetailChrome();
    }

    private void OnUsageRuntimeStateChanged(object? sender, UsageRuntimeStateChangedEventArgs args)
    {
        if (args.Current.IsScanning || RuntimeDataMode.SampleModeEnabled)
        {
            return;
        }

        DispatcherQueue.TryEnqueue(() =>
        {
            _commandSnapshot = UsageRuntimePresentationMapper.ToDashboardCommandSnapshot(
                args.Current,
                WindowsGeneralSettingsComposition.Load());
            CommandSidebar.ApplySnapshot(_commandSnapshot);
            ApplyDetailChrome();
            DashboardUsageProvider.NotifyChanged();
            ShowLayout(Switcher.State.Selection);
        });
    }

    private void OnCommandSelectionChanged(object? sender, DashboardCommandSelection selection)
    {
        _commandSelection = selection;
        ApplyDetailChrome();
        if (_compactDashboard)
        {
            CompactCommandFlyout.Hide();
        }
    }

    private void OnCommandViewModeChanged(object? sender, DashboardCommandViewMode mode)
    {
        _commandSelection = DashboardCommandSelection.Overview();
        ApplyDetailChrome();
    }

    private void ApplyDetailChrome()
    {
        if (_commandSelection.IsOverview)
        {
            DetailTitle.Text = "Overview";
            DetailSubtitle.Text = _commandSnapshot.Origin == DashboardUsageOrigin.Sample
                ? "Sample · all providers"
                : "All providers + models";
        }
        else
        {
            DetailTitle.Text = _commandSelection.Title;
            DetailSubtitle.Text = _commandSelection.Kind == "provider"
                ? "Provider deep dive"
                : "Model deep dive";
        }
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
        if (!_nativeKernelCapable || _kernel is not null || _kernelConstructionFailed)
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
        bool capable = _nativeKernelCapable && _kernel is not null;
        bool showKernel = KernelBackdropSelection.ShouldShowKernel(
            _kernelEnabled, capable, HostReady, HostFailed, _backdrop is not null);
        // Prefer Win2D whenever the kernel is not ready/active so layout switches
        // always have a live animated field to drive.
        bool showWin2D = KernelBackdropSelection.ShouldShowWin2D(
            _kernelEnabled, capable, HostReady, HostFailed, _backdrop is not null)
            || (!showKernel && _backdrop is not null);

        KernelHost.Visibility = showKernel ? Visibility.Visible : Visibility.Collapsed;
        BackdropHost.Visibility = showWin2D ? Visibility.Visible : Visibility.Collapsed;

        if (_backdrop is not null)
        {
            _backdrop.Paused = !showWin2D;
            _backdrop.Control.Visibility = showWin2D ? Visibility.Visible : Visibility.Collapsed;
        }

        _kernel?.SetBackdropActive(showKernel);
    }

    private void OnKernelReady(object? sender, EventArgs e) => ApplyBackdropLayers();

    private void OnKernelFailed(object? sender, string reason)
    {
        AppDiagnostics.LogEvent("dashboard.kernel-failover", reason);
        ApplyBackdropLayers();
    }

    private void OnLayoutChanged(object? sender, DashboardLayout layout) => ShowLayout(layout);

    private void OnDashboardSizeChanged(object sender, SizeChangedEventArgs e)
    {
        bool compact = e.NewSize.Width < CompactDashboardBreakpoint;
        MoveCommandSidebar(compact, e.NewSize.Height);
        SidebarColumn.MinWidth = compact ? 0 : 260;
        SidebarColumn.MaxWidth = compact ? 0 : 320;
        SidebarColumn.Width = compact ? new GridLength(0) : new GridLength(Math.Min(320, Math.Max(260, e.NewSize.Width * 0.22)));
        SidebarDividerColumn.Width = compact ? new GridLength(0) : new GridLength(1);
        SidebarDivider.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        CompactCommandButton.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        DetailSubtitle.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        DetailHost.Padding = compact ? new Thickness(10, 8, 10, 0) : new Thickness(16, 12, 16, 0);

        double detailWidth = compact ? e.NewSize.Width : Math.Max(0, e.NewSize.Width - SidebarColumn.Width.Value);
        Switcher.Width = compact ? 190 : double.NaN;
        Switcher.MaxWidth = compact ? 190 : double.PositiveInfinity;
        Switcher.UpdateAvailableWidth(detailWidth - 220);

        UpdateContentHostSizing();
    }

    private void OnContentScrollSizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateContentHostSizing();
    }

    private void UpdateContentHostSizing()
    {
        if (ContentScroll.ActualHeight > 0)
        {
            ContentHost.MinHeight = ContentScroll.ActualHeight;
        }
        if (ContentScroll.ActualWidth > 0)
        {
            ContentHost.MinWidth = ContentScroll.ActualWidth;
        }
    }

    private void MoveCommandSidebar(bool compact, double availableHeight)
    {
        if (compact)
        {
            if (!_compactDashboard)
            {
                DesktopCommandHost.Content = null;
                CompactCommandFlyout.Content = CommandSidebar;
                _compactDashboard = true;
            }

            CommandSidebar.Width = Math.Min(340, Math.Max(280, DetailHost.ActualWidth - 32));
            CommandSidebar.MaxHeight = Math.Max(320, Math.Min(640, availableHeight - 96));
            return;
        }

        if (_compactDashboard)
        {
            CompactCommandFlyout.Hide();
            CompactCommandFlyout.Content = null;
            DesktopCommandHost.Content = CommandSidebar;
            _compactDashboard = false;
        }

        CommandSidebar.Width = double.NaN;
        CommandSidebar.MaxHeight = double.PositiveInfinity;
    }

    private void ShowLayout(DashboardLayout layout)
    {
        ContentHost.Content = CreateLayoutView(layout);

        // Win2D swarm family follows the concept layout (macOS ConstellationBackground parity).
        _backdrop?.SetLayout(layout);
        if (_backdrop is not null)
        {
            // Ensure the animated control is running after visibility toggles.
            _backdrop.Paused = false;
        }

        // When the native kernel field is active, also switch its kernel so the
        // background actually changes with the layout switcher (FamilyFor map).
        if (_kernelEnabled && _kernel is not null && !_kernel.IsFailed)
        {
            string layoutKernel = KernelForLayout(layout);
            _kernel.SetKernel(layoutKernel);
            // Keep settings picker in sync without a no-op storm when already equal.
            if (!string.Equals(
                    LiquidGlassEnvironment.Current.GetString(KernelBackdropPreferences.KernelKey, KernelCatalog.DefaultId),
                    layoutKernel,
                    StringComparison.Ordinal))
            {
                LiquidGlassEnvironment.Current.SetString(KernelBackdropPreferences.KernelKey, layoutKernel);
            }
        }

        ApplyBackdropLayers();
        ContentScroll.ChangeView(null, 0, null, true);
    }

    /// <summary>
    /// Map each dashboard concept to a signature kernel id — mirrors
    /// <c>DashboardBackdrop.FamilyFor</c> (Volumetric / Constellation / Mesh / Aurora / Flow).
    /// </summary>
    internal static string KernelForLayout(DashboardLayout layout) => layout switch
    {
        DashboardLayout.Atelier => "volumetric",
        DashboardLayout.Constellation => "constellation",
        DashboardLayout.Nebula => "mesh",
        DashboardLayout.Aurora => "aurora",
        DashboardLayout.Cockpit => "flow",
        DashboardLayout.Classic => "constellation",
        DashboardLayout.Stream => "flow",
        DashboardLayout.Atlas => "mesh",
        _ => KernelCatalog.DefaultId,
    };

    private static UIElement CreateLayoutView(DashboardLayout layout) => layout switch
    {
        DashboardLayout.Atelier => new AtelierLayoutView(),
        DashboardLayout.Aurora => new AuroraLayoutView(),
        DashboardLayout.Nebula => new NebulaLayoutView(),
        DashboardLayout.Constellation => new ConstellationLayoutView(),
        DashboardLayout.Cockpit => new CockpitLayoutView(),
        DashboardLayout.Classic => new ClassicLayoutView(),
        DashboardLayout.Stream => new StreamLayoutView(),
        DashboardLayout.Atlas => new AtlasLayoutView(),
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
        string theme = ActualTheme == ElementTheme.Light ? "light" : "dark";
        _kernel?.SetTheme(theme);
        _backdrop?.SetTheme(theme);
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
        CommandSidebar.SelectionChanged -= OnCommandSelectionChanged;
        CommandSidebar.ViewModeChanged -= OnCommandViewModeChanged;
        if (App.Current.UsageRuntime is { } usageRuntime)
        {
            usageRuntime.StateChanged -= OnUsageRuntimeStateChanged;
        }
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
