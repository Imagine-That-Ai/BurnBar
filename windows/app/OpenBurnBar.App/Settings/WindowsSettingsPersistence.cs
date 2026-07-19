using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.CloudSync.RuntimeSafety;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.TextExpansion;
using OpenBurnBar.CloudSync.Crypto;
using OpenBurnBar.CloudSync.AppCheck.Net;
using OpenBurnBar.CloudSync.AppCheck.Windows;
using Windows.ApplicationModel.DataTransfer;

namespace OpenBurnBar.App.Settings.Winui;

internal sealed class WindowsSettingsPersistence
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private readonly object _gate = new();
    private readonly string _path;
    private Dictionary<string, JsonElement> _values;

    public WindowsSettingsPersistence(string? path = null)
    {
        _path = path ?? Path.Combine(
            Path.GetDirectoryName(AppConfiguration.Current.ConfigFilePath)!,
            "settings.json");
        _values = Load(_path);
    }

    public T Read<T>(string key, T fallback)
    {
        lock (_gate)
        {
            if (!_values.TryGetValue(key, out JsonElement value)) return fallback;
            try
            {
                return value.Deserialize<T>(JsonOptions) is { } decoded ? decoded : fallback;
            }
            catch (JsonException)
            {
                return fallback;
            }
        }
    }

    public void Write<T>(string key, T value)
    {
        lock (_gate)
        {
            _values[key] = JsonSerializer.SerializeToElement(value, JsonOptions);
            Persist();
        }
    }

    public string ReadSecret(string name) => AppConfiguration.Current.SecretStore.Read(name) ?? string.Empty;

    public void WriteSecret(string name, string value)
    {
        IAppSecretStore store = AppConfiguration.Current.SecretStore;
        if (string.IsNullOrEmpty(value))
        {
            if (store.Contains(name)) store.Delete(name);
            return;
        }
        store.Write(name, value);
        SecretRedactor.Shared.Register(value);
    }

    public string DirectoryPath => Path.GetDirectoryName(_path)!;

    private void Persist()
    {
        Directory.CreateDirectory(DirectoryPath);
        string temporary = _path + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temporary, JsonSerializer.Serialize(_values, JsonOptions));
        File.Move(temporary, _path, overwrite: true);
    }

    private static Dictionary<string, JsonElement> Load(string path)
    {
        if (!File.Exists(path)) return new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(path), JsonOptions)
                ?? new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        }
        catch (JsonException)
        {
            string archive = path + ".corrupt-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss");
            File.Move(path, archive, overwrite: false);
            return new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        }
    }
}

internal static class WindowsSettingsComposition
{
    private static readonly WindowsSettingsPersistence Persistence = new();
    private static readonly Lazy<DesktopOAuthCredentialsProvider?> OAuth = new(
        () => CloudAuthProductionComposition.TryCreateOAuthCredentialsProvider());
    private static readonly Lazy<HttpClientAppCheckMintTransport> AppCheckTransport = new(() => new());

    public static WindowsSettingsPersistence SharedPersistence => Persistence;

    public static GatewayEndpointSettings LoadGatewayEndpointSettings() =>
        new GatewayStore(Persistence).Load();

    public static NotificationSettingsSnapshot LoadNotificationSettings() =>
        new NotificationStore(Persistence).Load();

    public static GatewayComposition CreateGatewayComposition()
    {
        var store = new GatewayRouteStore(Persistence);
        return GatewayCompositionFactory.Create(
            store.Load(),
            store.ReadCredential,
            new ModelRouteHealthStore(Path.Combine(
                Persistence.DirectoryPath,
                "gateway-model-health.json")),
            new GatewayRouteTelemetryStore(Path.Combine(
                Persistence.DirectoryPath,
                "gateway-route-events.jsonl")),
            new WindowsProviderCliProcessRunner(),
            enableProactiveDiscovery: true);
    }

    public static ProjectCodeRootSettingsViewModel CreateProjectCodeRootSettingsViewModel() =>
        new(new WindowsProjectCodeRootStore(Persistence));

    public static ProjectCodeRootSettingsSnapshot LoadProjectCodeRootSettings() =>
        new WindowsProjectCodeRootStore(Persistence).Load();

    public static void SaveProjectCodeRootSettings(ProjectCodeRootSettingsSnapshot settings) =>
        new WindowsProjectCodeRootStore(Persistence).Save(settings);

