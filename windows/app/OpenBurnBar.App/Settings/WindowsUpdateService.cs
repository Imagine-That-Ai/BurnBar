using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.Updater.Core.Feed;
using OpenBurnBar.Updater.Core.Host;
using OpenBurnBar.Updater.Core.Verification;
using OpenBurnBar.Updater.Core.Versioning;
using OpenBurnBar.Updater.Windows;
using Windows.ApplicationModel;

namespace OpenBurnBar.App.Settings.Winui;

internal sealed record WindowsUpdateStatus(
    string Version,
    string Channel,
    string AppcastUrl,
    string ReleaseNotesUrl,
    bool AutomaticChecksEnabled,
    bool HostConfigured,
    bool NativeHostAvailable,
    bool ProductionPinInjected,
    bool AutomaticChecksAvailable,
    bool CheckActionAvailable,
    bool ManagedByStore,
    string Message);

internal sealed record WindowsStartupStatus(
    bool IsEnabled,
    bool CanChange,
    string Message);

internal static class WindowsUpdateService
{
    private const string AutomaticChecksKey = "updates.automaticChecksEnabled";
    private const string LastBackgroundCheckKey = "updates.lastBackgroundCheckUtc";
    private const string AppcastEnv = "OPENBURNBAR_WINDOWS_APPCAST_URL";
    private const string PinEnv = "OPENBURNBAR_WINDOWS_UPDATE_PIN";
    private const string StoreUpdatesUri = "ms-windows-store://downloadsandupdates";

    private static readonly object Gate = new();
    private static WinSparkleUpdaterHost? _host;
    private static WindowsUpdateStatus? _lastStatus;

    public static WindowsUpdateStatus GetStatus(WindowsSettingsPersistence persistence)
    {
        lock (Gate)
        {
            return _lastStatus ?? ConfigureLocked(persistence, configureNativeHost: true);
        }
    }

    public static WindowsUpdateStatus Configure(WindowsSettingsPersistence persistence)
    {
        lock (Gate)
        {
            return ConfigureLocked(persistence, configureNativeHost: true);
        }
    }

    public static void SetAutomaticChecks(WindowsSettingsPersistence persistence, bool enabled)
    {
        if (GetDistributionMetadata().Kind == DistributionKind.MicrosoftStore)
        {
            persistence.Write(AutomaticChecksKey, false);
            return;
        }
        persistence.Write(AutomaticChecksKey, enabled);
        lock (Gate)
        {
            _lastStatus = null;
        }
    }

    public static async Task<string> CheckWithUiAsync(WindowsSettingsPersistence persistence, CancellationToken cancellationToken = default)
    {
        WinSparkleUpdaterHost? host;
        WindowsUpdateStatus status;
        lock (Gate)
        {
            status = ConfigureLocked(persistence, configureNativeHost: true);
            host = _host;
        }

        if (status.ManagedByStore)
        {
            using Process _ = ChildProcessLaunchPolicy.StartDefaultBrowser(new Uri(status.AppcastUrl));
            return "Microsoft Store update settings opened.";
        }
        if (!status.HostConfigured || host is null)
        {
            return status.Message;
        }

        try
        {
            await host.CheckForUpdatesWithUiAsync(cancellationToken).ConfigureAwait(false);
            return "Update check started.";
        }
        catch (Exception ex) when (IsNativeUpdaterFailure(ex))
        {
            AppDiagnostics.LogException("updates.check-ui", ex);
            lock (Gate)
            {
                _host = null;
                _lastStatus = status with
                {
                    HostConfigured = false,
                    NativeHostAvailable = false,
                    Message = NativeFailureMessage(ex),
                };
                return _lastStatus.Message;
            }
        }
    }

