using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using System.Threading.Tasks;
using OpenBurnBar.App.Shell;
using OpenBurnBar.App.Theme;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Storage;
using OpenBurnBar.App.Tray;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Projects;
using OpenBurnBar.App.Projects;
using OpenBurnBar.ComputerUse.Core.Gate;

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
    private readonly ComputerUseSafetyMonitor _computerUseSafetyMonitor = new();
    private readonly SemaphoreSlim _localRuntimeRestartGate = new(1, 1);
    private readonly SemaphoreSlim _projectCodeMemoryGate = new(1, 1);

    private AppStatePersistence? _state;
    private ThemeService? _theme;
    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private FlyoutWindow? _flyout;
    private DispatcherQueue? _dispatcherQueue;
    private IUsageRuntime? _usageRuntime;
    private GatewayComposition? _gatewayComposition;
    private LocalHttpGatewayHost? _gateway;
    private string? _localAccessToken;
    private ElderWandFusionOrchestrator? _fusion;
    private ProjectCodeMemoryService? _projectCodeMemory;
    private bool _hotkeyRegistered;
    private bool _computerUseSafetyMonitorReady;
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

    internal IReadOnlyList<ElderWandProviderGroup> ElderWandProviderGroups() =>
        _gatewayComposition is null
            ? Array.Empty<ElderWandProviderGroup>()
            : ElderWandGatewayCatalogProjection.Groups(_gatewayComposition.Router.Routes);

    internal nint MainWindowHandle => _mainWindow is null
        ? nint.Zero
        : WindowChrome.GetHandle(_mainWindow);

    internal ProjectCodeMemoryService? ProjectCodeMemory =>
        Volatile.Read(ref _projectCodeMemory);

    internal async Task<ProjectCodeMemoryService?> ReconfigureProjectCodeMemoryAsync()
    {
        ProjectCodeMemoryService? replacement = null;
        try
        {
            replacement = CreateProjectCodeMemoryService();
            if (replacement is not null)
            {
                replacement.TryLoad();
                await replacement.RefreshAsync().ConfigureAwait(false);
                replacement.StartWatching();
            }
        }
        catch (Exception ex)
        {
            try
            {
                replacement?.Dispose();
            }
            catch (Exception disposeError)
            {
                AppDiagnostics.LogException("project-code-memory.dispose-replacement", disposeError);
            }
            AppDiagnostics.LogException("project-code-memory.reconfigure", ex);
            throw new InvalidOperationException("The selected code folder could not be indexed.", ex);
        }

        await _projectCodeMemoryGate.WaitAsync();
        try
        {
            ProjectCodeMemoryService? previous = Volatile.Read(ref _projectCodeMemory);
            Volatile.Write(ref _projectCodeMemory, replacement);
            try
            {
                previous?.Dispose();
            }
            catch (Exception ex)
            {
                AppDiagnostics.LogException("project-code-memory.dispose-previous", ex);
            }
        }
        finally
        {
            _projectCodeMemoryGate.Release();
        }

        return replacement;
    }

    internal async Task RestartLocalGatewayAsync()
    {
        await _localRuntimeRestartGate.WaitAsync();
        try
        {
            await StopLocalRuntimeAsync();
            StartLocalGateway();
            StartCompanionCli();

            GatewayEndpointSettings settings = WindowsSettingsComposition.LoadGatewayEndpointSettings();
            GatewayListenerOptions listenerOptions = ResolveGatewayListenerOptions(settings);
            if (_gatewayComposition is null)
            {
                throw new InvalidOperationException("The local model runtime could not be composed.");
            }

            if (listenerOptions.Enabled && _gateway is null)
            {
                throw new InvalidOperationException(
                    $"The model proxy could not listen on {listenerOptions.BaseAddress}.");
            }

            if (_companionCli is null)
            {
                throw new InvalidOperationException("The companion CLI could not restart.");
            }
        }
        finally
        {
            _localRuntimeRestartGate.Release();
        }
    }

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
        WindowsAppCheckComposition.RegisterIfConfigured();
        WinAppCloudSyncHost.ConfigureFromAppConfiguration();
        StartWindowsRuntimeSafetyConfig();
        StartComputerUseWatchdog();
        StartPrivilegedInputBroker();
        StartPensieveKnowledgeWatcher();
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
            StartCompanionCli();
            AppDiagnostics.LogEvent("route-smoke.start", $"{smoke.RouteKey} -> {smoke.OutputDirectory}");
            StartRouteSmoke(smoke);
            return;
        }

        RegisterActivationRouting();
        if (automation?.MainWindow == true)
        {
            StartCompanionCli();
            ShowMainWindow();
            return;
        }

        // Windows are created eagerly but stay hidden — the tray owns visibility, exactly like
        // NSStatusItem owning the menu-bar popover on macOS.
        _flyout = new FlyoutWindow(State, _usageRuntime);
        _theme.Register(_flyout);

        // The flyout is the always-alive window, so anchor the global Ctrl+K hotkey there.
        _hotkeyRegistered = _hotkey.Register(_flyout, OpenCommandPalette);
        _computerUseSafetyMonitorReady = _computerUseSafetyMonitor.Register(
            _flyout,
            OnComputerUsePanic);
        if (!_computerUseSafetyMonitorReady)
        {
            AppDiagnostics.LogEvent("computer-use.safety-monitor-unavailable", "registration failed");
            OnComputerUsePanic(ComputerUsePanicSource.Revoked);
        }
        StartCompanionCli();

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
        // The route-smoke harness captures XAML routes — pin the native shell for it.
        _mainWindow = new MainWindow(_theme!, _usageRuntime, _gateway, _localAccessToken, forceXamlShell: true);
        _mainWindow.Shell!.CommandPaletteRequested += (_, _) => OpenCommandPalette();
        _mainWindow.Activate();
        if (smoke.WindowWidth is not null || smoke.WindowHeight is not null)
        {
            var appWindow = WindowChrome.GetAppWindow(_mainWindow);
            var current = appWindow.Size;
            appWindow.Resize(new Windows.Graphics.SizeInt32(
                smoke.WindowWidth ?? current.Width,
                smoke.WindowHeight ?? current.Height));
        }
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
            _mainWindow?.Navigate(route.RouteKey, route.Payload);
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
            _mainWindow = new MainWindow(_theme!, _usageRuntime, _gateway, _localAccessToken);
            if (_mainWindow.Shell is { } shell)
            {
                shell.CommandPaletteRequested += (_, _) => OpenCommandPalette();
            }
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
                _mainWindow.Navigate(key, palette.ChosenSessionId);
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
        GeneralSettingsSnapshot generalSettings = WindowsGeneralSettingsComposition.Load();
        var engine = new OutOfProcessUsageEngine();
        var store = new SqlCipherUsageRuntimeSnapshotStore(() =>
        {
            var (path, passphrase) = WindowsStorageDevHost.ResolveCredentials();
            return new UsageRuntimeStorageCredentials(path!, passphrase!);
        });
        return new WindowsUsageRuntime(
            engine,
            store,
            WindowsUsagePaths.ForCurrentUser(
                includeConversationBodies: generalSettings.IndexingEnabled),
            periodicInterval: TimeSpan.FromSeconds(generalSettings.RefreshIntervalSeconds),
            errorSink: ex => AppDiagnostics.LogException("usage-runtime", ex));
    }

    private void StartLocalGateway()
    {
        try
        {
            _gatewayComposition = WindowsSettingsComposition.CreateGatewayComposition();
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("gateway.composition", ex);
            _gatewayComposition = null;
            return;
        }

        try
        {
            EnsureFusionRuntime();
            GatewayEndpointSettings settings = WindowsSettingsComposition.LoadGatewayEndpointSettings();
            GatewayListenerOptions listenerOptions = ResolveGatewayListenerOptions(settings);
            string? accessToken = ResolveGatewayAccessToken(listenerOptions, settings);
            _localAccessToken = accessToken;

            if (!listenerOptions.Enabled)
            {
                AppDiagnostics.LogEvent("gateway.disabled", listenerOptions.BaseAddress.ToString());
                return;
            }

            _gateway = new LocalHttpGatewayHost(
                listenerOptions.Host, listenerOptions.Port, _gatewayComposition.Router,
                _gatewayComposition.Executor, accessToken, discovery: _gatewayComposition.Discovery,
                fusionHandler: HandleGatewayFusionAsync);
            _gateway.Start();
            AppDiagnostics.LogEvent("gateway.started", _gateway.BaseAddress.ToString());
        }
        catch (Exception ex)
        {
            // The desktop shell remains usable when another local service owns
            // the configured port; the gateway's failure is visible in diagnostics.
            AppDiagnostics.LogException("gateway.start", ex);
            _gateway = null;
        }
    }

    private static string? ResolveGatewayAccessToken(
        GatewayListenerOptions listenerOptions,
        GatewayEndpointSettings settings)
    {
        const string allowUnauthenticatedEnvironmentVariable = "OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK";
        string tokenName = AppSecretNames.ProviderSecret("settings", "model-proxy", "auth-token");
        var persistence = WindowsSettingsComposition.SharedPersistence;
        bool allowUnauthenticated = listenerOptions.AllowsUnauthenticatedAccess(
            settings.AllowUnauthenticatedLoopback,
            Environment.GetEnvironmentVariable(allowUnauthenticatedEnvironmentVariable));
        string configuredToken = settings.AuthToken;
        string? resolved = GatewayAuthTokenPolicy.Resolve(configuredToken, allowUnauthenticated);
        if (string.IsNullOrWhiteSpace(configuredToken)
            && !string.IsNullOrWhiteSpace(resolved))
        {
            persistence.WriteSecret(tokenName, resolved);
        }

        return resolved;
    }

    private static GatewayListenerOptions ResolveGatewayListenerOptions(GatewayEndpointSettings settings) =>
        GatewayListenerOptions.Resolve(
            configuredEnabled: settings.Enabled,
            configuredHost: settings.Host,
            configuredPort: settings.Port,
            enabledOverride: Environment.GetEnvironmentVariable("OPENBURNBAR_GATEWAY_ENABLED"),
            hostOverride: Environment.GetEnvironmentVariable("OPENBURNBAR_GATEWAY_HOST"),
            portOverride: Environment.GetEnvironmentVariable("OPENBURNBAR_GATEWAY_PORT"));

    private static ProjectCodeMemoryService? CreateProjectCodeMemoryService()
    {
        GeneralSettingsSnapshot generalSettings = WindowsGeneralSettingsComposition.Load();
        if (!generalSettings.IndexingEnabled)
        {
            AppDiagnostics.LogEvent("project-code-memory", "disabled_by_general_settings");
            return null;
        }

        ProjectCodeRootSettingsViewModel rootSettings =
            WindowsSettingsComposition.CreateProjectCodeRootSettingsViewModel();
        string? projectRoot = rootSettings.IsAvailable ? rootSettings.RootPath : null;
        if (projectRoot is null && !rootSettings.IsConfigured)
        {
            string? legacyRoot = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_ROOT");
            if (!string.IsNullOrWhiteSpace(legacyRoot))
            {
                try
                {
                    var legacySettings = new ProjectCodeRootSettingsViewModel();
                    legacySettings.SelectRoot(legacyRoot);
                    projectRoot = legacySettings.RootPath;
                    AppDiagnostics.LogEvent("project-code-memory.root", "legacy_environment_override");
                }
                catch (ArgumentException ex)
                {
                    AppDiagnostics.LogException("project-code-memory.root", ex);
                }
            }
        }

        if (projectRoot is null)
        {
            AppDiagnostics.LogEvent(
                "project-code-memory",
                rootSettings.IsConfigured ? "selected_root_unavailable" : "root_not_selected");
            return null;
        }

        string? parserPath = Environment.GetEnvironmentVariable("OPENBURNBAR_CODE_STATIC_PARSER_PATH");
        if (string.IsNullOrWhiteSpace(parserPath))
        {
            string packagedPath = Path.Combine(
                AppContext.BaseDirectory,
                "ProjectCode",
                "project-code-static-parser.exe");
            parserPath = File.Exists(packagedPath) ? packagedPath : null;
        }

        IProjectCodeStaticParserClient? treeSitterParser = !string.IsNullOrWhiteSpace(parserPath)
            && File.Exists(parserPath)
            ? new JsonLinesProjectCodeStaticParserClient(parserPath)
            : null;
        IProjectCodeStaticParserClient? lspParser = CreateLanguageServerParser();
        IProjectCodeStaticParserClient? parser = lspParser is not null && treeSitterParser is not null
            ? new FallbackProjectCodeStaticParserClient(lspParser, treeSitterParser)
            : lspParser ?? treeSitterParser;
        string indexPath = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_INDEX_PATH")
            ?? WindowsProjectCodePaths.IndexPathForRoot(projectRoot);
        ProjectCodeMemoryStore? store = null;
        try
        {
            string storePath = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_MEMORY_PATH")
                ?? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "OpenBurnBar",
                    "project-code-memory.sqlite");
            (_, string? passphrase) = WindowsStorageDevHost.ResolveCredentials();
            store = new ProjectCodeMemoryStore(
                storePath,
                encryptionPassphrase: passphrase,
                embeddingProvider: ProjectCodeEmbeddingProviderComposition.TryCreate());
        }
        catch (Exception ex)
        {
            // The JSON index remains a bounded, source-free fallback when a
            // local SQLite provider is unavailable; surface the degradation in
            // diagnostics instead of making companion startup fail closed.
            AppDiagnostics.LogException("project-code-memory.store", ex);
        }

        var index = new ProjectCodeSymbolIndex(projectRoot, indexPath, parser: parser, store: store);
        return new ProjectCodeMemoryService(index, parser);
    }

    private static IProjectCodeStaticParserClient? CreateLanguageServerParser()
    {
        string? raw = Environment.GetEnvironmentVariable("OPENBURNBAR_CODE_LSP_COMMANDS");
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        try
        {
            Dictionary<string, string[]>? commands = JsonSerializer.Deserialize<Dictionary<string, string[]>>(raw);
            if (commands is null || commands.Count == 0)
            {
                return null;
            }

            var normalized = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
            foreach ((string language, string[]? command) in commands)
            {
                if (command is { Length: > 0 })
                {
                    normalized[language] = command;
                }
            }

            return normalized.Count == 0
                ? null
                : new LanguageServerProjectCodeParserClient(normalized);
        }
        catch (JsonException ex)
        {
            AppDiagnostics.LogException("project-code.lsp-config", ex);
            return null;
        }
        catch (ArgumentException ex)
        {
            AppDiagnostics.LogException("project-code.lsp-config", ex);
            return null;
        }
    }

    private static async Task RefreshProjectCodeMemoryAsync(ProjectCodeMemoryService service)
    {
        try
        {
            await service.RefreshAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("project-code-memory.refresh", ex);
        }
    }

    private async Task<object?> HandleProjectCodeAsync(JsonElement request, CancellationToken cancellationToken)
    {
        await _projectCodeMemoryGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ProjectCodeMemoryService? service = Volatile.Read(ref _projectCodeMemory);
            if (service is null)
            {
                throw new InvalidOperationException("project_code_unavailable");
            }

            string op = request.TryGetProperty("op", out JsonElement opElement)
                ? opElement.GetString() ?? string.Empty
                : string.Empty;
            switch (op)
            {
                case "code.index":
                    return ToProjectCodeStatus(await service.RefreshAsync(cancellationToken).ConfigureAwait(false), service);
                case "code.search":
                    return new
                    {
                        query = RequiredString(request, "query"),
                        hits = service.Search(
                            RequiredString(request, "query"),
                            OptionalBoundedInt(request, "limit", 50, 1, 100)),
                    };
                case "code.symbol":
                    return new
                    {
                        name = RequiredString(request, "name"),
                        symbols = service.FindSymbol(
                            RequiredString(request, "name"),
                            OptionalBoundedInt(request, "limit", 50, 1, 100)),
                    };
                case "code.references":
                    return await service.FindReferencesAsync(
                        RequiredString(request, "filePath"),
                        OptionalBoundedInt(request, "line", 1, 1, 1_000_000),
                        OptionalBoundedInt(request, "character", 0, 0, 1_000_000),
                        cancellationToken).ConfigureAwait(false);
                case "code.call_graph":
                    return service.ReadCallGraph(
                        RequiredString(request, "name"),
                        OptionalBoundedInt(request, "limit", 200, 1, 200),
                        OptionalBoundedInt(request, "depth", 1, 1, 3));
                case "code.semantic_search":
                    return service.ReadSemanticSearch(
                        RequiredString(request, "query"),
                        OptionalBoundedInt(request, "limit", 20, 1, 100));
                case "code.context_pack":
                    return service.BuildContextPack(
                        RequiredString(request, "query"),
                        OptionalBoundedInt(request, "limit", 10, 1, ProjectCodeMemoryService.MaxContextPackHits),
                        OptionalBoundedInt(request, "maxBytes", 24_000, 1, ProjectCodeMemoryService.MaxContextPackBytes));
                case "code.status":
                    return ToProjectCodeStatus(service.Snapshot, service);
                default:
                    throw new ArgumentException("Unknown project-code operation.", nameof(request));
            }
        }
        finally
        {
            _projectCodeMemoryGate.Release();
        }
    }

    private static object ToProjectCodeStatus(
        ProjectCodeIndexSnapshot? snapshot,
        ProjectCodeMemoryService service) => new
        {
            root = service.Root,
            watching = service.IsWatching,
            durableStore = service.HasDurableStore,
            loaded = snapshot is not null,
            refreshedAt = snapshot?.RefreshedAt,
            parserMode = snapshot?.ParserMode ?? "none",
            symbolCount = snapshot?.Symbols.Count ?? service.Symbols.Count,
            truncated = snapshot?.Truncated ?? false,
            store = service.DurableStoreStats,
        };

    private static string RequiredString(JsonElement request, string property)
    {
        if (!request.TryGetProperty(property, out JsonElement element)
            || element.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(element.GetString()))
        {
            throw new ArgumentException($"{property} is required.", nameof(request));
        }

        return element.GetString()!;
    }

    private static int OptionalBoundedInt(JsonElement request, string property, int fallback, int minimum, int maximum)
    {
        if (!request.TryGetProperty(property, out JsonElement element))
        {
            return fallback;
        }

        if (!element.TryGetInt32(out int value) || value < minimum || value > maximum)
        {
            throw new ArgumentException($"{property} must be between {minimum} and {maximum}.", nameof(request));
        }

        return value;
    }

}