    public static bool TryConfigureProductionCloudSync()
    {
        DesktopOAuthCredentialsProvider? oauth = OAuth.Value;
        FirebaseOAuthSession? session = oauth?.CurrentSession;
        if (oauth is null || session is null || !oauth.IsSignedIn)
        {
            return false;
        }

        string? configuredAppId = Environment.GetEnvironmentVariable(CloudAuthProductionComposition.AppCheckAppIdEnv);
        if (string.IsNullOrWhiteSpace(configuredAppId))
        {
            return false;
        }

        ConfigureProductionCloudSync(oauth, session);
        return true;
    }

    public static void ConfigureCloudSync()
    {
        if (!TryConfigureProductionCloudSync())
        {
            WinAppCloudSyncHost.ConfigureFromAppConfiguration();
        }
        _ = App.Current.RefreshWindowsRuntimeSafetyConfigAsync();
    }

    private static void ConfigureProductionCloudSync(
        DesktopOAuthCredentialsProvider oauth,
        FirebaseOAuthSession session)
    {
        string appCheckAppId = CloudAuthProductionComposition.RequireAppCheckAppId();
        AppConfiguration config = AppConfiguration.Current;
        byte[] vaultKey = string.IsNullOrWhiteSpace(config.EffectiveVaultKeyB64())
            ? CloudVaultCrypto.GenerateVaultKey()
            : Convert.FromBase64String(config.EffectiveVaultKeyB64()!);
        config.UpdateAndSave(model =>
        {
            model.FirebaseUid = session.Uid;
            model.VaultKeyB64 = Convert.ToBase64String(vaultKey);
        });
        WinAppCloudSyncHost.ConfigureWithOAuth(
            oauth,
            config.EffectiveFirebaseProjectId(),
            session.Uid,
            vaultKey,
            new TpmAttestationProducer(),
            AppCheckTransport.Value,
            appCheckAppId);
    }

    public static object? Create(SettingsTab tab) => tab switch
    {
        SettingsTab.Daemon => new OpenBurnBar.App.Settings.ViewModels.Daemon.DaemonSettingsViewModel(),
        SettingsTab.Agents => new OpenBurnBar.App.Settings.ViewModels.Agents.AgentsSettingsViewModel(),
        SettingsTab.ModelProxy => new ModelProxySettingsViewModel(
            new GatewayStore(Persistence),
            new WindowsClipboard(),
            new GatewayRouteStore(Persistence)),
        SettingsTab.Alerts => new AlertsSettingsViewModel(new AlertStore(Persistence)),
        SettingsTab.Notifications => new NotificationsSettingsViewModel(new NotificationStore(Persistence)),
        SettingsTab.TextExpansion => new TextExpansionSettingsViewModel(
            new TextExpansionStore(Persistence),
            WindowsAccessibilityProbe.Instance),
        SettingsTab.ComputerUse => new ComputerUseSettingsViewModel(
            WindowsAccessibilityProbe.Instance,
            new FileComputerUseAuditService(ComputerUseAuditRoot()),
            new ComputerUsePermissionsStore(Persistence),
            new ComputerUseBrowserSettingsStore(Persistence),
            new WindowsBrowserComputerUseService(),
            CreateComputerUseFleetSafetySource()),
        SettingsTab.Pets => new PetsSettingsViewModel(store: new PetStore(Persistence)),
        SettingsTab.Account => new AccountSettingsViewModel(
            new OAuthAccountSessionGate(OAuth.Value),
            new OAuthAccountActionHost(OAuth.Value)),
        SettingsTab.Cloud => new CloudSettingsViewModel(
            new CloudStore(Persistence),
            new OAuthAccountSessionGate(OAuth.Value),
            UnavailableCloudBackupHost.Instance),
        SettingsTab.DevicesAndSync => new DevicesAndSyncSettingsViewModel(
            store: new DevicesSyncStore(Persistence),
            session: new OAuthAccountSessionGate(OAuth.Value)),
        SettingsTab.Media => new MercuryMediaSettingsViewModel(
            new FleetAwareMercuryMediaCapabilitySource(
                () =>
                {
                    WindowsRuntimeSafetySnapshot snapshot = WindowsRuntimeSafetyState.Shared.Current;
                    return !snapshot.IsFresh(DateTimeOffset.UtcNow) || snapshot.MediaKillSwitch;
                },
                new StaticMercuryMediaCapabilitySource(captureRuntimeSupported: OperatingSystem.IsWindows()))),
        _ => null,
    };

