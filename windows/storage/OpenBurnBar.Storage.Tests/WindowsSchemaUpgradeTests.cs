using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// The UPGRADE proof for an existing Windows profile.
///
/// <para>
/// <c>WindowsSqlCipherProvisioner.ApplySchema</c> replays an <em>endpoint</em>
/// schema built entirely from <c>IF NOT EXISTS</c> statements, so it cannot add a
/// column to a <c>token_usage</c> table that already exists. Before the additive
/// upgrade catalog, <c>ValidateExistingSchemaBeforeMigration</c> compared a real
/// user's database to the NEW endpoint constants and threw <c>UnsupportedSchema</c>
/// first — meaning every previously valid Windows profile was pushed into the
/// archive/reset recovery surface the moment a migration was added, instead of
/// receiving it.
/// </para>
/// <para>
/// These tests build a database at an EARLIER endpoint (v59_founder_lens, 60
/// migrations) the only honest way available off-Windows — provision the current
/// endpoint, then regress the v60 + v61 deltas back out of it — seed it with rows
/// a real user would have, and require that reopening it upgrades in place across
/// BOTH pending steps in one transaction: column added, index created, rows
/// backfilled with the shared CASE, the stamp-only v61 step applied, endpoint
/// advanced, and every pre-existing row still there.
/// </para>
/// </summary>
public sealed class WindowsSchemaUpgradeTests
{
    private const string PreviousEndpoint = "v59_founder_lens";
    private const long PreviousMigrationCount = 60;
    private const string CurrentEndpoint = "v65_memory_quarantine_bodies";
    private const long CurrentMigrationCount = 66;

    private const string Passphrase = "OBB-WinPort-SchemaUpgrade-Test-Key-0000000=";
    private const string KeyProvenance = "test-static:schema-upgrade";

    // ── The upgrade actually happens ────────────────────────────────────────────

    [Fact]
    public void ExistingDatabaseAtPreviousEndpoint_IsUpgradedInPlace_NotRejected()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        SeedUsageRows(profile.DatabasePath);
        RegressToPreviousEndpoint(profile.DatabasePath);
        AssertAtPreviousEndpoint(profile.DatabasePath);

        WindowsStorageProvisioningReport report =
            provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        Assert.Equal(CurrentEndpoint, report.SchemaEndpoint);
        Assert.Equal(CurrentMigrationCount, report.MigrationCount);
        Assert.False(report.Created);

        using var connection = SqlCipherConnection.Open(profile.DatabasePath, Passphrase);
        Assert.Equal(CurrentEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
        Assert.Equal(CurrentMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
        Assert.True(ColumnExists(connection, "token_usage", "billingKind"));
        Assert.True(IndexExists(connection, "token_usage_billing_kind_time_idx"));
        Assert.True(ColumnExists(connection, "memory_quarantine_bodies", "body"));
        Assert.True(IndexExists(connection, "memory_quarantine_bodies_project_idx"));

        // The user's rows are still their rows — an upgrade, not a reset.
        Assert.Equal(SeedRows.Count, ScalarLong(connection, "SELECT count(*) FROM token_usage"));
        Assert.Equal(
            4242,
            ScalarLong(connection, "SELECT totalTokens FROM token_usage WHERE id = 'seed-claude-code-provider-log'"));
    }

    [Fact]
    public void UpgradedDatabase_BackfillsEveryRow_WithTheSharedCaseLogic()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);
        SeedUsageRows(profile.DatabasePath);
        RegressToPreviousEndpoint(profile.DatabasePath);

        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        using var connection = SqlCipherConnection.Open(profile.DatabasePath, Passphrase);
        IReadOnlyDictionary<string, string> kinds = ReadBillingKinds(connection);
        foreach (SeedRow row in SeedRows)
        {
            Assert.Equal(
                BillingProvenance.Classify(row.Provider, row.UsageSource),
                kinds[row.Id]);
        }

