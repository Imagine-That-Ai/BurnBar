using System;
using System.IO;
using System.Security.Cryptography;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Budget;
using OpenBurnBar.App.Presentation.ElderWand;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.Storage;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.SessionLogs;

namespace OpenBurnBar.App.Storage;

/// <summary>
/// Owns the process-level SQLCipher database for Windows surfaces. A clean profile provisions
/// a generated protected key + encrypted database; invalid storage becomes typed recovery state,
/// never a legitimate empty store.
/// </summary>
internal static class WindowsStorageDevHost
{
    private const string ProtectedKeyProvenance = "protected-generated:" + AppSecretNames.SqlCipherPassphrase;

    private static readonly object Gate = new();
    private static readonly WindowsSqlCipherProvisioner Provisioner = new();

    private static AppConfiguration? _configurationOverride;
    private static string? _databasePathOverride;
    private static WindowsStorageRuntimeStatus _status = WindowsStorageRuntimeStatus.NotStarted;

    public static WindowsStorageRuntimeStatus Status
    {
        get { lock (Gate) return _status; }
    }

    public static WindowsStorageRuntimeStatus InitializeRuntime(
        bool retryInterruptedMigration = false,
        WindowsStorageProvisioningFault? fault = null)
    {
        lock (Gate)
        {
            try
            {
                var (path, passphrase, provenance) = ResolveOrProvisionCredentialsUnlocked();
                var report = Provisioner.EnsureReady(path, passphrase, provenance, retryInterruptedMigration, fault);
                _status = WindowsStorageRuntimeStatus.Ready(report);
            }
            catch (WindowsStorageProvisioningException ex)
            {
                _status = WindowsStorageRuntimeStatus.RecoveryRequired(ex.RecoveryState);
            }
            catch (SecretStoreException ex)
            {
                _status = WindowsStorageRuntimeStatus.RecoveryRequired(SecretStoreRecoveryState(ex));
            }

            return _status;
        }
    }

    public static (string? Path, string? Passphrase) ResolveCredentials()
    {
        var status = InitializeRuntime();
        if (!status.IsReady)
        {
            throw new WindowsStorageProvisioningException(status.RecoveryState!);
        }

        var (_, passphrase, _) = ResolveOrProvisionCredentialsUnlocked();
        return (status.Report!.DatabasePath, passphrase);
    }

    public static WindowsStorageRuntimeStatus RetryRecovery() => InitializeRuntime(retryInterruptedMigration: true);

    public static WindowsStorageArchiveResult ArchiveAndReset(bool confirmDestructiveReset)
    {
        lock (Gate)
        {
            var (path, passphrase, provenance) = ResolveOrProvisionCredentialsUnlocked();
            var result = Provisioner.ArchiveAndReset(path, passphrase, provenance, confirmDestructiveReset);
            _status = WindowsStorageRuntimeStatus.Ready(result.NewDatabase);
            return result;
        }
    }

    public static string? RecoveryLogPath => Status.RecoveryState?.RedactedLogPath ?? Status.Report?.RedactedLogPath;

    internal static void ConfigureForTests(AppConfiguration configuration, string databasePath)
    {
        lock (Gate)
        {
            _configurationOverride = configuration;
            _databasePathOverride = databasePath;
            _status = WindowsStorageRuntimeStatus.NotStarted;
        }
    }

    internal static void ResetForTests()
    {
        lock (Gate)
        {
            _configurationOverride = null;
            _databasePathOverride = null;
            _status = WindowsStorageRuntimeStatus.NotStarted;
        }
    }

    public static IBudgetRuleStore CreateBudgetRuleStore(System.Collections.Generic.IEnumerable<BudgetRule>? seedWhenInMemory = null)
    {
        var (path, passphrase) = ResolveCredentials();
        return new SqlCipherBudgetRuleStore(path!, passphrase!);
    }

    public static ISwitcherProfileStore CreateSwitcherProfileStore()
    {
        var (path, passphrase) = ResolveCredentials();
        return new SqlCipherSwitcherProfileStore(path!, passphrase!);
    }

    public static IElderWandPresetPersistence CreateElderWandPersistence()
    {
        var (path, passphrase) = ResolveCredentials();
        return new SqlCipherElderWandPersistence(path!, passphrase!);
    }

    public static ISessionLogReadSource CreateSessionLogReadSource()
    {
        var (path, passphrase) = ResolveCredentials();
        return new SqlCipherSessionLogReadSource(path!, passphrase!);
    }

