using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text;

namespace OpenBurnBar.App.Configuration;

/// <summary>
/// Process-wide runtime configuration. Resolution order per field: environment variable (CI/dev override),
/// then protected-storage references from <c>app_config.json</c>, then empty.
/// </summary>
public sealed class AppConfiguration
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    private static readonly Lazy<AppConfiguration> Instance = new(() => new AppConfiguration());

    private readonly object _gate = new();
    private AppConfigurationModel _model;
    private readonly string _filePath;
    private readonly IAppSecretStore _secretStore;
    private readonly SecretMigrationFaults? _faults;
    private AppConfigurationSecurityState _securityState = new(AppConfigurationSecurityStatus.Clean);

    private AppConfiguration()
    {
        _filePath = DefaultFilePath();
        _secretStore = ProtectedFileSecretStore.CreateDefault();
        _model = LoadFromDisk(_filePath);
    }

    internal AppConfiguration(string filePathForTests)
        : this(filePathForTests, ProtectedFileSecretStore.CreateForTests(DefaultSecretDirectoryFor(filePathForTests)), faults: null)
    {
    }

    internal AppConfiguration(string filePathForTests, IAppSecretStore secretStore, SecretMigrationFaults? faults = null)
    {
        _filePath = filePathForTests;
        _secretStore = secretStore;
        _faults = faults;
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

    public IAppSecretStore SecretStore => _secretStore;

    public AppConfigurationSecurityState SecurityState
    {
        get { lock (_gate) return _securityState; }
    }

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
        ResolveEnvOrSecret(
            "OPENBURNBAR_SQLCIPHER_PASSPHRASE",
            _model.SqlCipherPassphraseRef,
            nameof(AppConfigurationModel.SqlCipherPassphraseRef));

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
        ResolveEnvOrSecret(
            "OPENBURNBAR_FIREBASE_ID_TOKEN",
            _model.FirebaseIdTokenRef,
            nameof(AppConfigurationModel.FirebaseIdTokenRef));

    public string? EffectiveAppCheckToken() =>
        ResolveEnvOrSecret(
            "OPENBURNBAR_APP_CHECK_TOKEN",
            _model.AppCheckTokenRef,
            nameof(AppConfigurationModel.AppCheckTokenRef));

    public string? EffectiveVaultKeyB64() =>
        ResolveEnvOrSecret(
            "OPENBURNBAR_VAULT_KEY_B64",
            _model.VaultKeyB64Ref,
            nameof(AppConfigurationModel.VaultKeyB64Ref));

    /// <summary>Updates in-memory values and writes <c>app_config.json</c>. Does not override env at read time.</summary>
    public void Save(AppConfigurationModel model)
    {
        ArgumentNullException.ThrowIfNull(model);
        lock (_gate)
        {
            _model = PrepareForPersistence(model, _model);
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
            _model = PrepareForPersistence(draft, _model);
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
            string json = JsonSerializer.Serialize(_model, JsonOptions);
            AtomicWriteAllText(_filePath, json);
        }
        catch (SecretStoreException)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.WriteDenied,
                "Configuration could not be persisted.",
                innerException: ex);
        }
    }

    private AppConfigurationModel LoadFromDisk(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                CleanupCompletedJournal(path);
                return new AppConfigurationModel();
            }

            string json = File.ReadAllText(path);
            AppConfigurationModel model = JsonSerializer.Deserialize<AppConfigurationModel>(json, JsonOptions)
                ?? new AppConfigurationModel();
            if (HasLegacySecrets(model))
            {
                model = MigrateLegacySecrets(path, model);
                _securityState = new(
                    AppConfigurationSecurityStatus.MigratedLegacySecrets,
                    "Legacy plaintext app_config.json secrets migrated to protected storage.");
            }
            else
            {
                CleanupCompletedJournal(path);
                _securityState = new(AppConfigurationSecurityStatus.Clean);
            }

            RegisterReferencedSecretsForRedaction(model);
            return ClearLegacyPlaintext(model);
        }
        catch (SecretStoreException ex)
        {
            _securityState = new(AppConfigurationSecurityStatus.MigrationFailed, ex.Message);
            throw;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            _securityState = new(AppConfigurationSecurityStatus.MigrationFailed, ex.Message);
            throw new SecretStoreException(
                SecretStoreFailureKind.CorruptProtectedPayload,
                "Configuration file could not be loaded.",
                innerException: ex);
        }
    }

    private static AppConfigurationModel Clone(AppConfigurationModel source) => new()
    {
        SqlCipherDbPath = source.SqlCipherDbPath,
        SqlCipherPassphrase = source.SqlCipherPassphrase,
        SqlCipherPassphraseRef = source.SqlCipherPassphraseRef,
        FirebaseProjectId = source.FirebaseProjectId,
        FirebaseUid = source.FirebaseUid,
        FirebaseIdToken = source.FirebaseIdToken,
        FirebaseIdTokenRef = source.FirebaseIdTokenRef,
        AppCheckToken = source.AppCheckToken,
        AppCheckTokenRef = source.AppCheckTokenRef,
        VaultKeyB64 = source.VaultKeyB64,
        VaultKeyB64Ref = source.VaultKeyB64Ref,
    };

    private AppConfigurationModel PrepareForPersistence(AppConfigurationModel draft, AppConfigurationModel? prior)
    {
        var next = Clone(draft);
        next.SqlCipherPassphraseRef = StoreOrPreserve(
            next.SqlCipherPassphrase,
            next.SqlCipherPassphraseRef,
            prior?.SqlCipherPassphraseRef,
            AppSecretNames.SqlCipherPassphrase);
        next.FirebaseIdTokenRef = StoreOrPreserve(
            next.FirebaseIdToken,
            next.FirebaseIdTokenRef,
            prior?.FirebaseIdTokenRef,
            AppSecretNames.FirebaseIdToken);
        next.AppCheckTokenRef = StoreOrPreserve(
            next.AppCheckToken,
            next.AppCheckTokenRef,
            prior?.AppCheckTokenRef,
            AppSecretNames.AppCheckToken);
        next.VaultKeyB64Ref = StoreOrPreserve(
            next.VaultKeyB64,
            next.VaultKeyB64Ref,
            prior?.VaultKeyB64Ref,
            AppSecretNames.CloudVaultKeyB64);

        return ClearLegacyPlaintext(next);
    }

    private string? StoreOrPreserve(string? plaintext, string? requestedRef, string? priorRef, string canonicalRef)
    {
        if (!string.IsNullOrWhiteSpace(plaintext))
        {
            _secretStore.Write(canonicalRef, plaintext);
            string? verified = _secretStore.Read(canonicalRef);
            if (!string.Equals(verified, plaintext, StringComparison.Ordinal))
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.VerificationFailed,
                    "Protected secret write verification failed.",
                    canonicalRef);
            }

            return canonicalRef;
        }

        return FirstNonEmpty(null, requestedRef) ?? FirstNonEmpty(null, priorRef);
    }

    private AppConfigurationModel MigrateLegacySecrets(string path, AppConfigurationModel legacy)
    {
        var secrets = LegacySecrets(legacy).ToArray();
        string journalPath = JournalPath(path);
        var journal = new SecretMigrationJournal
        {
            ConfigPath = path,
            SecretRefs = secrets.Select(s => s.SecretName).ToArray(),
        };
        AtomicWriteAllText(journalPath, JsonSerializer.Serialize(journal, JsonOptions));
        _faults?.ThrowIf(SecretMigrationBoundary.AfterJournalWritten);

        foreach (LegacySecret secret in secrets)
        {
            _secretStore.Write(secret.SecretName, secret.Value);
            _faults?.ThrowIf(SecretMigrationBoundary.AfterSecretWritten, secret.SecretName);
            string? verified = _secretStore.Read(secret.SecretName);
            if (!string.Equals(verified, secret.Value, StringComparison.Ordinal))
            {
                throw new SecretStoreException(
                    SecretStoreFailureKind.VerificationFailed,
                    "Legacy secret protected write did not verify.",
                    secret.SecretName);
            }

            _faults?.ThrowIf(SecretMigrationBoundary.AfterSecretVerified, secret.SecretName);
        }

        AppConfigurationModel migrated = ClearLegacyPlaintext(Clone(legacy));
        migrated.SqlCipherPassphraseRef = MergeRef(migrated.SqlCipherPassphraseRef, legacy.SqlCipherPassphrase, AppSecretNames.SqlCipherPassphrase);
        migrated.FirebaseIdTokenRef = MergeRef(migrated.FirebaseIdTokenRef, legacy.FirebaseIdToken, AppSecretNames.FirebaseIdToken);
        migrated.AppCheckTokenRef = MergeRef(migrated.AppCheckTokenRef, legacy.AppCheckToken, AppSecretNames.AppCheckToken);
        migrated.VaultKeyB64Ref = MergeRef(migrated.VaultKeyB64Ref, legacy.VaultKeyB64, AppSecretNames.CloudVaultKeyB64);

        AtomicWriteAllText(path, JsonSerializer.Serialize(migrated, JsonOptions));
        _faults?.ThrowIf(SecretMigrationBoundary.AfterConfigReplaced);
        TryDelete(journalPath);
        return migrated;
    }

    private void RegisterReferencedSecretsForRedaction(AppConfigurationModel model)
    {
        foreach (string? reference in new[]
        {
            model.SqlCipherPassphraseRef,
            model.FirebaseIdTokenRef,
            model.AppCheckTokenRef,
            model.VaultKeyB64Ref,
        })
        {
            if (!string.IsNullOrWhiteSpace(reference))
            {
                string? secret = _secretStore.Read(reference);
                if (secret is null)
                {
                    throw new SecretStoreException(
                        SecretStoreFailureKind.SecretMissing,
                        "Configuration references a missing protected secret.",
                        reference);
                }
                else
                {
                    SecretRedactor.Shared.Register(secret);
                }
            }
        }
    }

    private string? ResolveSecret(string? reference, string fieldName)
    {
        if (string.IsNullOrWhiteSpace(reference))
        {
            return null;
        }

        string? value = _secretStore.Read(reference);
        if (value is null)
        {
            throw new SecretStoreException(
                SecretStoreFailureKind.SecretMissing,
                $"Configuration field {fieldName} references a missing protected secret.",
                reference);
        }

        SecretRedactor.Shared.Register(value);
        return value;
    }

    private string? ResolveEnvOrSecret(string environmentVariable, string? reference, string fieldName)
    {
        string? env = Environment.GetEnvironmentVariable(environmentVariable);
        if (!string.IsNullOrWhiteSpace(env))
        {
            string value = env.Trim();
            SecretRedactor.Shared.Register(value);
            return value;
        }

        return ResolveSecret(reference, fieldName);
    }

    private static IEnumerable<LegacySecret> LegacySecrets(AppConfigurationModel model)
    {
        if (!string.IsNullOrWhiteSpace(model.SqlCipherPassphrase))
        {
            yield return new LegacySecret(AppSecretNames.SqlCipherPassphrase, model.SqlCipherPassphrase);
        }

        if (!string.IsNullOrWhiteSpace(model.FirebaseIdToken))
        {
            yield return new LegacySecret(AppSecretNames.FirebaseIdToken, model.FirebaseIdToken);
        }

        if (!string.IsNullOrWhiteSpace(model.AppCheckToken))
        {
            yield return new LegacySecret(AppSecretNames.AppCheckToken, model.AppCheckToken);
        }

        if (!string.IsNullOrWhiteSpace(model.VaultKeyB64))
        {
            yield return new LegacySecret(AppSecretNames.CloudVaultKeyB64, model.VaultKeyB64);
        }
    }

    private static bool HasLegacySecrets(AppConfigurationModel model) => LegacySecrets(model).Any();

    private static AppConfigurationModel ClearLegacyPlaintext(AppConfigurationModel model)
    {
        model.SqlCipherPassphrase = null;
        model.FirebaseIdToken = null;
        model.AppCheckToken = null;
        model.VaultKeyB64 = null;
        return model;
    }

    private static string? MergeRef(string? existing, string? legacyValue, string canonicalRef) =>
        !string.IsNullOrWhiteSpace(existing)
            ? existing
            : !string.IsNullOrWhiteSpace(legacyValue)
                ? canonicalRef
                : null;

    private static void CleanupCompletedJournal(string path)
    {
        string journal = JournalPath(path);
        if (File.Exists(journal))
        {
            TryDelete(journal);
        }
    }

    private static string JournalPath(string path) => path + ".secret-migration.json";

    private static string DefaultSecretDirectoryFor(string configPath)
    {
        string directory = Path.GetDirectoryName(configPath) ?? Path.GetTempPath();
        return Path.Combine(directory, "protected-secrets");
    }

    private static void AtomicWriteAllText(string path, string contents)
    {
        string? dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }

        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        string backup = path + "." + Guid.NewGuid().ToString("N") + ".bak";
        File.WriteAllText(temp, contents, Encoding.UTF8);
        if (File.Exists(path))
        {
            File.Replace(temp, path, backup, ignoreMetadataErrors: true);
            TryDelete(backup);
        }
        else
        {
            File.Move(temp, path);
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch { /* best effort */ }
    }

    private static string? FirstNonEmpty(string? env, string? file)
    {
        string? value = !string.IsNullOrWhiteSpace(env) ? env.Trim() : string.IsNullOrWhiteSpace(file) ? null : file.Trim();
        if (value is not null)
        {
            SecretRedactor.Shared.Register(value);
        }

        return value;
    }

    private sealed record LegacySecret(string SecretName, string Value);
}
