using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.ComputerUse;
using OpenBurnBar.App.Media;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.TextExpansion;
using OpenBurnBar.CloudSync.Crypto;
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

    public static WindowsSettingsPersistence SharedPersistence => Persistence;

    public static object? Create(SettingsTab tab) => tab switch
    {
        SettingsTab.Daemon => new OpenBurnBar.App.Settings.ViewModels.Daemon.DaemonSettingsViewModel(),
        SettingsTab.Agents => new OpenBurnBar.App.Settings.ViewModels.Agents.AgentsSettingsViewModel(),
        SettingsTab.ModelProxy => new ModelProxySettingsViewModel(
            new GatewayStore(Persistence),
            new WindowsClipboard()),
        SettingsTab.Alerts => new AlertsSettingsViewModel(new AlertStore(Persistence)),
        SettingsTab.Notifications => new NotificationsSettingsViewModel(new NotificationStore(Persistence)),
        SettingsTab.TextExpansion => new TextExpansionSettingsViewModel(
            new TextExpansionStore(Persistence),
            WindowsAccessibilityProbe.Instance),
        SettingsTab.ComputerUse => new ComputerUseSettingsViewModel(
            WindowsAccessibilityProbe.Instance,
            WindowsComputerUseRuntimeHost.Current,
            new ComputerUsePermissionsStore(Persistence),
            WindowsComputerUseRuntimeHost.Current),
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
        SettingsTab.Media => new MediaSettingsViewModel(WindowsMercuryRuntimeHost.Current),
        _ => null,
    };

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
                AppConfiguration config = AppConfiguration.Current;
                byte[] vaultKey = string.IsNullOrWhiteSpace(config.EffectiveVaultKeyB64())
                    ? CloudVaultCrypto.GenerateVaultKey()
                    : Convert.FromBase64String(config.EffectiveVaultKeyB64()!);
                config.UpdateAndSave(model =>
                {
                    model.FirebaseUid = session.Uid;
                    model.VaultKeyB64 = Convert.ToBase64String(vaultKey);
                });
                WinAppCloudSyncHost.ConfigureWithOAuth(oauth, config.EffectiveFirebaseProjectId(), session.Uid, vaultKey);
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

}
