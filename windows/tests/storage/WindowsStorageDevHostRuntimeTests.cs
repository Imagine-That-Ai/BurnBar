using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Data.Sqlite;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Storage;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Storage.Tests;

[Collection(WindowsStorageTestCollection.Name)]
public sealed class WindowsStorageDevHostRuntimeTests : IDisposable
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";

    // Literal mirrors of WindowsSqlCipherProvisioner.CurrentMigrationEndpoint /
    // CurrentMigrationCount — deliberately NOT read from the production constants,
    // so an unintended provisioner edit fails here instead of agreeing with itself.
    // Both move together on every new migration; the count equals the length of
    // WindowsSqlCipherProvisioner.AppliedMigrationIdentifiers (= the Swift
    // migrator's registration count).
    private const string ExpectedSchemaEndpoint = "v66_agent_memory_bodies";
    private const long ExpectedMigrationCount = 67;

    public void Dispose()
    {
        Environment.SetEnvironmentVariable(SampleEnv, null);
        Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PATH", null);
        Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", null);
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
        Assert.Equal(ExpectedSchemaEndpoint, report.SchemaEndpoint);
        Assert.Equal(ExpectedMigrationCount, report.MigrationCount);
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
        Assert.Equal(ExpectedSchemaEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
        Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
        AssertV56CheckpointSchema(connection);
        using (var insertManifest = connection.CreateCommand())
        {
            insertManifest.CommandText = """
                INSERT INTO parser_checkpoint_files (
                    provider, path, fileSizeBytes, modificationDate, creationDate,
                    fileSystemNumber, fileNumber
                ) VALUES ($provider, $path, $size, $modified, $created, $filesystem, $file)
                """;
            insertManifest.Parameters.AddWithValue("$provider", "codex");
            insertManifest.Parameters.AddWithValue("$path", "C:\\Users\\Test\\.codex\\rollout.jsonl");
            insertManifest.Parameters.AddWithValue("$size", 4096);
            insertManifest.Parameters.AddWithValue("$modified", "2026-07-18 12:00:00.123");
            insertManifest.Parameters.AddWithValue("$created", "2026-07-18 11:00:00.456");
            insertManifest.Parameters.AddWithValue("$filesystem", "18446744073709551615");
            insertManifest.Parameters.AddWithValue("$file", "9223372036854775808");
            Assert.Equal(1, insertManifest.ExecuteNonQuery());
        }
        using (var readManifest = connection.CreateCommand())
        {
            readManifest.CommandText = """
                SELECT fileSizeBytes, modificationDate, creationDate, fileSystemNumber, fileNumber
                FROM parser_checkpoint_files
                WHERE provider = 'codex' AND path = 'C:\Users\Test\.codex\rollout.jsonl'
                """;
            using var reader = readManifest.ExecuteReader();
            Assert.True(reader.Read());
            Assert.Equal(4096L, reader.GetInt64(0));
            Assert.Equal("2026-07-18 12:00:00.123", reader.GetString(1));
            Assert.Equal("2026-07-18 11:00:00.456", reader.GetString(2));
            Assert.Equal("18446744073709551615", reader.GetString(3));
            Assert.Equal("9223372036854775808", reader.GetString(4));
        }
        using (var duplicateManifest = connection.CreateCommand())
        {
            duplicateManifest.CommandText = """
                INSERT INTO parser_checkpoint_files (provider, path)
                VALUES ('codex', 'C:\Users\Test\.codex\rollout.jsonl')
                """;
            SqliteException error = Assert.Throws<SqliteException>(() => duplicateManifest.ExecuteNonQuery());
            Assert.Equal(19, error.SqliteErrorCode);
        }
        WriteEvidence("fresh-install", profile.DatabasePath, report, null);
    }

    [Fact]
    public void CleanProfile_Reopen_PreservesCheckpointDataAndExactV56Marker()
    {
        using var profile = TestProfile.Create();

        WindowsStorageProvisioningReport first = WindowsStorageDevHost.InitializeRuntime().Report!;
        string firstConfig = File.ReadAllText(profile.Configuration.ConfigFilePath);
        string firstJournal = File.ReadAllText(first.JournalPath);
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        using (var connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!))
        {
            using var seed = connection.CreateCommand();
            seed.CommandText = """
                INSERT INTO parser_checkpoints (
                    provider, checkpointToken, lastProcessedFilePath, lastProcessedAt, version
                ) VALUES (
                    'codex', 'watermark-17', 'C:\Users\Test\.codex\rollout.jsonl',
                    '2026-07-18 12:00:00.123', 3
                );
                INSERT INTO parser_checkpoint_files (
                    provider, path, fileSizeBytes, modificationDate, creationDate,
                    fileSystemNumber, fileNumber
                ) VALUES (
                    'codex', 'C:\Users\Test\.codex\rollout.jsonl', 4096,
                    '2026-07-18 12:00:00.123', '2026-07-18 11:00:00.456',
                    '18446744073709551615', '9223372036854775808'
                );
                """;
            Assert.Equal(2, seed.ExecuteNonQuery());
        }

        WindowsStorageProvisioningReport second = WindowsStorageDevHost.InitializeRuntime().Report!;

        Assert.False(second.Created);
        Assert.Equal(first.DatabasePath, second.DatabasePath);
        Assert.Equal(ExpectedSchemaEndpoint, second.SchemaEndpoint);
        Assert.Equal(ExpectedMigrationCount, second.MigrationCount);
        Assert.Equal(firstConfig, File.ReadAllText(profile.Configuration.ConfigFilePath));
        Assert.Contains("\"state\": \"complete\"", firstJournal, StringComparison.Ordinal);
        Assert.Contains("\"state\": \"complete\"", File.ReadAllText(second.JournalPath), StringComparison.Ordinal);
        using (var reopened = SqlCipherConnection.Open(profile.DatabasePath, passphrase!))
        {
            Assert.Equal(ExpectedSchemaEndpoint, SqlCipherConnection.ReadMigrationEndpoint(reopened));
            Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(reopened));
            AssertV56CheckpointSchema(reopened);
            using var read = reopened.CreateCommand();
            read.CommandText = """
                SELECT c.checkpointToken, c.lastProcessedFilePath, c.lastProcessedAt, c.version,
                       f.fileSizeBytes, f.modificationDate, f.creationDate,
                       f.fileSystemNumber, f.fileNumber
                FROM parser_checkpoints AS c
                JOIN parser_checkpoint_files AS f ON f.provider = c.provider
                WHERE c.provider = 'codex'
                  AND f.path = 'C:\Users\Test\.codex\rollout.jsonl'
                """;
            using var reader = read.ExecuteReader();
            Assert.True(reader.Read());
            Assert.Equal("watermark-17", reader.GetString(0));
            Assert.Equal("C:\\Users\\Test\\.codex\\rollout.jsonl", reader.GetString(1));
            Assert.Equal("2026-07-18 12:00:00.123", reader.GetString(2));
            Assert.Equal(3L, reader.GetInt64(3));
            Assert.Equal(4096L, reader.GetInt64(4));
            Assert.Equal("2026-07-18 12:00:00.123", reader.GetString(5));
            Assert.Equal("2026-07-18 11:00:00.456", reader.GetString(6));
            Assert.Equal("18446744073709551615", reader.GetString(7));
            Assert.Equal("9223372036854775808", reader.GetString(8));
            Assert.False(reader.Read());
        }
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
            TokenUsageWriteSeam.WriteTokenUsage(connection, new TokenUsageRecord
            {
                Id = "usage-old",
                Provider = "claude",
                SessionId = "session-old",
                ProjectName = "Archive",
                Model = "claude-sonnet-4",
                InputTokens = 4,
                OutputTokens = 6,
                TotalTokens = 10,
                Cost = 0.50,
                StartTime = "2026-05-01 12:00:00.000",
                EndTime = "2026-05-01 12:00:01.000",
                CreatedAt = "2026-05-01 12:00:01.000",
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
            Assert.Equal(40, TokenUsageReadSeam.SumTotalTokens(connection));
        }

        var summary = WindowsStorageDevHost.LoadDashboardUsageSummary(
            DashboardUsageWindow.ThisMonth,
            new DateTimeOffset(2026, 7, 15, 12, 0, 0, TimeSpan.Zero));
        Assert.True(summary.HasData);
        Assert.Equal(30, summary.TotalTokens);
        Assert.Equal(1, summary.SessionCount);
        Assert.Equal(0.12, summary.TotalCostUsd, 3);

        var allTime = WindowsStorageDevHost.LoadDashboardUsageSummary(
            DashboardUsageWindow.AllTime,
            new DateTimeOffset(2026, 7, 15, 12, 0, 0, TimeSpan.Zero));
        Assert.Equal(40, allTime.TotalTokens);
        Assert.Equal(2, allTime.SessionCount);
        Assert.Equal(0.62, allTime.TotalCostUsd, 3);
        WriteEvidence("generated-db-write-seams", profile.DatabasePath, WindowsStorageDevHost.Status.Report, null);
    }

    [Fact]
    public void WrongKey_ProducesDistinctRecoveryState_WithRetryArchiveResetAndRevealLog()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        profile.Configuration.UpdateAndSave(model =>
        {
            model.SqlCipherDbPath = profile.DatabasePath;
            model.SqlCipherPassphrase = "WrongBase64Key-000000000000000000000000000=";
        });
        WindowsStorageDevHost.ConfigureForTests(profile.Configuration, profile.DatabasePath);

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.False(status.IsReady);
        AssertRecovery(status, WindowsStorageFailureKind.WrongKey);
        WriteEvidence("wrong-key-recovery", profile.DatabasePath, null, status.RecoveryState);
    }

    [Fact]
    public void PlaintextSqlCipherEnvironment_DoesNotOverrideInjectedProtectedConfiguration()
    {
        using var profile = TestProfile.Create();
        Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PATH", Path.Combine(profile.Root, "env.sqlite"));
        Environment.SetEnvironmentVariable("OPENBURNBAR_SQLCIPHER_PASSPHRASE", "env-passphrase-must-not-win");

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.True(status.IsReady);
        Assert.Equal(profile.DatabasePath, status.Report!.DatabasePath);
        Assert.Equal("protected-generated:openburnbar.windows.sqlcipher.passphrase", status.Report.KeyProvenance);
        Assert.False(File.Exists(Path.Combine(profile.Root, "env.sqlite")));
    }

    [Fact]
    public void CorruptDatabase_ProducesDistinctRecoveryState_AndArchiveResetCreatesExactV56Schema()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        File.WriteAllText(profile.DatabasePath, "not a SQLCipher database");

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        Assert.False(status.IsReady);
        AssertRecovery(status, WindowsStorageFailureKind.CorruptDatabase);
        Assert.True(File.Exists(status.RecoveryState!.RedactedLogPath));

        WindowsStorageArchiveResult archive = WindowsStorageDevHost.ArchiveAndReset(confirmDestructiveReset: true);
        Assert.True(Directory.Exists(archive.ArchiveDirectory));
        Assert.True(File.Exists(archive.ArchivedDatabasePath));
        Assert.True(SqlCipherConnection.FileIsEncrypted(profile.DatabasePath));
        Assert.Equal(ExpectedSchemaEndpoint, archive.NewDatabase.SchemaEndpoint);
        Assert.Equal(ExpectedMigrationCount, archive.NewDatabase.MigrationCount);
        using var reset = SqlCipherConnection.Open(profile.DatabasePath, passphrase!);
        Assert.Equal(ExpectedSchemaEndpoint, SqlCipherConnection.ReadMigrationEndpoint(reset));
        Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(reset));
        AssertV56CheckpointSchema(reset);
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

    [Fact]
    public void AcceptedOlderEndpoint_MissingLaterColumn_NeverGetsFalselyStampedAsV56()
    {
        using var profile = TestProfile.Create();
        WindowsStorageDevHost.InitializeRuntime();
        var (_, passphrase) = WindowsStorageDevHost.ResolveCredentials();
        using (var connection = SqlCipherConnection.Open(profile.DatabasePath, passphrase!))
        {
            using var regressToV48 = connection.CreateCommand();
            regressToV48.CommandText = """
                ALTER TABLE token_usage DROP COLUMN parentRequestID;
                DELETE FROM grdb_migrations
                WHERE rowid > (
                    SELECT rowid FROM grdb_migrations
                    WHERE identifier = 'v48_conversation_fts_orphan_repair'
                );
                """;
            regressToV48.ExecuteNonQuery();
            Assert.Equal("v48_conversation_fts_orphan_repair", SqlCipherConnection.ReadMigrationEndpoint(connection));
            Assert.Equal(48, SqlCipherConnection.ReadMigrationCount(connection));
            Assert.DoesNotContain(ReadTableInfo(connection, "token_usage"), column => column.Name == "parentRequestID");
        }

        WindowsStorageRuntimeStatus status = WindowsStorageDevHost.InitializeRuntime();

        using var reopened = SqlCipherConnection.Open(profile.DatabasePath, passphrase!);
        if (!status.IsReady)
        {
            AssertRecovery(status, WindowsStorageFailureKind.UnsupportedSchema);
            Assert.Equal("v48_conversation_fts_orphan_repair", SqlCipherConnection.ReadMigrationEndpoint(reopened));
            Assert.Equal(48, SqlCipherConnection.ReadMigrationCount(reopened));
            return;
        }

        Assert.Equal(ExpectedSchemaEndpoint, status.Report!.SchemaEndpoint);
        Assert.Equal(ExpectedMigrationCount, status.Report.MigrationCount);
        Assert.Equal(ExpectedSchemaEndpoint, SqlCipherConnection.ReadMigrationEndpoint(reopened));
        Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(reopened));
        Assert.Contains(ReadTableInfo(reopened, "token_usage"), column =>
            column == ("parentRequestID", "TEXT", 0, 0));
    }

    private static void AssertV56CheckpointSchema(SqliteConnection connection)
    {
        (string Name, string Type, int NotNull, int PrimaryKeyPosition)[] expectedCheckpoints =
        [
            ("provider", "TEXT", 0, 1),
            ("checkpointToken", "TEXT", 1, 0),
            ("lastProcessedFilePath", "TEXT", 0, 0),
            ("lastProcessedAt", "DATETIME", 1, 0),
            ("version", "INTEGER", 1, 0),
        ];
        (string Name, string Type, int NotNull, int PrimaryKeyPosition)[] expectedManifest =
        [
            ("provider", "TEXT", 1, 1),
            ("path", "TEXT", 1, 2),
            ("fileSizeBytes", "INTEGER", 0, 0),
            ("modificationDate", "DATETIME", 0, 0),
            ("creationDate", "DATETIME", 0, 0),
            ("fileSystemNumber", "TEXT", 0, 0),
            ("fileNumber", "TEXT", 0, 0),
        ];

        Assert.Equal(expectedCheckpoints, ReadTableInfo(connection, "parser_checkpoints"));
        Assert.Equal(expectedManifest, ReadTableInfo(connection, "parser_checkpoint_files"));
    }

    private static (string Name, string Type, int NotNull, int PrimaryKeyPosition)[] ReadTableInfo(
        SqliteConnection connection,
        string tableName)
    {
        var columns = new List<(string Name, string Type, int NotNull, int PrimaryKeyPosition)>();
        using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA table_info({tableName})";
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            columns.Add((reader.GetString(1), reader.GetString(2), reader.GetInt32(3), reader.GetInt32(5)));
        }

        return columns.ToArray();
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
        public string Root => _root;

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