    private static IComputerUseFleetSafetySource CreateComputerUseFleetSafetySource() =>
        new DelegatingComputerUseFleetSafetySource(
            isResolved: () => WindowsRuntimeSafetyState.Shared.Current.IsFresh(DateTimeOffset.UtcNow),
            killSwitchActive: () => WindowsRuntimeSafetyState.Shared.Current.ComputerUseKillSwitch,
            watchEnabled: () => WindowsRuntimeSafetyState.Shared.Current.ComputerUseWatchEnabled,
            browserEnabled: () => WindowsRuntimeSafetyState.Shared.Current.ComputerUseBrowserEnabled,
            systemEnabled: () => WindowsRuntimeSafetyState.Shared.Current.ComputerUseSystemEnabled,
            phoneControlEnabled: () => WindowsRuntimeSafetyState.Shared.Current.ComputerUsePhoneControlEnabled,
            trustModesEnabled: () => WindowsRuntimeSafetyState.Shared.Current.ComputerUseTrustModesEnabled);

    private sealed class AlertStore(WindowsSettingsPersistence persistence) : IAlertSettingsStore
    {
        public AlertSettingsSnapshot Load() => persistence.Read("alerts", AlertSettingsSnapshot.Default);
        public void Save(AlertSettingsSnapshot settings) => persistence.Write("alerts", settings);
    }

    private sealed class NotificationStore(WindowsSettingsPersistence persistence) : INotificationSettingsStore
    {
        private static readonly string TokenName = AppSecretNames.ProviderSecret("settings", "telegram", "bot-token");
        public NotificationSettingsSnapshot Load()
        {
            NotificationSettingsSnapshot value = persistence.Read("notifications", NotificationSettingsSnapshot.Default);
            return value with { TelegramBotToken = persistence.ReadSecret(TokenName) };
        }
        public void Save(NotificationSettingsSnapshot settings)
        {
            persistence.WriteSecret(TokenName, settings.TelegramBotToken);
            persistence.Write("notifications", settings with { TelegramBotToken = string.Empty });
        }
    }

    private sealed class GatewayStore(WindowsSettingsPersistence persistence) : IGatewayEndpointStore
    {
        private static readonly string TokenName = AppSecretNames.ProviderSecret("settings", "model-proxy", "auth-token");
        public GatewayEndpointSettings Load()
        {
            GatewayEndpointSettings value = persistence.Read("modelProxy", GatewayEndpointSettings.Default);
            return value with { AuthToken = persistence.ReadSecret(TokenName) };
        }
        public void Save(GatewayEndpointSettings settings)
        {
            persistence.WriteSecret(TokenName, settings.AuthToken);
            persistence.Write("modelProxy", settings with { AuthToken = string.Empty });
        }
    }

    private sealed class GatewayRouteStore(WindowsSettingsPersistence persistence) : IGatewayRouteSettingsStore
    {
        private const string MetadataKey = "modelProxy.routes";

        public IReadOnlyList<GatewayRouteConfiguration> Load() =>
            persistence.Read(MetadataKey, Array.Empty<GatewayRouteConfiguration>());

        public string? ReadCredential(string routeId)
        {
            try
            {
                return NullIfEmpty(persistence.ReadSecret(AppSecretNames.GatewayRouteCredential(routeId)));
            }
            catch (SecretStoreException ex)
            {
                throw new GatewayRouteSettingsStoreException(
                    "The protected credential could not be read.",
                    ex);
            }
        }

        public void Upsert(
            GatewayRouteConfiguration configuration,
            string? replacementCredential,
            bool replaceCredential)
        {
            ArgumentNullException.ThrowIfNull(configuration);
            configuration.Validate();
            var priorRoutes = Load().ToArray();
            string secretName = AppSecretNames.GatewayRouteCredential(configuration.Id);
            string? priorCredential = replaceCredential ? ReadCredential(configuration.Id) : null;
            var nextRoutes = priorRoutes.ToList();
            int index = nextRoutes.FindIndex(route =>
                string.Equals(route.Id, configuration.Id, StringComparison.OrdinalIgnoreCase));
            GatewayRouteConfiguration normalized = configuration with
            {
                Id = configuration.Id.Trim(),
                Vendor = configuration.Vendor.Trim(),
                Model = configuration.Model.Trim(),
                Endpoint = configuration.Endpoint.Trim(),
            };
            if (index >= 0)
            {
                nextRoutes[index] = normalized;
            }
            else
            {
                nextRoutes.Add(normalized);
            }

            try
            {
                if (replaceCredential)
                {
                    persistence.WriteSecret(secretName, replacementCredential?.Trim() ?? string.Empty);
                }
                persistence.Write(MetadataKey, nextRoutes.ToArray());
            }
            catch (Exception ex) when (ex is SecretStoreException or IOException or UnauthorizedAccessException)
            {
                if (replaceCredential)
                {
                    TryRestoreCredential(persistence, secretName, priorCredential);
                }
                throw new GatewayRouteSettingsStoreException(
                    "Protected provider-route storage rejected the update.",
                    ex);
            }
        }