        // Not vacuous: the seed spans all three buckets.
        Assert.Contains(BillingProvenance.Api, kinds.Values);
        Assert.Contains(BillingProvenance.Subscription, kinds.Values);
        Assert.Contains(BillingProvenance.Unknown, kinds.Values);
    }

    [Fact]
    public void UpgradedDatabase_HasTheSameEffectiveSchemaAsAFreshOne_AndReprovisioningIsANoOp()
    {
        using var fresh = TempProfile.Create();
        using var upgraded = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();

        provisioner.EnsureReady(fresh.DatabasePath, Passphrase, KeyProvenance);
        provisioner.EnsureReady(upgraded.DatabasePath, Passphrase, KeyProvenance);
        RegressToPreviousEndpoint(upgraded.DatabasePath);
        provisioner.EnsureReady(upgraded.DatabasePath, Passphrase, KeyProvenance);

        // The property that actually governs compatibility: identical columns
        // (name, type, NOT NULL, default, PK position) and identical indexes.
        // The sqlite_master DDL *text* legitimately differs — SQLite appends an
        // ALTERed column to the stored CREATE TABLE instead of re-emitting it
        // inline — which is exactly why a fresh Windows database and a
        // migrated Mac database have never shared a schema hash either.
        using (var freshConnection = SqlCipherConnection.Open(fresh.DatabasePath, Passphrase))
        using (var upgradedConnection = SqlCipherConnection.Open(upgraded.DatabasePath, Passphrase))
        {
            Assert.Equal(
                ReadTableInfo(freshConnection, "token_usage"),
                ReadTableInfo(upgradedConnection, "token_usage"));
            Assert.Equal(
                ReadIndexNames(freshConnection, "token_usage"),
                ReadIndexNames(upgradedConnection, "token_usage"));
            Assert.Equal(
                ReadTableInfo(freshConnection, "memory_quarantine_bodies"),
                ReadTableInfo(upgradedConnection, "memory_quarantine_bodies"));
            Assert.Equal(
                ReadIndexNames(freshConnection, "memory_quarantine_bodies"),
                ReadIndexNames(upgradedConnection, "memory_quarantine_bodies"));
        }

        // Re-running over an already-current database must be a no-op, not a
        // second ALTER (which SQLite would reject as a duplicate column).
        string hashAfterUpgrade;
        using (var connection = SqlCipherConnection.Open(upgraded.DatabasePath, Passphrase))
        {
            hashAfterUpgrade = SqlCipherConnection.ComputeSchemaHash(connection);
        }

        WindowsStorageProvisioningReport second =
            provisioner.EnsureReady(upgraded.DatabasePath, Passphrase, KeyProvenance);

        Assert.Equal(CurrentEndpoint, second.SchemaEndpoint);
        Assert.Equal(CurrentMigrationCount, second.MigrationCount);
        Assert.Equal(hashAfterUpgrade, second.SchemaHash);
    }

    [Fact]
    public void HalfAppliedUpgrade_ColumnPresentButUnstamped_CompletesInsteadOfFailing()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);
        SeedUsageRows(profile.DatabasePath);

        // Drop only the stamps: the v60 ALTER already landed. A naive replay would
        // die on "duplicate column name: billingKind"; the ensureColumn-style guard
        // has to skip it and finish the remaining work. The v61 stamp must go too —
        // history must stay a strict PREFIX for the upgrade path to engage.
        Execute(
            profile.DatabasePath,
            "DELETE FROM grdb_migrations WHERE identifier IN ('v60_billing_kind', 'v61_usage_memory', 'v62_war_room_originator', 'v63_standing_orders', 'v64_token_usage_start_time_index', 'v65_memory_quarantine_bodies')");

        WindowsStorageProvisioningReport report =
            provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        Assert.Equal(CurrentEndpoint, report.SchemaEndpoint);
        Assert.Equal(CurrentMigrationCount, report.MigrationCount);
    }

    [Fact]
    public void UpgradedDatabase_AcceptsWritesCarryingBillingProvenance()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);
        RegressToPreviousEndpoint(profile.DatabasePath);
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        using var connection = SqlCipherConnection.Open(profile.DatabasePath, Passphrase);
        TokenUsageWriteSeam.WriteTokenUsage(connection, new TokenUsageRecord
        {
            Id = "post-upgrade-write",
            Provider = "Claude Code",
            SessionId = "s-post-upgrade",
            ProjectName = "BurnBar",
            Model = "opus-4.8",
            StartTime = "2026-08-09 00:00:00.000",
            EndTime = "2026-08-09 00:01:00.000",
            CreatedAt = "2026-08-09 00:02:00.000",
            UsageSource = "provider_log",
        });

        Assert.Equal(
            BillingProvenance.Subscription,
            ReadBillingKinds(connection)["post-upgrade-write"]);
    }

    // ── The upgrade path does NOT weaken the rejection gate ─────────────────────

    [Fact]
    public void UnknownFutureMigration_IsStillRejectedAsUnsupportedSchema()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);
        Execute(profile.DatabasePath, "INSERT INTO grdb_migrations(identifier) VALUES ('v999_future_schema')");

        WindowsStorageProvisioningException error = Assert.Throws<WindowsStorageProvisioningException>(
            () => provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance));

        Assert.Equal(WindowsStorageFailureKind.UnsupportedSchema, error.RecoveryState.Kind);
        AssertEndpointUnchanged(profile.DatabasePath, "v999_future_schema", CurrentMigrationCount + 1);
    }

    [Fact]
    public void MigrationBehindTheEndpoint_WithNoRegisteredUpgradeStep_IsStillRejected()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        // Three migrations behind, and v59_founder_lens has no additive step: the
        // provisioner must refuse rather than invent one.
        RegressToPreviousEndpoint(profile.DatabasePath);
        Execute(profile.DatabasePath, "DELETE FROM grdb_migrations WHERE identifier = 'v59_founder_lens'");

        WindowsStorageProvisioningException error = Assert.Throws<WindowsStorageProvisioningException>(
            () => provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance));

        Assert.Equal(WindowsStorageFailureKind.UnsupportedSchema, error.RecoveryState.Kind);
        AssertEndpointUnchanged(profile.DatabasePath, "v58_ai_inbox", PreviousMigrationCount - 1);
    }

    [Fact]
    public void ReorderedMigrationHistory_IsStillRejected()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);
        RegressToPreviousEndpoint(profile.DatabasePath);
        // Same count, wrong history: a database from some other lineage.
        Execute(
            profile.DatabasePath,
            "UPDATE grdb_migrations SET identifier = 'v58_something_else' WHERE identifier = 'v58_ai_inbox'");

        WindowsStorageProvisioningException error = Assert.Throws<WindowsStorageProvisioningException>(
            () => provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance));

        Assert.Equal(WindowsStorageFailureKind.UnsupportedSchema, error.RecoveryState.Kind);
    }

    [Fact]
    public void NonZeroUserVersion_IsStillRejected()
    {
        using var profile = TempProfile.Create();
        var provisioner = new WindowsSqlCipherProvisioner();
        provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);
        RegressToPreviousEndpoint(profile.DatabasePath);
        Execute(profile.DatabasePath, "PRAGMA user_version = 7;");

        WindowsStorageProvisioningException error = Assert.Throws<WindowsStorageProvisioningException>(
            () => provisioner.EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance));

        Assert.Equal(WindowsStorageFailureKind.UnsupportedSchema, error.RecoveryState.Kind);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private sealed record SeedRow(string Id, string Provider, string UsageSource);

    /// <summary>
    /// One row per CASE arm the v60 backfill distinguishes, plus rows it must
    /// leave in the honest <c>unknown</c> bucket.
    /// </summary>
    private static readonly IReadOnlyList<SeedRow> SeedRows = new[]
    {
        new SeedRow("seed-claude-code-provider-log", "Claude Code", "provider_log"),
        new SeedRow("seed-codex-provider-log", "Codex", "provider_log"),
        new SeedRow("seed-cursor-agent-provider-log", "Cursor Agent", "provider_log"),
        new SeedRow("seed-warp-provider-log", "Warp", "provider_log"),
        new SeedRow("seed-openai-provider-log", "OpenAI", "provider_log"),
        new SeedRow("seed-hermes-provider-log", "Hermes", "provider_log"),
        new SeedRow("seed-xai-provider-log", "xAI", "provider_log"),
        new SeedRow("seed-anything-billing-api", "Gemini", "billing_api"),
        new SeedRow("seed-anything-daemon", "Gemini", "daemon"),
        new SeedRow("seed-claude-code-daemon", "Claude Code", "daemon"),
        new SeedRow("seed-unknown-harness-provider-log", "Unheard-Of Harness", "provider_log"),
        new SeedRow("seed-claude-code-in-app-chat", "Claude Code", "in_app_chat"),
        new SeedRow("seed-claude-code-cursor-bridge", "Claude Code", "cursor_bridge"),
        new SeedRow("seed-lowercase-provider-log", "claude code", "provider_log"),
    };

    /// <summary>Write the seed rows the way a pre-v60 build would have: no billingKind.</summary>
    private static void SeedUsageRows(string databasePath)
    {
        using var connection = SqlCipherConnection.Open(databasePath, Passphrase);
        using var transaction = connection.BeginTransaction();
        foreach (SeedRow row in SeedRows)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model, totalTokens, cost,
                    startTime, endTime, createdAt, usageSource
                ) VALUES (
                    $id, $provider, $sessionId, 'BurnBar', 'opus-4.8', 4242, 1.25,
                    '2026-08-01 00:00:00.000', '2026-08-01 00:01:00.000',
                    '2026-08-01 00:02:00.000', $usageSource
                )
                """;
            command.Parameters.AddWithValue("$id", row.Id);
            command.Parameters.AddWithValue("$provider", row.Provider);
            command.Parameters.AddWithValue("$sessionId", "session-" + row.Id);
            command.Parameters.AddWithValue("$usageSource", row.UsageSource);
            command.ExecuteNonQuery();
        }

        transaction.Commit();
    }

    /// <summary>
    /// Turn a current-endpoint database back into a genuine PREVIOUS-endpoint one
    /// by removing exactly the v60 delta (index, column, stamp) and the v61 stamp
    /// (the stamp-only step has no schema delta on Windows). This is the same
    /// technique the existing older-endpoint regression test uses; the provisioner
    /// can only create the current endpoint, so a real v59 file cannot be minted
    /// here any other way.
    /// </summary>
    private static void RegressToPreviousEndpoint(string databasePath)
    {
        Execute(
            databasePath,
            """
            DROP INDEX IF EXISTS token_usage_billing_kind_time_idx;
            ALTER TABLE token_usage DROP COLUMN billingKind;
            DROP INDEX IF EXISTS token_usage_originator_time_idx;
            DROP INDEX IF EXISTS token_usage_start_time_idx;
            ALTER TABLE token_usage DROP COLUMN originatorKind;
            ALTER TABLE token_usage DROP COLUMN originatorRef;
            DROP INDEX IF EXISTS standing_orders_enabled_fired_idx;
            DROP TABLE IF EXISTS standing_orders;
            DROP INDEX IF EXISTS memory_quarantine_bodies_project_idx;
            DROP TABLE IF EXISTS memory_quarantine_bodies;
            DELETE FROM grdb_migrations WHERE identifier IN ('v60_billing_kind', 'v61_usage_memory', 'v62_war_room_originator', 'v63_standing_orders', 'v64_token_usage_start_time_index', 'v65_memory_quarantine_bodies');
            """);
    }

    private static void AssertAtPreviousEndpoint(string databasePath)
    {
        using var connection = SqlCipherConnection.Open(databasePath, Passphrase);
        Assert.Equal(PreviousEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
        Assert.Equal(PreviousMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
        Assert.False(ColumnExists(connection, "token_usage", "billingKind"));
        Assert.False(IndexExists(connection, "token_usage_billing_kind_time_idx"));
        Assert.False(ColumnExists(connection, "token_usage", "originatorKind"));
        Assert.False(IndexExists(connection, "token_usage_start_time_idx"));
    }

    private static void AssertEndpointUnchanged(string databasePath, string endpoint, long count)
    {
        using var connection = SqlCipherConnection.Open(databasePath, Passphrase);
        Assert.Equal(endpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
        Assert.Equal(count, SqlCipherConnection.ReadMigrationCount(connection));
    }

    private static void Execute(string databasePath, string sql)
    {
        using var connection = SqlCipherConnection.Open(databasePath, Passphrase);
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private static IReadOnlyDictionary<string, string> ReadBillingKinds(SqliteConnection connection)
    {
        var kinds = new Dictionary<string, string>(StringComparer.Ordinal);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT id, billingKind FROM token_usage";
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            kinds[reader.GetString(0)] = reader.GetString(1);
        }

        return kinds;
    }

    private static bool ColumnExists(SqliteConnection connection, string table, string column)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM pragma_table_info($table) WHERE name = $column LIMIT 1";
        command.Parameters.AddWithValue("$table", table);
        command.Parameters.AddWithValue("$column", column);
        return command.ExecuteScalar() is not null;
    }

    private static (string Name, string Type, long NotNull, string Default, long PrimaryKey)[] ReadTableInfo(
        SqliteConnection connection,
        string table)
    {
        var columns = new List<(string, string, long, string, long)>();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT name, type, \"notnull\", COALESCE(dflt_value, ''), pk FROM pragma_table_info($table) ORDER BY cid";
        command.Parameters.AddWithValue("$table", table);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            columns.Add((
                reader.GetString(0),
                reader.GetString(1),
                reader.GetInt64(2),
                reader.GetString(3),
                reader.GetInt64(4)));
        }

        return columns.ToArray();
    }

    private static string[] ReadIndexNames(SqliteConnection connection, string table)
    {
        var names = new List<string>();
        using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = $table ORDER BY name";
        command.Parameters.AddWithValue("$table", table);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            names.Add(reader.GetString(0));
        }

        return names.ToArray();
    }

    private static bool IndexExists(SqliteConnection connection, string name)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = $name LIMIT 1";
        command.Parameters.AddWithValue("$name", name);
        return command.ExecuteScalar() is not null;
    }

    private static long ScalarLong(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar());
    }

}