    public static async Task RunAutomaticCheckIfDueAsync(WindowsSettingsPersistence persistence, CancellationToken cancellationToken = default)
    {
        if (GetDistributionMetadata().Kind == DistributionKind.MicrosoftStore)
        {
            return;
        }
        if (!persistence.Read(AutomaticChecksKey, false))
        {
            return;
        }

        DateTimeOffset last = persistence.Read(LastBackgroundCheckKey, DateTimeOffset.MinValue);
        if (DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24))
        {
            return;
        }

        WinSparkleUpdaterHost? host;
        WindowsUpdateStatus status;
        lock (Gate)
        {
            status = ConfigureLocked(persistence, configureNativeHost: true);
            host = _host;
        }

        if (!status.HostConfigured || host is null)
        {
            return;
        }

        try
        {
            await host.CheckForUpdatesInBackgroundAsync(cancellationToken).ConfigureAwait(false);
            persistence.Write(LastBackgroundCheckKey, DateTimeOffset.UtcNow);
        }
        catch (Exception ex) when (IsNativeUpdaterFailure(ex))
        {
            AppDiagnostics.LogException("updates.check-background", ex);
            lock (Gate)
            {
                _host = null;
                _lastStatus = status with
                {
                    HostConfigured = false,
                    NativeHostAvailable = false,
                    Message = NativeFailureMessage(ex),
                };
            }
        }
    }

    public static void OpenReleaseNotes()
    {
        Uri uri = new(GetFeedMetadata().ReleaseNotesUrl);
        using Process _ = ChildProcessLaunchPolicy.StartDefaultBrowser(uri);
    }

    private static WindowsUpdateStatus ConfigureLocked(WindowsSettingsPersistence persistence, bool configureNativeHost)
    {
        DistributionMetadata distribution = GetDistributionMetadata();
        string version = CurrentVersion();
        if (distribution.Kind == DistributionKind.MicrosoftStore)
        {
            _host = null;
            return _lastStatus = new WindowsUpdateStatus(
                version,
                "Microsoft Store",
                StoreUpdatesUri,
                $"https://apps.microsoft.com/detail/{distribution.ProductId}",
                AutomaticChecksEnabled: false,
                HostConfigured: false,
                NativeHostAvailable: false,
                ProductionPinInjected: false,
                AutomaticChecksAvailable: false,
                CheckActionAvailable: true,
                ManagedByStore: true,
                Message: "Microsoft Store manages signing, installation, and automatic updates for this app.");
        }
        if (distribution.Kind == DistributionKind.Invalid)
        {
            _host = null;
            return _lastStatus = new WindowsUpdateStatus(
                version,
                "unknown packaged channel",
                string.Empty,
                "https://github.com/Imagine-That-Ai/BurnBar/releases",
                AutomaticChecksEnabled: false,
                HostConfigured: false,
                NativeHostAvailable: false,
                ProductionPinInjected: false,
                AutomaticChecksAvailable: false,
                CheckActionAvailable: false,
                ManagedByStore: false,
                Message: "Updater disabled: packaged distribution metadata is malformed.");
        }

        FeedMetadata feed = GetFeedMetadata();
        string pin = Environment.GetEnvironmentVariable(PinEnv) ?? feed.PinnedKey;
        bool productionPinInjected = !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(PinEnv));
        bool automatic = persistence.Read(AutomaticChecksKey, false);
        string channel = productionPinInjected ? "direct-download" : "direct-download dev pin";

        PinnedUpdateKey? key = PinnedUpdateKey.TryLoad(pin);
        if (key is null)
        {
            return _lastStatus = new WindowsUpdateStatus(
                version,
                channel,
                feed.AppcastUrl,
                feed.ReleaseNotesUrl,
                automatic,
                HostConfigured: false,
                NativeHostAvailable: false,
                ProductionPinInjected: productionPinInjected,
                AutomaticChecksAvailable: true,
                CheckActionAvailable: false,
                ManagedByStore: false,
                Message: "Updater disabled: pinned Ed25519 update key is missing or malformed.");
        }

        if (!OperatingSystem.IsWindows())
        {
            return _lastStatus = new WindowsUpdateStatus(
                version,
                channel,
                feed.AppcastUrl,
                feed.ReleaseNotesUrl,
                automatic,
                HostConfigured: false,
                NativeHostAvailable: false,
                ProductionPinInjected: productionPinInjected,
                AutomaticChecksAvailable: true,
                CheckActionAvailable: false,
                ManagedByStore: false,
                Message: "Updater host is Windows-only.");
        }

        if (!configureNativeHost)
        {
            return _lastStatus = new WindowsUpdateStatus(
                version,
                channel,
                feed.AppcastUrl,
                feed.ReleaseNotesUrl,
                automatic,
                HostConfigured: false,
                NativeHostAvailable: true,
                ProductionPinInjected: productionPinInjected,
                AutomaticChecksAvailable: true,
                CheckActionAvailable: false,
                ManagedByStore: false,
                Message: "Updater configuration is valid.");
        }

        try
        {
            if (!UpdateVersion.TryParse(version, out UpdateVersion parsedVersion))
            {
                parsedVersion = UpdateVersion.Parse("0.1.0");
            }
            var configuration = new UpdaterConfiguration
            {
                AppcastUrl = feed.AppcastUrl,
                PinnedKey = key.Value,
                CurrentVersion = parsedVersion,
                Format = FeedFormat.Appcast,
                Channel = channel,
            };

            _host ??= new WinSparkleUpdaterHost();
            _host.Configure(configuration);
            return _lastStatus = new WindowsUpdateStatus(
                version,
                channel,
                feed.AppcastUrl,
                feed.ReleaseNotesUrl,
                automatic,
                HostConfigured: true,
                NativeHostAvailable: true,
                ProductionPinInjected: productionPinInjected,
                AutomaticChecksAvailable: true,
                CheckActionAvailable: true,
                ManagedByStore: false,
                Message: productionPinInjected
                    ? "WinSparkle updater configured with production feed pin."
                    : "WinSparkle updater configured with the committed development feed pin.");
        }
        catch (Exception ex) when (IsNativeUpdaterFailure(ex))
        {
            _host = null;
            return _lastStatus = new WindowsUpdateStatus(
                version,
                channel,
                feed.AppcastUrl,
                feed.ReleaseNotesUrl,
                automatic,
                HostConfigured: false,
                NativeHostAvailable: false,
                ProductionPinInjected: productionPinInjected,
                AutomaticChecksAvailable: true,
                CheckActionAvailable: false,
                ManagedByStore: false,
                Message: NativeFailureMessage(ex));
        }
    }

    private static DistributionMetadata GetDistributionMetadata()
    {
        string path = Path.Combine(
            AppContext.BaseDirectory,
            "Resources",
            "Updates",
            "distribution-channel.json");
        if (!File.Exists(path))
        {
            return new DistributionMetadata(DistributionKind.DirectDownload, string.Empty);
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
            JsonElement root = document.RootElement;
            int schemaVersion = root.TryGetProperty("schemaVersion", out JsonElement schema)
                && schema.TryGetInt32(out int parsedSchema)
                    ? parsedSchema
                    : 0;
            string channel = ReadString(root, "channel") ?? string.Empty;
            string productId = ReadString(root, "productId") ?? string.Empty;
            return schemaVersion == 1
                && string.Equals(channel, "microsoft-store", StringComparison.Ordinal)
                && !string.IsNullOrWhiteSpace(productId)
                    ? new DistributionMetadata(DistributionKind.MicrosoftStore, productId)
                    : new DistributionMetadata(DistributionKind.Invalid, string.Empty);
        }
        catch (JsonException)
        {
            return new DistributionMetadata(DistributionKind.Invalid, string.Empty);
        }
        catch (IOException)
        {
            return new DistributionMetadata(DistributionKind.Invalid, string.Empty);
        }
        catch (UnauthorizedAccessException)
        {
            return new DistributionMetadata(DistributionKind.Invalid, string.Empty);
        }
    }

    private static FeedMetadata GetFeedMetadata()
    {
        string updatesDir = Path.Combine(AppContext.BaseDirectory, "Resources", "Updates");
        string latestPath = Path.Combine(updatesDir, "latest-windows.json");
        string pinPath = Path.Combine(updatesDir, "pinned-update-key.pub");
        string appcastUrl = Environment.GetEnvironmentVariable(AppcastEnv)
            ?? "https://dl.openburnbar.app/windows/appcast-windows.xml";
        string releaseNotesUrl = "https://dl.openburnbar.app/windows/release-metadata.json";

        if (File.Exists(latestPath))
        {
            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(latestPath));
            JsonElement root = doc.RootElement;
            appcastUrl = ReadString(root, "appcastUrl") ?? appcastUrl;
            releaseNotesUrl = ReadString(root, "releaseNotesUrl") ?? releaseNotesUrl;
        }

        string pinnedKey = File.Exists(pinPath) ? File.ReadAllText(pinPath).Trim() : string.Empty;
        return new FeedMetadata(appcastUrl, releaseNotesUrl, pinnedKey);
    }

    private static string CurrentVersion()
    {
        string? informational = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        string? fileVersion = Process.GetCurrentProcess().MainModule?.FileVersionInfo.ProductVersion;
        return FirstVersionToken(informational) ?? FirstVersionToken(fileVersion) ?? "0.1.0";
    }

    private static string? FirstVersionToken(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        string token = value.Split('+', ' ', StringSplitOptions.RemoveEmptyEntries)[0];
        return UpdateVersion.TryParse(token, out _) ? token : null;
    }

    private static string? ReadString(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static bool IsNativeUpdaterFailure(Exception ex) =>
        ex is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or InvalidOperationException;

    private static string NativeFailureMessage(Exception ex) =>
        ex is DllNotFoundException
            ? "Updater unavailable: winsparkle.dll is not bundled with this build."
            : "Updater unavailable: " + ex.Message;

    private sealed record FeedMetadata(string AppcastUrl, string ReleaseNotesUrl, string PinnedKey);
    private sealed record DistributionMetadata(DistributionKind Kind, string ProductId);

    private enum DistributionKind
    {
        DirectDownload,
        MicrosoftStore,
        Invalid,
    }
}

