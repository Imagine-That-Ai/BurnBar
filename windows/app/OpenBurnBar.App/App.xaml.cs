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
using OpenBurnBar.App.Settings.Winui;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.Storage;
using OpenBurnBar.App.Tray;
using OpenBurnBar.App.UsageRuntime;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Projects;

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
    private readonly SemaphoreSlim _localRuntimeRestartGate = new(1, 1);

    private AppStatePersistence? _state;
    private ThemeService? _theme;
    private TrayIcon? _tray;
    private MainWindow? _mainWindow;
    private FlyoutWindow? _flyout;
    private DispatcherQueue? _dispatcherQueue;
    private IUsageRuntime? _usageRuntime;
    private GatewayComposition? _gatewayComposition;
    private LocalHttpGatewayHost? _gateway;
    private CompanionCliServer? _companionCli;
    private string? _localAccessToken;
    private HeadlessRunService? _headlessRuns;
    private ElderWandFusionOrchestrator? _fusion;
    private ProjectCodeMemoryService? _projectCodeMemory;
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

    internal IReadOnlyList<ElderWandProviderGroup> ElderWandProviderGroups() =>
        _gatewayComposition is null
            ? Array.Empty<ElderWandProviderGroup>()
            : ElderWandGatewayCatalogProjection.Groups(_gatewayComposition.Router.Routes);

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
        Quota.Acquisition.Windows.WindowsQuotaAcquisitionHost.ConfigureDefault();
        StartLocalGateway();
        StartCompanionCli();

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
        _mainWindow = new MainWindow(_theme!, _usageRuntime);
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
            _mainWindow = new MainWindow(_theme!, _usageRuntime);
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
                _mainWindow.Shell.Navigate(key, palette.ChosenSessionId);
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
        var engine = new CAbiUsageEngine();
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
            _gatewayComposition = GatewayCompositionFactory.CreateFromEnvironment();
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("gateway.composition", ex);
            _gatewayComposition = null;
            return;
        }

        try
        {
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
                listenerOptions.Host,
                listenerOptions.Port,
                _gatewayComposition.Router,
                _gatewayComposition.Executor,
                accessToken);
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
        const string tokenEnvironmentVariable = "OPENBURNBAR_GATEWAY_AUTH_TOKEN";
        const string allowUnauthenticatedEnvironmentVariable = "OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK";
        string tokenName = AppSecretNames.ProviderSecret("settings", "model-proxy", "auth-token");
        string? environmentToken = Environment.GetEnvironmentVariable(tokenEnvironmentVariable);
        var persistence = WindowsSettingsComposition.SharedPersistence;
        bool allowUnauthenticated = listenerOptions.AllowsUnauthenticatedAccess(
            settings.AllowUnauthenticatedLoopback,
            Environment.GetEnvironmentVariable(allowUnauthenticatedEnvironmentVariable));
        string configuredToken = environmentToken ?? settings.AuthToken;
        string? resolved = GatewayAuthTokenPolicy.Resolve(configuredToken, allowUnauthenticated);
        if (environmentToken is null
            && string.IsNullOrWhiteSpace(configuredToken)
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

    private void StartCompanionCli()
    {
        try
        {
            int port = 8765;
            string? configuredPort = Environment.GetEnvironmentVariable("OPENBURNBAR_COMPANION_CLI_PORT");
            if (int.TryParse(configuredPort, out int parsedPort) && parsedPort is > 0 and <= 65535)
            {
                port = parsedPort;
            }

            string journalPath = Environment.GetEnvironmentVariable("OPENBURNBAR_RUN_JOURNAL_PATH")
                ?? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "OpenBurnBar",
                    "headless-runs.jsonl");
            var headlessRuns = new HeadlessRunService(new JsonLinesHeadlessRunJournal(journalPath));
            _headlessRuns = headlessRuns;
            if (_localAccessToken is null)
            {
                GatewayEndpointSettings settings = WindowsSettingsComposition.LoadGatewayEndpointSettings();
                _localAccessToken = ResolveGatewayAccessToken(
                    new GatewayListenerOptions(true, "127.0.0.1", port),
                    settings);
            }
            var runHandler = new CompanionCliHeadlessRunHandler(
                headlessRuns,
                BuiltInHeadlessRunSteps.ExecuteAsync);
            _ = ReportRecoverableHeadlessRunsAsync(headlessRuns);
            string fusionJournalPath = Environment.GetEnvironmentVariable("OPENBURNBAR_FUSION_JOURNAL_PATH")
                ?? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "OpenBurnBar",
                    "elder-wand-runs.jsonl");
            _fusion = new ElderWandFusionOrchestrator(
                ExecuteFusionToolAsync,
                new JsonLinesFusionRunJournal(fusionJournalPath));
            _projectCodeMemory = CreateProjectCodeMemoryService();
            if (_projectCodeMemory is not null)
            {
                _projectCodeMemory.TryLoad();
                _projectCodeMemory.StartWatching();
                _ = RefreshProjectCodeMemoryAsync(_projectCodeMemory);
            }
            var router = new CompanionCliCommandRouter(
                _gatewayComposition?.Router,
                runHandler.SubmitAsync,
                runHandler.ResumeAsync,
                HandleFusionRunAsync,
                HandleProjectCodeAsync,
                runHandler.RecoverAsync);
            _companionCli = new CompanionCliServer(port, router, _localAccessToken);
            _companionCli.Start();
            AppDiagnostics.LogEvent("companion-cli.started", $"127.0.0.1:{port}");
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("companion-cli.start", ex);
            _companionCli = null;
            _headlessRuns = null;
            _fusion = null;
            _projectCodeMemory?.Dispose();
            _projectCodeMemory = null;
        }
    }

    private static ProjectCodeMemoryService? CreateProjectCodeMemoryService()
    {
        GeneralSettingsSnapshot generalSettings = WindowsGeneralSettingsComposition.Load();
        if (!generalSettings.IndexingEnabled)
        {
            AppDiagnostics.LogEvent("project-code-memory", "disabled_by_general_settings");
            return null;
        }

        string? projectRoot = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_ROOT");
        if (string.IsNullOrWhiteSpace(projectRoot) || !Directory.Exists(projectRoot))
        {
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
        string? indexPath = Environment.GetEnvironmentVariable("OPENBURNBAR_PROJECT_INDEX_PATH");
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

    private static async Task ReportRecoverableHeadlessRunsAsync(HeadlessRunService service)
    {
        try
        {
            IReadOnlyList<RecoverableHeadlessRun> runs = await service
                .RecoverAsync()
                .ConfigureAwait(false);
            if (runs.Count > 0)
            {
                AppDiagnostics.LogEvent("headless-runs.recoverable", runs.Count.ToString());
            }
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("headless-runs.recovery", ex);
        }
    }

    private async Task<object?> HandleProjectCodeAsync(JsonElement request, CancellationToken cancellationToken)
    {
        ProjectCodeMemoryService? service = _projectCodeMemory;
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

    private async Task<object?> HandleFusionRunAsync(JsonElement request, CancellationToken cancellationToken)
    {
        if (_fusion is null)
        {
            throw new InvalidOperationException("fusion_unavailable");
        }

        if (!request.TryGetProperty("seedPrompt", out JsonElement promptElement)
            || promptElement.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(promptElement.GetString()))
        {
            throw new ArgumentException("seedPrompt is required.", nameof(request));
        }

        string seedPrompt = promptElement.GetString()!;
        if (seedPrompt.Length > 64 * 1024)
        {
            throw new ArgumentException("seedPrompt exceeds the safety limit.", nameof(request));
        }

        int maxSteps = 8;
        if (request.TryGetProperty("maxSteps", out JsonElement maxStepsElement)
            && (!maxStepsElement.TryGetInt32(out maxSteps) || maxSteps is < 1 or > 16))
        {
            throw new ArgumentException("maxSteps must be between 1 and 16.", nameof(request));
        }

        string? runId = request.TryGetProperty("runId", out JsonElement runIdElement)
            && runIdElement.ValueKind == JsonValueKind.String
            ? runIdElement.GetString()
            : null;
        runId = string.IsNullOrWhiteSpace(runId)
            ? "fusion-" + Guid.NewGuid().ToString("N")
            : runId.Trim();
        FusionRunResult result = await _fusion
            .RunAsync(new FusionRunRequest(seedPrompt, maxSteps, runId), cancellationToken)
            .ConfigureAwait(false);
        return new
        {
            runId,
            succeeded = result.Succeeded,
            steps = result.Steps.Count,
            error = result.Error,
        };
    }

    private async Task<FusionToolResult> ExecuteFusionToolAsync(
        FusionToolCall call,
        CancellationToken cancellationToken)
    {
        GatewayComposition? composition = _gatewayComposition;
        if (composition is null)
        {
            return FusionToolResult.Fail("gateway_unavailable");
        }

        string? configuredModel = Environment.GetEnvironmentVariable("OPENBURNBAR_FUSION_MODEL");
        ModelRouteDecision decision = string.IsNullOrWhiteSpace(configuredModel)
            ? composition.Router.Select()
            : composition.Router.SelectForModel(configuredModel, allowDegrade: true);
        if (decision.FailedClosed || decision.Route.Endpoint is null)
        {
            composition.Router.RecordOutcome(decision.Route, succeeded: false, decision.Degraded);
            return FusionToolResult.Fail("fusion_route_unavailable");
        }

        byte[] body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            model = decision.Route.Model,
            messages = new[]
            {
                new { role = "system", content = "You are the OpenBurnBar Elder Wand fusion judge. Return JSON with terminal (boolean) and output (string) when you can finish; otherwise return concise analysis text." },
                new { role = "user", content = call.Payload },
            },
            temperature = 0.2,
            max_tokens = 2048,
        });
        ModelCompletionResult response = await composition.Executor
            .ExecuteAsync(decision.Route, body, cancellationToken)
            .ConfigureAwait(false);
        composition.Router.RecordOutcome(decision.Route, response.Succeeded, decision.Degraded);
        if (!response.Succeeded)
        {
            return FusionToolResult.Fail($"fusion_provider_http_{response.StatusCode}");
        }

        string output = ExtractFusionOutput(response.Body);
        if (string.IsNullOrWhiteSpace(output))
        {
            return FusionToolResult.Fail("fusion_provider_empty_output");
        }

        if (TryReadTerminalEnvelope(output, out bool terminal, out string envelopeOutput))
        {
            return new FusionToolResult(true, terminal, envelopeOutput, null);
        }

        return FusionToolResult.Continue(output);
    }

    private static string ExtractFusionOutput(byte[] body)
    {
        if (body.Length == 0)
        {
            return string.Empty;
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("choices", out JsonElement choices)
                && choices.ValueKind == JsonValueKind.Array
                && choices.GetArrayLength() > 0)
            {
                JsonElement first = choices[0];
                if (first.TryGetProperty("message", out JsonElement message)
                    && message.TryGetProperty("content", out JsonElement content)
                    && content.ValueKind == JsonValueKind.String)
                {
                    return content.GetString() ?? string.Empty;
                }

                if (first.TryGetProperty("text", out JsonElement text)
                    && text.ValueKind == JsonValueKind.String)
                {
                    return text.GetString() ?? string.Empty;
                }
            }
        }
        catch (JsonException)
        {
            // Some OpenAI-compatible local engines return plain text. Preserve
            // that output while still applying the hard byte cap below.
        }

        string raw = Encoding.UTF8.GetString(body);
        return raw.Length <= 256 * 1024 ? raw : raw[..(256 * 1024)];
    }

    private static bool TryReadTerminalEnvelope(string output, out bool terminal, out string envelopeOutput)
    {
        terminal = false;
        envelopeOutput = output;
        try
        {
            using JsonDocument document = JsonDocument.Parse(output);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("terminal", out JsonElement terminalElement))
            {
                return false;
            }

            if (terminalElement.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
            {
                return false;
            }

            if (!root.TryGetProperty("output", out JsonElement outputElement)
                || outputElement.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            terminal = terminalElement.GetBoolean();
            envelopeOutput = outputElement.GetString() ?? string.Empty;
            return true;
        }
        catch (JsonException)
        {
            return false;
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
        await StopLocalRuntimeAsync();
        _flyout?.Close();
        _mainWindow?.Close();
        Exit();
    }

    private async Task StopLocalRuntimeAsync()
    {
        if (_gateway is not null)
        {
            await _gateway.DisposeAsync();
            _gateway = null;
        }
        if (_companionCli is not null)
        {
            await _companionCli.DisposeAsync();
            _companionCli = null;
        }
        _headlessRuns = null;
        _fusion = null;
        _projectCodeMemory?.Dispose();
        _projectCodeMemory = null;
        _gatewayComposition?.HttpClient.Dispose();
        _gatewayComposition = null;
        _localAccessToken = null;
    }

    private AppStatePersistence State =>
        _state ?? throw new InvalidOperationException("App state was requested before launch initialization completed.");
}
