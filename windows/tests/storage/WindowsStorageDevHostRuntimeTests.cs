using System;
using System.IO;
using System.Linq;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Storage;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Storage.Tests;

[Collection(WindowsStorageTestCollection.Name)]
public sealed class WindowsStorageDevHostRuntimeTests : IDisposable
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";
    private const string SqlPathEnv = "OPENBURNBAR_SQLCIPHER_PATH";
    private const string SqlPassEnv = "OPENBURNBAR_SQLCIPHER_PASSPHRASE";

    public void Dispose()
    {
        Environment.SetEnvironmentVariable(SampleEnv, null);
        Environment.SetEnvironmentVariable(SqlPathEnv, null);
        Environment.SetEnvironmentVariable(SqlPassEnv, null);
        WindowsStorageDevHost.ResetForTests();
    }

    [Fact]
    public void CleanProfile_ProvisionsEncryptedDatabase_GeneratedProtectedKey_AndMigrationJournal()
    {
        using var profile = TestProfile.Create();

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.True(status.IsReady);
        WindowsStorageProvisioningReport report = status.Report!;
        Assert.True(report.Created);
        Assert.True(File.Exists(profile.DatabasePath));
        Assert.True(File.Exists(report.JournalPath));
        Assert.True(File.Exists(profile.DatabasePath + ".key-provenance.json"));
        Assert.True(SqlCipherConnection.FileIsEncrypted(profile.DatabasePath));
        Assert.Equal("protected-generated:openburnbar.windows.sqlcipher.passphrase", report.KeyProvenance);
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentMigrationEndpoint, report.SchemaEndpoint);
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentMigrationCount, report.MigrationCount);
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentUserVersion, report.UserVersion);
        Assert.Contains("\"state\": \"complete\"", File.ReadAllText(report.JournalPath), StringComparison.Ordinal);
        Assert.Contains("\"keyProvenance\": \"protected-generated:openburnbar.windows.sqlcipher.passphrase\"", File.ReadAllText(report.JournalPath), StringComparison.Ordinal);

        string configJson = File.ReadAllText(profile.Configuration.ConfigFilePath);
        Assert.Contains("\"sqlCipherDbPath\"", configJson, StringComparison.Ordinal);
        Assert.Contains("\"sqlCipherPassphraseRef\"", configJson, StringComparison.Ordinal);
        Assert.DoesNotContain("sqlCipherPassphrase\":", configJson, StringComparison.Ordinal);

        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        using var connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!);
        SqlCipherConnection.AssertPinnedParams(connection, out string cipherVersion);
        Assert.Equal(report.CipherVersion, cipherVersion);
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentMigrationEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentUserVersion, SqlCipherConnection.ReadUserVersion(connection));
        WriteEvidence("fresh-install", profile.DatabasePath, report, null);
    }

    [Fact]
    public void CleanProfile_Restart_IsIdempotent_AndKeepsTheSameDatabaseAndKey()
    {
        using var profile = TestProfile.Create();

        WindowsStorageProvisioningReport first = WindowsStorageDevHost.InitializeRuntime().Report!;
        string firstConfig = File.ReadAllText(profile.Configuration.ConfigFilePath);
        string firstJournal = File.ReadAllText(first.JournalPath);

        WindowsStorageProvisioningReport second = WindowsStorageDevHost.InitializeRuntime().Report!;

        Assert.False(second.Created);
        Assert.Equal(first.DatabasePath, second.DatabasePath);
        Assert.Equal(first.SchemaEndpoint, second.SchemaEndpoint);
        Assert.Equal(first.MigrationCount, second.MigrationCount);
        Assert.Equal(firstConfig, File.ReadAllText(profile.Configuration.ConfigFilePath));
        Assert.Contains("\"state\": \"complete\"", firstJournal, StringComparison.Ordinal);
        Assert.Contains("\"state\": \"complete\"", File.ReadAllText(second.JournalPath), StringComparison.Ordinal);
        WriteEvidence("restart-idempotency", profile.DatabasePath, second, null);
    }

    [Fact]
    public void GeneratedDatabase_SupportsProductionWriteAndReadSeams()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();

        using (var connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!))
        {
            TokenUsageWriteSeam.WriteTokenUsage(connection, new TokenUsageRecord
            {
                Id = "usage-1",
                Provider = "codex",
                SessionId = "session-1",
                ProjectName = "BurnBar",
                Model = "gpt-5",
                InputTokens = 10,
                OutputTokens = 20,
                TotalTokens = 30,
                Cost = 0.12,
                StartTime = "2026-07-09 12:00:00.000",
                EndTime = "2026-07-09 12:00:01.000",
                CreatedAt = "2026-07-09 12:00:01.000",
            });

            BudgetRuleWriteSeam.UpsertRule(connection, new BudgetRuleRow(
                Id: "budget-1",
                Scope: "provider",
                Identifier: "codex",
                ProviderId: "codex",
                AccountId: null,
                ProjectName: null,
                Label: "Codex",
                AmountUsd: 25,
                Period: "monthly",
                Behavior: "block",
                FallbackCredentialIds: Array.Empty<string>(),
                PausedUntil: null,
                CreatedAt: DateTimeOffset.UtcNow,
                UpdatedAt: DateTimeOffset.UtcNow,
                SyncedAt: null,
                SourceDeviceId: null,
                IsEnabled: true));

            SwitcherProfileWriteSeam.UpsertProfile(connection, new SwitcherProfileRow(
                Id: "profile-1",
                TargetKind: "cli",
                BrowserType: null,
                BrowserMetadataJson: null,
                CliType: "codex",
                CliMetadataJson: "{\"displayLabel\":\"Codex\"}",
                SortKey: 0,
                CreatedAt: DateTimeOffset.UtcNow,
                UpdatedAt: DateTimeOffset.UtcNow));

            ElderWandPresetWriteSeam.UpsertString(connection, "elderWand.presets.v1", "[]", DateTimeOffset.UtcNow);
        }

        using (var connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!))
        {
            Assert.NotNull(TokenUsageWriteSeam.ReadTokenUsage(connection, "usage-1"));
            Assert.Single(BudgetRuleWriteSeam.FetchAllRules(connection, includeDisabled: true));
            Assert.Single(SwitcherProfileWriteSeam.FetchAllProfiles(connection));
            Assert.Equal("[]", ElderWandPresetWriteSeam.ReadString(connection, "elderWand.presets.v1"));
            Assert.Equal(30, TokenUsageReadSeam.SumTotalTokens(connection));
        }

        var summary = WindowsStorageDevHost.LoadDashboardUsageSummary();
        Assert.True(summary.HasData);
        Assert.Equal(30, summary.TotalTokens);
        Assert.Equal(1, summary.SessionCount);
        WriteEvidence("generated-db-write-seams", profile.DatabasePath, WindowsStorageDevHost.Status.Report, null);
    }

    [Fact]
    public void WrongKey_ProducesDistinctRecoveryState_WithRetryArchiveResetAndRevealLog()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        WindowsStorageDevHost.ResetForTests();
        Environment.SetEnvironmentVariable(SqlPathEnv, profile.DatabasePath);
        Environment.SetEnvironmentVariable(SqlPassEnv, "WrongBase64Key-000000000000000000000000000=");

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.False(status.IsReady);
        AssertRecovery(status, WindowsStorageFailureKind.WrongKey);
        WriteEvidence("wrong-key-recovery", profile.DatabasePath, null, status.RecoveryState);
    }

    [Fact]
    public void CorruptDatabase_ProducesDistinctRecoveryState_AndArchiveResetCreatesANewValidDatabase()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        File.WriteAllText(profile.DatabasePath, "not a SQLCipher database");

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.False(status.IsReady);
        AssertRecovery(status, WindowsStorageFailureKind.CorruptDatabase);
        Assert.True(File.Exists(status.RecoveryState!.RedactedLogPath));

        WindowsStorageArchiveResult archive = WindowsStorageDevHost.ArchiveAndReset(confirmDestructiveReset: true);
        Assert.True(Directory.Exists(archive.ArchiveDirectory));
        Assert.True(File.Exists(archive.ArchivedDatabasePath));
        Assert.True(SqlCipherConnection.FileIsEncrypted(profile.DatabasePath));
        Assert.Equal(WindowsSqlCipherProvisioner.CurrentMigrationEndpoint, archive.NewDatabase.SchemaEndpoint);
        WriteEvidence("corrupt-archive-reset", profile.DatabasePath, archive.NewDatabase, status.RecoveryState);
    }

    [Theory]
    [InlineData(WindowsStorageProvisioningFaultKind.LockedFile, WindowsStorageFailureKind.LockedFile)]
    [InlineData(WindowsStorageProvisioningFaultKind.FullDisk, WindowsStorageFailureKind.FullDisk)]
    [InlineData(WindowsStorageProvisioningFaultKind.AccessDenied, WindowsStorageFailureKind.AccessDenied)]
    public void InjectedHostFaults_ProduceDistinctRecoveryStates(
        WindowsStorageProvisioningFaultKind fault,
        WindowsStorageFailureKind expected)
    {
        using var profile = TestProfile.Create();

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime(
            fault: new WindowsStorageProvisioningFault(fault));

        Assert.False(status.IsReady);
        AssertRecovery(status, expected);
        WriteEvidence("fault-" + expected, profile.DatabasePath, null, status.RecoveryState);
    }

    [Fact]
    public void InterruptedMigration_StaysRecoveryUntilExplicitRetry()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        File.WriteAllText(
            WindowsSqlCipherProvisioner.JournalPath(profile.DatabasePath),
            "{\"version\":1,\"state\":\"applying\"}");

        WindowsStorageRuntimeStatus interrupted = WindowsStorageDevHost.InitializeRuntime();

        Assert.False(interrupted.IsReady);
        AssertRecovery(interrupted, WindowsStorageFailureKind.InterruptedMigration);

        WindowsStorageRuntimeStatus retried = WindowsStorageDevHost.RetryRecovery();

        Assert.True(retried.IsReady);
        Assert.True(retried.Report!.RetriedInterruptedMigration);
        Assert.Contains("\"state\": \"complete\"", File.ReadAllText(retried.Report.JournalPath), StringComparison.Ordinal);
        WriteEvidence("interrupted-retry", profile.DatabasePath, retried.Report, interrupted.RecoveryState);
    }

    [Fact]
    public void UnsupportedSchema_ProducesDistinctRecoveryState_WithoutDowngradingMarker()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        using (var connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!))
        {
            using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO grdb_migrations(identifier) VALUES ('v999_future_schema')";
            command.ExecuteNonQuery();
        }

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.False(status.IsReady);
        AssertRecovery(status, WindowsStorageFailureKind.UnsupportedSchema);
        using var reopened = SqlCipherConnection.Open(profile.DatabasePath, passphrase!);
        Assert.Equal("v999_future_schema", SqlCipherConnection.ReadMigrationEndpoint(reopened));
        WriteEvidence("unsupported-schema-recovery", profile.DatabasePath, null, status.RecoveryState);
    }

    private static void AssertRecovery(WindowsStorageRuntimeStatus status, WindowsStorageFailureKind expected)
    {
        Assert.NotNull(status.RecoveryState);
        Assert.Equal(expected, status.RecoveryState!.Kind);
        Assert.Contains(WindowsStorageRecoveryAction.RevealRedactedLog, status.RecoveryState.Actions);
        Assert.True(File.Exists(status.RecoveryState.RedactedLogPath));
        if (expected is not WindowsStorageFailureKind.FullDisk and not WindowsStorageFailureKind.AccessDenied and not WindowsStorageFailureKind.LockedFile)
        {
            Assert.Contains(WindowsStorageRecoveryAction.Reset, status.RecoveryState.Actions);
        }
    }

    private static void WriteEvidence(
        string name,
        string databasePath,
        WindowsStorageProvisioningReport? report,
        WindowsStorageRecoveryState? recovery)
    {
        string? root = Environment.GetEnvironmentVariable("OPENBURNBAR_STORAGE_EVIDENCE_DIR");
        if (string.IsNullOrWhiteSpace(root))
        {
            return;
        }

        string dir = Path.Combine(root, name);
        Directory.CreateDirectory(dir);
        string json = System.Text.Json.JsonSerializer.Serialize(new
        {
            name,
            databasePath,
            databaseExists = File.Exists(databasePath),
            encryptedHeader = File.Exists(databasePath) && SqlCipherConnection.FileIsEncrypted(databasePath),
            walExists = File.Exists(databasePath + "-wal"),
            shmExists = File.Exists(databasePath + "-shm"),
            report,
            recovery,
        }, new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(Path.Combine(dir, "evidence.json"), json);
        foreach (string suffix in new[] { ".windows-migration-journal.json", ".key-provenance.json", ".recovery.log" })
        {
            string source = databasePath + suffix;
            if (File.Exists(source))
            {
                File.Copy(source, Path.Combine(dir, Path.GetFileName(databasePath) + suffix), overwrite: true);
            }
        }
    }

    private sealed class TestProfile : IDisposable
    {
        private readonly string _root;

        private TestProfile(string root, AppConfiguration configuration, string databasePath)
        {
            _root = root;
            Configuration = configuration;
            DatabasePath = databasePath;
        }

        public AppConfiguration Configuration { get; }
        public string DatabasePath { get; }

        public static TestProfile Create()
        {
            string root = Path.Combine(Path.GetTempPath(), "obb-storage-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            string configPath = Path.Combine(root, "app_config.json");
            var configuration = new AppConfiguration(configPath);
            string databasePath = Path.Combine(root, "openburnbar.sqlite");
            WindowsStorageDevHost.ConfigureForTests(configuration, databasePath);
            return new TestProfile(root, configuration, databasePath);
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(_root, recursive: true);
            }
            catch
            {
                // Best-effort cleanup.
            }
        }
    }
}