        public void Delete(string routeId)
        {
            var priorRoutes = Load().ToArray();
            var nextRoutes = priorRoutes
                .Where(route => !string.Equals(route.Id, routeId, StringComparison.OrdinalIgnoreCase))
                .ToArray();
            if (nextRoutes.Length == priorRoutes.Length)
            {
                return;
            }

            string secretName = AppSecretNames.GatewayRouteCredential(routeId);
            string? priorCredential = ReadCredential(routeId);
            try
            {
                persistence.WriteSecret(secretName, string.Empty);
                persistence.Write(MetadataKey, nextRoutes);
            }
            catch (Exception ex) when (ex is SecretStoreException or IOException or UnauthorizedAccessException)
            {
                TryRestoreCredential(persistence, secretName, priorCredential);
                throw new GatewayRouteSettingsStoreException(
                    "Protected provider-route storage rejected the delete.",
                    ex);
            }
        }

        private static string? NullIfEmpty(string value) =>
            string.IsNullOrWhiteSpace(value) ? null : value;

        private static void TryRestoreCredential(
            WindowsSettingsPersistence persistence,
            string secretName,
            string? priorCredential)
        {
            try
            {
                persistence.WriteSecret(secretName, priorCredential ?? string.Empty);
            }
            catch
            {
                // The original exception remains authoritative. The settings UI
                // reports failure and a subsequent edit can retry protected cleanup.
            }
        }
    }

    private sealed class PetStore(WindowsSettingsPersistence persistence) : IPetSettingsStore
    {
        public PetSettingsSnapshot Load() => persistence.Read("pets", PetSettingsSnapshot.Default);
        public void Save(PetSettingsSnapshot settings) => persistence.Write("pets", settings);
    }

    private sealed class CloudStore(WindowsSettingsPersistence persistence) : ICloudSettingsStore
    {
        public CloudSettingsSnapshot Load() => persistence.Read("cloud", CloudSettingsSnapshot.Default);
        public void Save(CloudSettingsSnapshot settings) => persistence.Write("cloud", settings);
    }

    private sealed class DevicesSyncStore(WindowsSettingsPersistence persistence) : IDevicesSyncStore
    {
        public bool CloudSyncEnabled
        {
            get => persistence.Read("devices.cloudSyncEnabled", false);
            set => persistence.Write("devices.cloudSyncEnabled", value);
        }
        public bool SmartDisplaysEnabled
        {
            get => persistence.Read("devices.smartDisplaysEnabled", false);
            set => persistence.Write("devices.smartDisplaysEnabled", value);
        }
    }

    private sealed class ComputerUsePermissionsStore(WindowsSettingsPersistence persistence) : IComputerUsePermissionsStore
    {
        public bool OnboardingCompleted
        {
            get => persistence.Read("computerUse.onboardingCompleted", false);
            set => persistence.Write("computerUse.onboardingCompleted", value);
        }
    }

    private sealed class ComputerUseBrowserSettingsStore(WindowsSettingsPersistence persistence)
        : IComputerUseBrowserSettingsStore
    {
        public string BrowserCheckUrl
        {
            get => persistence.Read("computerUse.browserCheckUrl", "https://example.com");
            set => persistence.Write("computerUse.browserCheckUrl", value);
        }
    }

    private sealed class TextExpansionStore : ITextExpansionSettingsStore
    {
        private readonly WindowsSettingsPersistence _persistence;
        private readonly string _snapshotPath;
        private readonly object _gate = new();

        public TextExpansionStore(WindowsSettingsPersistence persistence)
        {
            _persistence = persistence;
            _snapshotPath = Path.Combine(persistence.DirectoryPath, TextExpansionSnapshotStore.SnapshotFileName);
        }

        public IReadOnlyList<TextExpansionSnippet> LoadSnippets()
        {
            lock (_gate)
            {
                if (!File.Exists(_snapshotPath)) return Array.Empty<TextExpansionSnippet>();
                return TextExpansionSnapshotStore.Decode(File.ReadAllText(_snapshotPath)).Snippets
                    .Where(snippet => snippet.DeletedAt is null)
                    .ToArray();
            }
        }

