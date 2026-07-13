using System;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using System.Threading.Tasks;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Storage;
using OpenBurnBar.App.Tray;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.App;

/// <summary>
/// Application entry point for the OpenBurnBar Windows shell.
///
/// Menu-bar-first parity with the macOS app: launch installs a <c>Shell_NotifyIcon</c> tray
/// item (the <see cref="TrayIcon"/>, an NSStatusItem analog) and does NOT pop a main window.
/// Left-clicking the tray toggles the resizable/reorderable Mica flyout (<see cref="FlyoutWindow"/>,
/// the NSPopover analog); the tray context menu opens the full <see cref="MainWindow"/> (the
/// NavigationView app frame) or quits. A process-global Ctrl+K opens the Command Palette.
///
/// Shared services (appearance/theme + persisted UI state) are created once here and threaded
/// into every window.
/// </summary>
public partial class App : Application
{
    private readonly GlobalHotkeyService _hotkey = new();

    private AppStatePersistence? _state;
    private ThemeService? _theme;
    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private FlyoutWindow? _flyout;
    private DispatcherQueue? _dispatcherQueue;
    private IUsageRuntime? _usageRuntime;
    private GatewayComposition? _gatewayComposition;
    private LocalHttpGatewayHost? _gateway;
    private bool _hotkeyRegistered;
    private bool _activationRegistered;
    private bool _isExiting;

    public App()
    {
        AutomationLaunchOptions.Parse(Environment.CommandLine)?.ApplyEnvironment();
        AppDiagnostics.Install(this);
        InitializeComponent();
    }

    /// <summary>The single running app instance (WinUI has no typed Application.Current).</summary>
    public static new App Current => (App)Application.Current;

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();
        var automation = AutomationLaunchOptions.Parse(args.Arguments) ?? AutomationLaunchOptions.Parse(Environment.CommandLine);
        automation?.ApplyEnvironment();
        AppDiagnostics.LogEvent("launch", args.Arguments ?? string.Empty);
        try
        {
            ReleaseConfigurationGuard.ThrowIfPlaintextCredentialEnvironmentPresent();
            _ = AppConfiguration.Current.SecurityState;
        }
        catch (SecretStoreException ex)
        {
            AppDiagnostics.LogException("configuration.security", ex);
            throw;
        }
        var storageStatus = WindowsStorageDevHost.InitializeRuntime();
        if (!storageStatus.IsReady && storageStatus.RecoveryState is { } recovery)
        {
            AppDiagnostics.LogEvent("storage.recovery-required", $"{recovery.Kind}: {recovery.Title}");
        }

        WindowsUpdateService.Configure(WindowsSettingsComposition.SharedPersistence);
        _ = WindowsUpdateService.RunAutomaticCheckIfDueAsync(WindowsSettingsComposition.SharedPersistence);
        WinAppCloudSyncHost.ConfigureFromAppConfiguration();
        Quota.Acquisition.Windows.WindowsQuotaAcquisitionHost.ConfigureDefault();
        StartLocalGateway();

        // Production Liquid Glass prefs (registry) — InMemory is reserved for unit tests.
        LiquidGlassEnvironment.Current = new LiquidGlassEnvironment(new RegistryLiquidGlassPreferenceStore());

        _state = new AppStatePersistence();
        automation?.ApplyStateSeed(_state);
        _theme = new ThemeService(_state);
        automation?.WriteLaunchMarker();

        if (storageStatus.IsReady)
        {
            _usageRuntime = CreateUsageRuntime();
            _ = StartUsageRuntimeAsync(_usageRuntime);
        }

        if ((RouteSmokeOptions.Parse(args.Arguments) ?? RouteSmokeOptions.Parse(Environment.CommandLine)) is { } smoke)
        {
            AppDiagnostics.LogEvent("route-smoke.start", $"{smoke.RouteKey} -> {smoke.OutputDirectory}");
            StartRouteSmoke(smoke);
            return;
        }

        RegisterActivationRouting();
        if (automation?.MainWindow == true)
        {
            ShowMainWindow();
            return;
        }

        // Windows are created eagerly but stay hidden — the tray owns visibility, exactly like
        // NSStatusItem owning the menu-bar popover on macOS.
        _flyout = new FlyoutWindow(State, _usageRuntime);
        _theme.Register(_flyout);

        // The flyout is the always-alive window, so anchor the global Ctrl+K hotkey there.
        _hotkeyRegistered = _hotkey.Register(_flyout, OpenCommandPalette);

        _tray = new TrayIcon(
            tooltip: "OpenBurnBar",
            onPrimaryClick: ToggleFlyout,
            onOpenMainWindow: ShowMainWindow,
            onExit: ExitApp);
        _tray.Show();