    /// <summary>
    /// Reads <c>token_usage</c> aggregates from the provisioned SQLCipher store.
    /// </summary>
    public static DashboardUsageSummary LoadDashboardUsageSummary()
    {
        var (path, passphrase) = ResolveCredentials();
        using var store = OpenBurnBarStorage.OpenReadOnly(path!, passphrase!);
        var connection = store.Connection;
        double spend = TokenUsageReadSeam.SumCostCurrentUtcMonth(connection);
        long tokens = TokenUsageReadSeam.SumTotalTokens(connection);
        long sessions = TokenUsageReadSeam.CountDistinctSessions(connection);
        bool hasData = spend > 0 || tokens > 0 || sessions > 0;
        return new DashboardUsageSummary(
            spend,
            tokens,
            sessions,
            hasData,
            hasData ? DashboardUsageOrigin.Local : DashboardUsageOrigin.Empty);
    }

    private static (string Path, string Passphrase, string Provenance) ResolveOrProvisionCredentialsUnlocked()
    {
        AppConfiguration config = _configurationOverride ?? OpenBurnBar.App.Configuration.AppConfiguration.Current;
        string path = _databasePathOverride
            ?? config.EffectiveSqlCipherDbPath()
            ?? DefaultDatabasePath(config.ConfigFilePath);

        string? passphrase = config.EffectiveSqlCipherPassphrase();
        if (string.IsNullOrWhiteSpace(passphrase))
        {
            passphrase = GeneratePassphrase();
            config.UpdateAndSave(model =>
            {
                model.SqlCipherDbPath = path;
                model.SqlCipherPassphrase = passphrase;
            });
        }
        else if (string.IsNullOrWhiteSpace(config.Snapshot().SqlCipherDbPath))
        {
            config.UpdateAndSave(model => model.SqlCipherDbPath = path);
        }

        return (path, passphrase, ProtectedKeyProvenance);
    }

    private static string DefaultDatabasePath(string configFilePath)
    {
        string directory = Path.GetDirectoryName(configFilePath) ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".openburnbar");
        return Path.Combine(directory, "openburnbar.sqlite");
    }

    private static string GeneratePassphrase()
    {
        byte[] bytes = RandomNumberGenerator.GetBytes(32);
        return Convert.ToBase64String(bytes);
    }

    private static WindowsStorageRecoveryState SecretStoreRecoveryState(SecretStoreException ex)
    {
        WindowsStorageFailureKind kind = ex.Failure switch
        {
            SecretStoreFailureKind.WriteDenied => WindowsStorageFailureKind.AccessDenied,
            SecretStoreFailureKind.ReadDenied => WindowsStorageFailureKind.AccessDenied,
            SecretStoreFailureKind.ProtectedStorageUnavailable => WindowsStorageFailureKind.AccessDenied,
            SecretStoreFailureKind.SecretMissing => WindowsStorageFailureKind.WrongKey,
            SecretStoreFailureKind.CorruptProtectedPayload => WindowsStorageFailureKind.WrongKey,
            _ => WindowsStorageFailureKind.AccessDenied,
        };
        string configPath = _configurationOverride?.ConfigFilePath ?? OpenBurnBar.App.Configuration.AppConfiguration.DefaultFilePath();
        string path = _configurationOverride?.EffectiveSqlCipherDbPath()
            ?? DefaultDatabasePath(configPath);
        return new WindowsStorageRecoveryState(
            kind,
            "Protected storage is not available for the SQLCipher key.",
            ex.Message,
            new[]
            {
                WindowsStorageRecoveryAction.Retry,
                WindowsStorageRecoveryAction.RevealRedactedLog,
            },
            path,
            WindowsSqlCipherProvisioner.JournalPath(path),
            WindowsSqlCipherProvisioner.RedactedLogPath(path));
    }
}

internal sealed record WindowsStorageRuntimeStatus(
    bool IsReady,
    WindowsStorageProvisioningReport? Report,
    WindowsStorageRecoveryState? RecoveryState)
{
    public static WindowsStorageRuntimeStatus NotStarted { get; } = new(false, null, null);

    public static WindowsStorageRuntimeStatus Ready(WindowsStorageProvisioningReport report) =>
        new(true, report, null);

    public static WindowsStorageRuntimeStatus RecoveryRequired(WindowsStorageRecoveryState state) =>
        new(false, null, state);
}