        public void Upsert(TextExpansionSnippet snippet)
        {
            lock (_gate)
            {
                var rows = LoadAll().ToDictionary(row => row.Id, StringComparer.Ordinal);
                rows[snippet.Id] = snippet;
                SaveAll(rows.Values);
            }
        }

        public void Delete(string id, DateTimeOffset at)
        {
            lock (_gate)
            {
                var rows = LoadAll().ToDictionary(row => row.Id, StringComparer.Ordinal);
                if (rows.TryGetValue(id, out TextExpansionSnippet? snippet))
                    rows[id] = snippet.With(deletedAt: new Optional<DateTimeOffset?>(at), updatedAt: at);
                SaveAll(rows.Values);
            }
        }

        public TextExpansionRuntimeSettings LoadRuntime() =>
            _persistence.Read("textExpansion.runtime", TextExpansionRuntimeSettings.Default);

        public void SaveRuntime(TextExpansionRuntimeSettings settings) =>
            _persistence.Write("textExpansion.runtime", settings);

        private IReadOnlyList<TextExpansionSnippet> LoadAll() => File.Exists(_snapshotPath)
            ? TextExpansionSnapshotStore.Decode(File.ReadAllText(_snapshotPath)).Snippets
            : Array.Empty<TextExpansionSnippet>();

        private void SaveAll(IEnumerable<TextExpansionSnippet> snippets)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_snapshotPath)!);
            string temporary = _snapshotPath + ".tmp-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temporary, TextExpansionSnapshotStore.Encode(new TextExpansionSnapshot(snippets.ToArray())));
            File.Move(temporary, _snapshotPath, overwrite: true);
        }
    }

    private sealed class WindowsClipboard : ISettingsClipboard
    {
        public void WriteText(string text)
        {
            var content = new DataPackage();
            content.SetText(text);
            Clipboard.SetContent(content);
            Clipboard.Flush();
        }
    }

    private sealed class WindowsAccessibilityProbe : IAccessibilityProbe
    {
        public static readonly WindowsAccessibilityProbe Instance = new();
        public bool IsAccessibilityTrusted => OperatingSystem.IsWindows() && Environment.UserInteractive;
    }

    private sealed class OAuthAccountSessionGate(DesktopOAuthCredentialsProvider? oauth) : IAccountSessionGate
    {
        public bool IsSignedIn => oauth?.IsSignedIn == true;
        public bool IsAnonymous => false;
        public string? SignedInUid => oauth?.SignedInUid;
        public string? SignedInEmail => oauth?.CurrentSession?.Email;
    }

    private sealed class OAuthAccountActionHost(DesktopOAuthCredentialsProvider? oauth) : IAccountActionHost
    {
        public AccountActionResult SignInWithEmail(string email, string password) =>
            AccountActionResult.Fail("Email/password auth is not enabled for the Windows desktop client. Use Google sign-in.");

        public AccountActionResult SignUpWithEmail(string email, string password) => SignInWithEmail(email, password);

        public AccountActionResult LinkProvider(AuthProviderAction provider)
        {
            if (provider != AuthProviderAction.Google)
                return AccountActionResult.Fail($"{provider} sign-in is not configured for this Windows build.");
            if (oauth is null)
                return AccountActionResult.Fail("Google OAuth client configuration is missing.");
            try
            {
                FirebaseOAuthSession session = oauth.SignInAsync().GetAwaiter().GetResult();
                ConfigureProductionCloudSync(oauth, session);
                return AccountActionResult.Ok;
            }
            catch (Exception ex)
            {
                return AccountActionResult.Fail(ex.Message);
            }
        }

        public AccountActionResult UpgradeToPremium() =>
            AccountActionResult.Fail("Subscription management opens from the account portal after sign-in.");

        public AccountActionResult DeleteAccount() =>
            AccountActionResult.Fail("Account deletion is unavailable until the authenticated callable is configured.");

        public AccountActionResult SignOut()
        {
            oauth?.SignOut();
            AppConfiguration.Current.UpdateAndSave(model => model.FirebaseUid = null);
            return AccountActionResult.Ok;
        }
    }

    private sealed class UnavailableCloudBackupHost : ICloudBackupHost
    {
        public static readonly UnavailableCloudBackupHost Instance = new();
        public bool TriggerBackup() => false;
    }

    private static string ComputerUseAuditRoot()
    {
        string? configured = Environment.GetEnvironmentVariable(FileComputerUseAuditService.RootEnvironmentVariable);
        return string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenBurnBar",
                "computer-use-audit")
            : configured;
    }
}