        WindowsActivationRequest initialActivation = WindowsActivationRouter.FromAppLifecycleArguments(
            AppInstance.GetCurrent().GetActivatedEventArgs().Kind.ToString(),
            AppInstance.GetCurrent().GetActivatedEventArgs().Data);
        HandleActivation(initialActivation, isInitialLaunch: true);
    }

    private void StartRouteSmoke(RouteSmokeOptions smoke)
    {
        _mainWindow = new MainWindow(_theme!);
        _mainWindow.Shell.CommandPaletteRequested += (_, _) => OpenCommandPalette();
        _mainWindow.Activate();
        _mainWindow.Shell.Navigate(smoke.RouteKey);
        _ = RouteSmokeHost.CaptureAndExitAsync(_mainWindow, smoke);
    }

    private void RegisterActivationRouting()
    {
        if (_activationRegistered)
        {
            return;
        }

        AppInstance.GetCurrent().Activated += (_, args) =>
        {
            WindowsActivationRequest request = WindowsActivationRouter.FromAppLifecycleArguments(
                args.Kind.ToString(),
                args.Data);
            (_dispatcherQueue ?? DispatcherQueue.GetForCurrentThread())
                .TryEnqueue(() => HandleActivation(request, isInitialLaunch: false));
        };
        _activationRegistered = true;
    }

    private void HandleActivation(WindowsActivationRequest request, bool isInitialLaunch)
    {
        WindowsActivationRoute? route = WindowsActivationRouter.Resolve(request);
        AppDiagnostics.LogEvent(
            "activation.route",
            $"{request.Kind} initial={isInitialLaunch} route={route?.RouteKey ?? "tray"} raw={request.Raw ?? string.Empty}");
        if (route is null)
        {
            return;
        }

        if (route.OpensMainWindow)
        {
            ShowMainWindow();
            _mainWindow?.Shell.Navigate(route.RouteKey);
        }
    }

    /// <summary>Open the full main window from the flyout's "Open full window" action.</summary>
    public void ShowMainWindowFromFlyout() => ShowMainWindow();

    /// <summary>Live shell when the main window is open (flyout deep-links).</summary>
    public AppShell? MainWindowShell => _mainWindow?.Shell;

    /// <summary>Process-owned local ingestion runtime, unavailable only during typed storage recovery.</summary>
    public IUsageRuntime? UsageRuntime => _usageRuntime;

    private void ToggleFlyout()
    {
        _flyout ??= new FlyoutWindow(State, _usageRuntime);
        _flyout.ToggleNearTray();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null)
        {
            _mainWindow = new MainWindow(_theme!);
            _mainWindow.Shell.CommandPaletteRequested += (_, _) => OpenCommandPalette();
            // Null the field when the user closes the window so a later open re-creates it.
            _mainWindow.Closed += (_, _) => _mainWindow = null;
        }

        _mainWindow.Activate();
    }

    /// <summary>Show the Command Palette over the main window (header button or Ctrl+K hotkey).</summary>
    private async void OpenCommandPalette()
    {
        try
        {
            // The palette is a ContentDialog and needs a live XamlRoot, so ensure the main window is up.
            ShowMainWindow();
            if (_mainWindow?.Content is not FrameworkElement root)
            {
                return;
            }

            var palette = new CommandPalette
            {
                XamlRoot = root.XamlRoot,
                RequestedTheme = root.RequestedTheme,
            };

            await palette.ShowAsync();

            if (palette.ChosenDestinationKey is { } key)
            {
                _mainWindow.Shell.Navigate(key);
            }
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("command-palette", ex);
        }
    }

    public void RequestExit() => ExitApp();

    private WindowsUsageRuntime CreateUsageRuntime()
    {
        var engine = new CAbiUsageEngine();
        var store = new SqlCipherUsageRuntimeSnapshotStore(() =>
        {
            var (path, passphrase) = WindowsStorageDevHost.ResolveCredentials();
            return new UsageRuntimeStorageCredentials(path!, passphrase!);
        });
        return new WindowsUsageRuntime(
            engine,
            store,
            WindowsUsagePaths.ForCurrentUser(),
            errorSink: ex => AppDiagnostics.LogException("usage-runtime", ex));
    }

    private void StartLocalGateway()
    {
        try
        {
            _gatewayComposition = GatewayCompositionFactory.CreateFromEnvironment();
            int port = 8642;
            string? configuredPort = Environment.GetEnvironmentVariable("OPENBURNBAR_GATEWAY_PORT");
            if (int.TryParse(configuredPort, out int parsedPort) && parsedPort is > 0 and <= 65535)
            {
                port = parsedPort;
            }

            _gateway = new LocalHttpGatewayHost(
                port,
                _gatewayComposition.Router,
                _gatewayComposition.Executor);
            _gateway.Start();
            AppDiagnostics.LogEvent("gateway.started", _gateway.BaseAddress.ToString());
        }
        catch (Exception ex)
        {
            // The desktop shell remains usable when another local service owns
            // the configured port; the gateway's failure is visible in diagnostics.
            AppDiagnostics.LogException("gateway.start", ex);
            _gateway = null;
            _gatewayComposition?.HttpClient.Dispose();
            _gatewayComposition = null;
        }
    }

    private static async Task StartUsageRuntimeAsync(IUsageRuntime runtime)
    {
        try
        {
            await runtime.StartAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("usage-runtime.start", ex);
        }
    }

    private async void ExitApp()
    {
        if (_isExiting)
        {
            return;
        }
        _isExiting = true;

        if (_hotkeyRegistered)
        {
            _hotkey.Dispose();
            _hotkeyRegistered = false;
        }

        _tray?.Dispose();
        _tray = null;
        if (_usageRuntime is not null)
        {
            await _usageRuntime.DisposeAsync();
            _usageRuntime = null;
        }
        if (_gateway is not null)
        {
            await _gateway.DisposeAsync();
            _gateway = null;
        }
        _gatewayComposition?.HttpClient.Dispose();
        _gatewayComposition = null;
        _flyout?.Close();
        _mainWindow?.Close();
        Exit();
    }

    private AppStatePersistence State =>
        _state ?? throw new InvalidOperationException("App state was requested before launch initialization completed.");
}
