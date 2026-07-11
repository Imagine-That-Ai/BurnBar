using System.Text.Json;

namespace OpenBurnBar.App.Configuration;

/// <summary>
/// Process-wide runtime configuration. Resolution order per field: environment variable (CI/dev override),
/// then <c>app_config.json</c> under the app data directory, then empty (triggers InMemory / sample fallbacks).
/// </summary>
public sealed class AppConfiguration
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private static readonly Lazy<AppConfiguration> Instance = new(() => new AppConfiguration());

    private readonly object _gate = new();
    private AppConfigurationModel _model;
    private readonly string _filePath;

    private AppConfiguration()
    {
        _filePath = DefaultFilePath();
        _model = LoadFromDisk(_filePath);
    }

    internal AppConfiguration(string filePathForTests)
    {
        _filePath = filePathForTests;
        _model = LoadFromDisk(_filePath);
    }

    public static AppConfiguration Current => Instance.Value;

    /// <summary><c>%LOCALAPPDATA%\OpenBurnBar\app_config.json</c> on Windows; <c>~/.openburnbar/app_config.json</c> elsewhere.</summary>
    public static string DefaultFilePath()
    {
        string? local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (!string.IsNullOrWhiteSpace(local))
        {
            return Path.Combine(local, "OpenBurnBar", "app_config.json");
        }

        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".openburnbar", "app_config.json");
    }

    public string ConfigFilePath => _filePath;

    public bool HasSqlCipherCredentials =>
        !string.IsNullOrWhiteSpace(EffectiveSqlCipherDbPath())
        && !string.IsNullOrWhiteSpace(EffectiveSqlCipherPassphrase())
        && File.Exists(EffectiveSqlCipherDbPath()!);

    public bool HasFirebaseCredentials =>
        !string.IsNullOrWhiteSpace(EffectiveFirebaseUid())
        && !string.IsNullOrWhiteSpace(EffectiveFirebaseIdToken());

    public string? EffectiveSqlCipherDbPath() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PATH"),
            _model.SqlCipherDbPath);

    public string? EffectiveSqlCipherPassphrase() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE"),
            _model.SqlCipherPassphrase);

    public string EffectiveFirebaseProjectId() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_FIREBASE_PROJECT_ID"),
            _model.FirebaseProjectId)
        ?? "openburnbar-dev";

    public string? EffectiveFirebaseUid() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_FIREBASE_UID"),
            _model.FirebaseUid);

    public string? EffectiveFirebaseIdToken() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_FIREBASE_ID_TOKEN"),
            _model.FirebaseIdToken);

    public string? EffectiveAppCheckToken() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_APP_CHECK_TOKEN"),
            _model.AppCheckToken);

    public string? EffectiveVaultKeyB64() =>
        FirstNonEmpty(
            Environment.GetEnvironmentVariable("OPENBURNBAR_VAULT_KEY_B64"),
            _model.VaultKeyB64);

    /// <summary>Updates in-memory values and writes <c>app_config.json</c>. Does not override env at read time.</summary>
    public void Save(AppConfigurationModel model)
    {
        ArgumentNullException.ThrowIfNull(model);
        lock (_gate)
        {
            _model = Clone(model);
            PersistUnlocked();
        }
    }

    /// <summary>Merge partial updates into the persisted file (passphrase omitted keeps the previous value).</summary>
    public void UpdateAndSave(Action<AppConfigurationModel> mutate)
    {
        ArgumentNullException.ThrowIfNull(mutate);
        lock (_gate)
        {
            var draft = Clone(_model);
            mutate(draft);
            _model = draft;
            PersistUnlocked();
        }
    }

    /// <summary>Reload from disk (e.g. after external edit).</summary>
    public void Reload()
    {
        lock (_gate)
        {
            _model = LoadFromDisk(_filePath);
        }
    }

    public AppConfigurationModel Snapshot()
    {
        lock (_gate)
        {
            return Clone(_model);
        }
    }

    private void PersistUnlocked()
    {
        try
        {
            string? dir = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            AppConfigurationModel persisted = PrepareForPersistence(_model);
            string json = JsonSerializer.Serialize(persisted, JsonOptions);
            File.WriteAllText(_filePath, json);
        }
        catch
        {
            // Best-effort persistence — same posture as shell-state.json.
        }
    }

    private static AppConfigurationModel LoadFromDisk(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return new AppConfigurationModel();
            }

            string json = File.ReadAllText(path);
            AppConfigurationModel model = JsonSerializer.Deserialize<AppConfigurationModel>(json, JsonOptions) ?? new AppConfigurationModel();
            PopulateSecretsFromProtectedFields(model);
            PopulateLegacyPlaintextSecrets(model, json);
            return model;
        }
        catch
        {
            return new AppConfigurationModel();
        }
    }

    private static AppConfigurationModel Clone(AppConfigurationModel source) => new()
    {
        SqlCipherDbPath = source.SqlCipherDbPath,
        SqlCipherPassphrase = source.SqlCipherPassphrase,
        SqlCipherPassphraseProtected = source.SqlCipherPassphraseProtected,
        FirebaseProjectId = source.FirebaseProjectId,
        FirebaseUid = source.FirebaseUid,
        FirebaseIdToken = source.FirebaseIdToken,
        FirebaseIdTokenProtected = source.FirebaseIdTokenProtected,
        AppCheckToken = source.AppCheckToken,
        AppCheckTokenProtected = source.AppCheckTokenProtected,
        VaultKeyB64 = source.VaultKeyB64,
        VaultKeyB64Protected = source.VaultKeyB64Protected,
    };

    private static AppConfigurationModel PrepareForPersistence(AppConfigurationModel source) => new()
    {
        SqlCipherDbPath = source.SqlCipherDbPath,
        SqlCipherPassphraseProtected = AppConfigurationSecretProtector.Protect(source.SqlCipherPassphrase),
        FirebaseProjectId = source.FirebaseProjectId,
        FirebaseUid = source.FirebaseUid,
        FirebaseIdTokenProtected = AppConfigurationSecretProtector.Protect(source.FirebaseIdToken),
        AppCheckTokenProtected = AppConfigurationSecretProtector.Protect(source.AppCheckToken),
        VaultKeyB64Protected = AppConfigurationSecretProtector.Protect(source.VaultKeyB64),
    };

    private static void PopulateSecretsFromProtectedFields(AppConfigurationModel model)
    {
        model.SqlCipherPassphrase = AppConfigurationSecretProtector.Unprotect(model.SqlCipherPassphraseProtected);
        model.FirebaseIdToken = AppConfigurationSecretProtector.Unprotect(model.FirebaseIdTokenProtected);
        model.AppCheckToken = AppConfigurationSecretProtector.Unprotect(model.AppCheckTokenProtected);
        model.VaultKeyB64 = AppConfigurationSecretProtector.Unprotect(model.VaultKeyB64Protected);
    }

    private static void PopulateLegacyPlaintextSecrets(AppConfigurationModel model, string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        JsonElement root = document.RootElement;
        model.SqlCipherPassphrase ??= LegacyString(root, "sqlCipherPassphrase");
        model.FirebaseIdToken ??= LegacyString(root, "firebaseIdToken");
        model.AppCheckToken ??= LegacyString(root, "appCheckToken");
        model.VaultKeyB64 ??= LegacyString(root, "vaultKeyB64");
    }

    private static string? LegacyString(JsonElement root, string propertyName) =>
        root.TryGetProperty(propertyName, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string? FirstNonEmpty(string? env, string? file) =>
        !string.IsNullOrWhiteSpace(env) ? env.Trim() : string.IsNullOrWhiteSpace(file) ? null : file.Trim();
}