internal static class WindowsStartupService
{
    private const string StartupTaskId = "OpenBurnBarAutoLaunch";

    public static async Task<WindowsStartupStatus> GetStatusAsync()
    {
        try
        {
            StartupTask task = await StartupTask.GetAsync(StartupTaskId);
            return FromTaskState(task.State);
        }
        catch (Exception ex)
        {
            return new WindowsStartupStatus(false, false, "Startup task unavailable in this unpackaged build: " + ex.Message);
        }
    }

    public static async Task<WindowsStartupStatus> SetEnabledAsync(bool enabled)
    {
        try
        {
            StartupTask task = await StartupTask.GetAsync(StartupTaskId);
            if (enabled)
            {
                StartupTaskState state = await task.RequestEnableAsync();
                return FromTaskState(state);
            }

            task.Disable();
            return FromTaskState(task.State);
        }
        catch (Exception ex)
        {
            return new WindowsStartupStatus(false, false, "Startup task unavailable in this unpackaged build: " + ex.Message);
        }
    }

    private static WindowsStartupStatus FromTaskState(StartupTaskState state) => state switch
    {
        StartupTaskState.Enabled => new WindowsStartupStatus(true, true, "Launch at startup is enabled."),
        StartupTaskState.Disabled => new WindowsStartupStatus(false, true, "Launch at startup is disabled."),
        StartupTaskState.DisabledByPolicy => new WindowsStartupStatus(false, false, "Launch at startup is disabled by system policy."),
        StartupTaskState.DisabledByUser => new WindowsStartupStatus(false, true, "Windows blocked automatic enablement; use Startup Apps to allow OpenBurnBar."),
        _ => new WindowsStartupStatus(false, false, "Launch at startup is unavailable."),
    };
}
