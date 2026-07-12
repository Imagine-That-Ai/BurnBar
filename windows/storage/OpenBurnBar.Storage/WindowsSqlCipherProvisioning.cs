using System;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

public sealed partial class WindowsSqlCipherProvisioner
{
    public const string CurrentMigrationEndpoint = "v54_provider_quota_snapshots";
    public const long CurrentMigrationCount = 55;
    public const long CurrentUserVersion = 0;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    public WindowsStorageProvisioningReport EnsureReady(
        string databasePath,
        string passphrase,
        string keyProvenance,
        bool retryInterruptedMigration = false,
        WindowsStorageProvisioningFault? fault = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(passphrase);
        ArgumentException.ThrowIfNullOrWhiteSpace(keyProvenance);
        SqlCipherParameters.EnsureProviderInitialized();
        ThrowInjectedFault(databasePath, fault);

        string journalPath = JournalPath(databasePath);
        string logPath = RedactedLogPath(databasePath);
        string fingerprint = ComputeKeyFingerprint(passphrase);
        bool created = !File.Exists(databasePath);
        bool retriedInterrupted = false;

        if (HasInterruptedJournal(journalPath))
        {
            if (!retryInterruptedMigration)
            {
                throw Recovery(databasePath, WindowsStorageFailureKind.InterruptedMigration, null);
            }

            retriedInterrupted = true;
            AppendLog(logPath, "retry-interrupted-migration", databasePath, keyProvenance, null);
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(databasePath) ?? ".");
            if (created)
            {
                WriteJournal(journalPath, "prepared", databasePath, keyProvenance, fingerprint, null);
            }

            using SqliteConnection connection = OpenReadWriteCreate(databasePath, passphrase);
            VerifyKeyFingerprint(databasePath, passphrase);
            ValidateExistingSchemaBeforeMigration(connection, databasePath);
            ApplySchema(connection, journalPath, databasePath, keyProvenance, fingerprint);
            SqlCipherConnection.AssertPinnedParams(connection, out string cipherVersion);
            string endpoint = SqlCipherConnection.ReadMigrationEndpoint(connection);
            long migrationCount = SqlCipherConnection.ReadMigrationCount(connection);
            long userVersion = SqlCipherConnection.ReadUserVersion(connection);

            if (!string.Equals(endpoint, CurrentMigrationEndpoint, StringComparison.Ordinal)
                || migrationCount > CurrentMigrationCount
                || userVersion > CurrentUserVersion)
            {
                throw Recovery(databasePath, WindowsStorageFailureKind.UnsupportedSchema, null);
            }

            string schemaHash = SqlCipherConnection.ComputeSchemaHash(connection);
            var report = new WindowsStorageProvisioningReport(
                databasePath,
                journalPath,
                logPath,
                keyProvenance,
                CurrentPathOwner(databasePath),
                cipherVersion,
                endpoint,
                migrationCount,
                userVersion,
                schemaHash,
                created,
                retriedInterrupted);
            WriteJournal(journalPath, "complete", databasePath, keyProvenance, fingerprint, report);
            WriteKeyProvenance(databasePath, keyProvenance, fingerprint);
            AppendLog(logPath, created ? "provisioned" : "opened", databasePath, keyProvenance, report);
            return report;
        }
        catch (WindowsStorageProvisioningException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw Classify(databasePath, passphrase, ex);
        }
    }

    public WindowsStorageArchiveResult ArchiveAndReset(
        string databasePath,
        string passphrase,
        string keyProvenance,
        bool confirmDestructiveReset)
    {
        if (!confirmDestructiveReset)
        {
            throw new InvalidOperationException("Archive/reset requires explicit destructive confirmation.");
        }

        string archiveDirectory = Path.Combine(
            Path.GetDirectoryName(databasePath) ?? ".",
            "storage-archive-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmssfff", CultureInfo.InvariantCulture));
        Directory.CreateDirectory(archiveDirectory);

        string archivedDatabase = Path.Combine(archiveDirectory, Path.GetFileName(databasePath));
        foreach (string suffix in new[] { "", "-wal", "-shm", "-journal", ".windows-migration-journal.json", ".key-provenance.json", ".recovery.log" })
        {
            string source = databasePath + suffix;
            if (!File.Exists(source))
            {
                continue;
            }

            string target = suffix.Length == 0
                ? archivedDatabase
                : Path.Combine(archiveDirectory, Path.GetFileName(databasePath) + suffix);
            File.Move(source, target, overwrite: true);
        }

        var report = EnsureReady(databasePath, passphrase, keyProvenance, retryInterruptedMigration: true);
        return new WindowsStorageArchiveResult(archiveDirectory, archivedDatabase, report);
    }

    public static string ComputeKeyFingerprint(string passphrase)
    {
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes("OpenBurnBar.Windows.SqlCipherKey.v1:" + passphrase));
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    private static SqliteConnection OpenReadWriteCreate(string databasePath, string passphrase)
    {
        SqlCipherParameters.ValidatePassphrase(passphrase);
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        };
        var connection = new SqliteConnection(builder.ConnectionString);
        try
        {
            connection.Open();
            SqlCipherParameters.KeyAndPin(connection, passphrase);
            Execute(connection, "PRAGMA foreign_keys = ON;");
            Execute(connection, "PRAGMA journal_mode = WAL;");
            Execute(connection, "SELECT count(*) FROM sqlite_master;");
            return connection;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    private static void ApplySchema(
        SqliteConnection connection,
        string journalPath,
        string databasePath,
        string keyProvenance,
        string fingerprint)
    {
        WriteJournal(journalPath, "applying", databasePath, keyProvenance, fingerprint, null);
        using var transaction = connection.BeginTransaction();
        foreach (string sql in SchemaStatements)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = sql;
            command.ExecuteNonQuery();
        }

        using (var clear = connection.CreateCommand())
        {
            clear.Transaction = transaction;
            clear.CommandText = "DELETE FROM grdb_migrations";
            clear.ExecuteNonQuery();
        }

        foreach (string identifier in AppliedMigrationIdentifiers)
        {
            using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText = "INSERT INTO grdb_migrations(identifier) VALUES ($identifier)";
            insert.Parameters.AddWithValue("$identifier", identifier);
            insert.ExecuteNonQuery();
        }

        using (var version = connection.CreateCommand())
        {
            version.Transaction = transaction;
            version.CommandText = "PRAGMA user_version = 0;";
            version.ExecuteNonQuery();
        }

        transaction.Commit();
    }

    private static void ValidateExistingSchemaBeforeMigration(SqliteConnection connection, string databasePath)
    {
        if (!TableExists(connection, "grdb_migrations"))
        {
            if (HasApplicationTables(connection))
            {
                throw Recovery(databasePath, WindowsStorageFailureKind.UnsupportedSchema, null);
            }
            return;
        }

        long count = SqlCipherConnection.ReadMigrationCount(connection);
        string endpoint = count == 0 ? string.Empty : SqlCipherConnection.ReadMigrationEndpoint(connection);
        long userVersion = SqlCipherConnection.ReadUserVersion(connection);
        if (count > CurrentMigrationCount
            || userVersion > CurrentUserVersion
            || (endpoint.Length > 0
                && !Array.Exists(
                    AppliedMigrationIdentifiers,
                    identifier => string.Equals(identifier, endpoint, StringComparison.Ordinal))))
        {
            throw Recovery(databasePath, WindowsStorageFailureKind.UnsupportedSchema, null);
        }
    }

    private static bool HasApplicationTables(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT 1
            FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%'
              AND type IN ('table', 'index', 'view', 'trigger')
            LIMIT 1
            """;
        return command.ExecuteScalar() is not null;
    }

    private static bool TableExists(SqliteConnection connection, string name)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = $name LIMIT 1";
        command.Parameters.AddWithValue("$name", name);
        using var reader = command.ExecuteReader();
        return reader.Read();
    }

    private static readonly string[] SchemaStatements =
    {
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
        """
        CREATE TABLE IF NOT EXISTS token_usage (
            id TEXT NOT NULL PRIMARY KEY,
            provider TEXT NOT NULL,
            sessionId TEXT NOT NULL,
            projectName TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL,
            inputTokens INTEGER NOT NULL DEFAULT 0,
            outputTokens INTEGER NOT NULL DEFAULT 0,
            cacheCreationTokens INTEGER NOT NULL DEFAULT 0,
            cacheReadTokens INTEGER NOT NULL DEFAULT 0,
            reasoningTokens INTEGER NOT NULL DEFAULT 0,
            totalTokens INTEGER NOT NULL DEFAULT 0,
            cost REAL NOT NULL DEFAULT 0,
            startTime TEXT NOT NULL DEFAULT '',
            endTime TEXT NOT NULL DEFAULT '',
            createdAt TEXT NOT NULL DEFAULT '',
            usageSource TEXT NOT NULL DEFAULT 'measured',
            sourceDeviceId TEXT,
            sourceDeviceName TEXT,
            isRemote INTEGER NOT NULL DEFAULT 0,
            providerID TEXT,
            providerAccountID TEXT,
            providerAccountLabel TEXT,
            providerAccountSource TEXT,
            provenanceMethod TEXT NOT NULL DEFAULT 'api',
            provenanceConfidence TEXT NOT NULL DEFAULT 'exact',
            estimatorVersion TEXT NOT NULL DEFAULT 'windows-provisioner-v1',
            parentRequestID TEXT
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS token_usage_unique_session_model_idx ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, ''))",
        "CREATE INDEX IF NOT EXISTS token_usage_created_at_idx ON token_usage(createdAt DESC)",
        "CREATE INDEX IF NOT EXISTS token_usage_session_idx ON token_usage(sessionId)",
        """
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT NOT NULL PRIMARY KEY,
            provider TEXT NOT NULL,
            sessionId TEXT NOT NULL,
            projectName TEXT NOT NULL DEFAULT '',
            inferredTaskTitle TEXT NOT NULL DEFAULT '',
            fullText TEXT NOT NULL DEFAULT '',
            indexedAt TEXT,
            messageCount INTEGER NOT NULL DEFAULT 0,
            deletedAt TEXT,
            workingDirectory TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS conversations_indexed_at_idx ON conversations(indexedAt DESC)",
        // Mirrors the Mac endpoint schema exactly (v6_fts_standalone_triggers):
        // a STANDALONE FTS5 table kept in sync by the conversations_ai/ad/au
        // triggers below. It must NOT be declared with content='conversations'
        // (external content): plain trigger DELETEs corrupt external-content
        // FTS5 indexes, and the column order (inferredTaskTitle first) is part
        // of the byte-compat contract — snippet(conversations_fts, 1, …) reads
        // column 1 = fullText. Checked by scripts/check-migrator-parity.mjs.
        "CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(inferredTaskTitle, fullText, tokenize='porter unicode61')",
        """
        CREATE TRIGGER IF NOT EXISTS conversations_ai AFTER INSERT ON conversations BEGIN
            INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
            VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS conversations_ad AFTER DELETE ON conversations BEGIN
            DELETE FROM conversations_fts WHERE rowid = old.rowid;
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS conversations_au AFTER UPDATE ON conversations BEGIN
            DELETE FROM conversations_fts WHERE rowid = old.rowid;
            INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
            VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS chat_threads (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT,
            backend TEXT NOT NULL DEFAULT 'cli',
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            projectPath TEXT,
            sessionId TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_threads_updated_idx ON chat_threads(updatedAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT NOT NULL PRIMARY KEY,
            threadId TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            cliUsed TEXT,
            transcriptPiecesJSON TEXT,
            attachmentsJSON TEXT,
            errorKind TEXT,
            errorMessage TEXT,
            retrievalStateJSON TEXT,
            modelUsed TEXT,
            backend TEXT,
            isStreaming INTEGER NOT NULL DEFAULT 0,
            metadata TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_messages_thread_time_idx ON chat_messages(threadId, timestamp)",
        "CREATE INDEX IF NOT EXISTS chat_messages_timestamp_idx ON chat_messages(timestamp DESC)",
        """
        CREATE TABLE IF NOT EXISTS chat_stream_failures (
            id TEXT NOT NULL PRIMARY KEY,
            threadId TEXT NOT NULL,
            messageId TEXT,
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            createdAt TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_stream_failures_thread_idx ON chat_stream_failures(threadId, createdAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS chat_retrieval_events (
            id TEXT NOT NULL PRIMARY KEY,
            threadId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            kind TEXT NOT NULL,
            detail TEXT NOT NULL,
            createdAt TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_retrieval_events_message_idx ON chat_retrieval_events(messageId, createdAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS budget_rules (
            id TEXT NOT NULL PRIMARY KEY,
            scope TEXT NOT NULL,
            identifier TEXT,
            providerID TEXT,
            accountID TEXT,
            projectName TEXT,
            label TEXT,
            amountUSD REAL NOT NULL,
            period TEXT NOT NULL,
            behavior TEXT NOT NULL,
            fallbackCredentialIDsJSON TEXT,
            pausedUntil TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            syncedAt TEXT,
            sourceDeviceID TEXT,
            isEnabled INTEGER NOT NULL DEFAULT 1
        )
        """,
        "CREATE INDEX IF NOT EXISTS budget_rules_enabled_idx ON budget_rules(isEnabled, scope)",
        """
        CREATE TABLE IF NOT EXISTS budget_events (
            id TEXT NOT NULL PRIMARY KEY,
            ruleID TEXT NOT NULL,
            kind TEXT NOT NULL,
            source TEXT,
            amountAtEvent REAL NOT NULL,
            limitAtEvent REAL NOT NULL,
            detailJSON TEXT,
            occurredAt TEXT NOT NULL,
            syncedAt TEXT,
            sourceDeviceID TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS budget_events_rule_time_idx ON budget_events(ruleID, occurredAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS switcher_profiles (
            id TEXT NOT NULL PRIMARY KEY,
            targetKind TEXT NOT NULL,
            browserType TEXT,
            browserMetadataJSON TEXT,
            cliType TEXT,
            cliMetadataJSON TEXT,
            sortKey INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS switcher_profiles_sort_idx ON switcher_profiles(sortKey, createdAt)",
        """
        CREATE TABLE IF NOT EXISTS switcher_active_profile (
            activeProfileID TEXT,
            providerID TEXT,
            updatedAt TEXT NOT NULL
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS switcher_active_provider_idx ON switcher_active_profile(COALESCE(providerID, ''))",
        """
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT NOT NULL,
            updatedAt REAL NOT NULL
        )
        """,
    };

    private static void VerifyKeyFingerprint(string databasePath, string passphrase)
    {
        string? expected = ReadKeyProvenance(databasePath)?.KeyFingerprint;
        if (expected is null)
        {
            return;
        }

        string actual = ComputeKeyFingerprint(passphrase);
        if (!string.Equals(expected, actual, StringComparison.Ordinal))
        {
            throw Recovery(databasePath, WindowsStorageFailureKind.WrongKey, null);
        }
    }

    private static void WriteKeyProvenance(string databasePath, string keyProvenance, string keyFingerprint)
    {
        var metadata = new KeyProvenanceDocument
        {
            DatabasePath = databasePath,
            KeyProvenance = keyProvenance,
            KeyFingerprint = keyFingerprint,
            WrittenAt = DateTimeOffset.UtcNow,
        };
        AtomicWrite(databasePath + ".key-provenance.json", JsonSerializer.Serialize(metadata, JsonOptions));
    }

    private static KeyProvenanceDocument? ReadKeyProvenance(string databasePath)
    {
        string path = databasePath + ".key-provenance.json";
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<KeyProvenanceDocument>(File.ReadAllText(path), JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    private static bool HasInterruptedJournal(string journalPath)
    {
        if (!File.Exists(journalPath))
        {
            return false;
        }

        try
        {
            var document = JsonSerializer.Deserialize<MigrationJournalDocument>(File.ReadAllText(journalPath), JsonOptions);
            return document is not null && !string.Equals(document.State, "complete", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return true;
        }
    }

    private static WindowsStorageProvisioningException Classify(string databasePath, string passphrase, Exception exception)
    {
        if (exception is UnauthorizedAccessException)
        {
            return Recovery(databasePath, WindowsStorageFailureKind.AccessDenied, exception);
        }

        if (exception is IOException io && IsLikelyFullDisk(io))
        {
            return Recovery(databasePath, WindowsStorageFailureKind.FullDisk, exception);
        }

        if (exception is IOException)
        {
            return Recovery(databasePath, WindowsStorageFailureKind.LockedFile, exception);
        }

        if (exception is SqliteException sqlite)
        {
            if (sqlite.SqliteErrorCode == 5 || sqlite.SqliteErrorCode == 6)
            {
                return Recovery(databasePath, WindowsStorageFailureKind.LockedFile, exception);
            }

            if (sqlite.SqliteErrorCode == 13)
            {
                return Recovery(databasePath, WindowsStorageFailureKind.FullDisk, exception);
            }

            if (sqlite.SqliteErrorCode == 14)
            {
                return Recovery(databasePath, WindowsStorageFailureKind.AccessDenied, exception);
            }
        }

        if (ReadKeyProvenance(databasePath)?.KeyFingerprint is { } expected
            && !string.Equals(expected, ComputeKeyFingerprint(passphrase), StringComparison.Ordinal))
        {
            return Recovery(databasePath, WindowsStorageFailureKind.WrongKey, exception);
        }

        return Recovery(databasePath, WindowsStorageFailureKind.CorruptDatabase, exception);
    }

    private static bool IsLikelyFullDisk(IOException exception)
    {
        const int HResultDiskFull = unchecked((int)0x80070070);
        const int HResultHandleDiskFull = unchecked((int)0x80070027);
        return exception.HResult == HResultDiskFull
            || exception.HResult == HResultHandleDiskFull
            || exception.Message.Contains("disk full", StringComparison.OrdinalIgnoreCase)
            || exception.Message.Contains("not enough space", StringComparison.OrdinalIgnoreCase);
    }

    private static WindowsStorageProvisioningException Recovery(
        string databasePath,
        WindowsStorageFailureKind kind,
        Exception? exception)
    {
        string logPath = RedactedLogPath(databasePath);
        AppendLog(logPath, "recovery-" + kind, databasePath, "redacted", null, exception);
        var state = new WindowsStorageRecoveryState(
            kind,
            TitleFor(kind),
            MessageFor(kind),
            ActionsFor(kind),
            databasePath,
            JournalPath(databasePath),
            logPath);
        return new WindowsStorageProvisioningException(state, exception);
    }

    private static void ThrowInjectedFault(string databasePath, WindowsStorageProvisioningFault? fault)
    {
        if (fault is null)
        {
            return;
        }

        Exception ex = fault.Kind switch
        {
            WindowsStorageProvisioningFaultKind.LockedFile => new IOException(fault.Message ?? "Injected locked file fault."),
            WindowsStorageProvisioningFaultKind.FullDisk => new IOException(fault.Message ?? "Injected disk full fault."),
            WindowsStorageProvisioningFaultKind.AccessDenied => new UnauthorizedAccessException(fault.Message ?? "Injected access denied fault."),
            WindowsStorageProvisioningFaultKind.InterruptedMigration => Recovery(databasePath, WindowsStorageFailureKind.InterruptedMigration, null),
            _ => new IOException(fault.Message ?? "Injected storage fault."),
        };

        if (ex is WindowsStorageProvisioningException storage)
        {
            throw storage;
        }

        throw Classify(databasePath, string.Empty, ex);
    }

    private static void WriteJournal(
        string journalPath,
        string state,
        string databasePath,
        string keyProvenance,
        string keyFingerprint,
        WindowsStorageProvisioningReport? report)
    {
        var document = new MigrationJournalDocument
        {
            State = state,
            DatabasePath = databasePath,
            PathOwner = CurrentPathOwner(databasePath),
            KeyProvenance = keyProvenance,
            KeyFingerprint = keyFingerprint,
            TargetEndpoint = CurrentMigrationEndpoint,
            TargetMigrationCount = CurrentMigrationCount,
            SchemaEndpoint = report?.SchemaEndpoint,
            SchemaHash = report?.SchemaHash,
            CipherVersion = report?.CipherVersion,
            CompletedAt = string.Equals(state, "complete", StringComparison.Ordinal) ? DateTimeOffset.UtcNow : null,
        };
        AtomicWrite(journalPath, JsonSerializer.Serialize(document, JsonOptions));
    }

    private static string CurrentPathOwner(string databasePath)
    {
        try
        {
            string user = Environment.UserName;
            string? domain = Environment.UserDomainName;
            return string.IsNullOrWhiteSpace(domain) ? user : domain + "\\" + user;
        }
        catch
        {
            return "unknown";
        }
    }

    private static void AppendLog(
        string logPath,
        string eventName,
        string databasePath,
        string keyProvenance,
        WindowsStorageProvisioningReport? report,
        Exception? exception = null)
    {
        string? dir = Path.GetDirectoryName(logPath);
        if (!string.IsNullOrWhiteSpace(dir))
        {
            Directory.CreateDirectory(dir);
        }

        string line = JsonSerializer.Serialize(new
        {
            at = DateTimeOffset.UtcNow,
            eventName,
            databasePath,
            keyProvenance,
            schemaEndpoint = report?.SchemaEndpoint,
            migrationCount = report?.MigrationCount,
            pathOwner = report?.PathOwner,
            errorType = exception?.GetType().Name,
            errorMessage = exception is null ? null : Redact(exception.Message),
        });
        File.AppendAllText(logPath, line + Environment.NewLine, Encoding.UTF8);
    }

    private static string Redact(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        return value.Replace(Environment.UserName, "<user>", StringComparison.OrdinalIgnoreCase);
    }

    private static void Execute(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static void AtomicWrite(string path, string contents)
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
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best-effort cleanup only.
        }
    }

    private sealed record MigrationJournalDocument
    {
        public int Version { get; init; } = 1;
        public string State { get; init; } = "prepared";
        public string DatabasePath { get; init; } = string.Empty;
        public string PathOwner { get; init; } = string.Empty;
        public string KeyProvenance { get; init; } = string.Empty;
        public string KeyFingerprint { get; init; } = string.Empty;
        public string TargetEndpoint { get; init; } = CurrentMigrationEndpoint;
        public long TargetMigrationCount { get; init; } = CurrentMigrationCount;
        public string? SchemaEndpoint { get; init; }
        public string? SchemaHash { get; init; }
        public string? CipherVersion { get; init; }
        public DateTimeOffset StartedAt { get; init; } = DateTimeOffset.UtcNow;
        public DateTimeOffset? CompletedAt { get; init; }
    }

    private sealed record KeyProvenanceDocument
    {
        public int Version { get; init; } = 1;
        public string DatabasePath { get; init; } = string.Empty;
        public string KeyProvenance { get; init; } = string.Empty;
        public string KeyFingerprint { get; init; } = string.Empty;
        public DateTimeOffset WrittenAt { get; init; }
    }
}
