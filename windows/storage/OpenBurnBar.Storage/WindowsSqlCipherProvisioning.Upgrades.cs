using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;

namespace OpenBurnBar.Storage;

public sealed partial class WindowsSqlCipherProvisioner
{
    /// <summary>
    /// The ADDITIVE, in-place upgrade catalog: how a Windows database that already
    /// sits at an EARLIER endpoint reaches <see cref="CurrentMigrationEndpoint"/>
    /// without being archived and reset.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>SchemaStatements</c> is an <em>endpoint</em> schema — it describes what a
    /// FRESH database looks like at the current endpoint, and every statement is
    /// <c>IF NOT EXISTS</c>, so replaying it over an existing table adds nothing.
    /// A real user's profile is not fresh: it already has <c>token_usage</c>, so
    /// only an <c>ALTER TABLE</c> can give it a newly added column.
    /// </para>
    /// <para>
    /// Each step here is the C# peer of one Swift <c>DatabaseMigrator</c>
    /// registration, and it must stay semantically identical to it — same DDL,
    /// same backfill, same index. The steps are keyed by the migration identifier
    /// they stamp into <c>grdb_migrations</c>, so a database that is behind by N
    /// purely-additive migrations is caught up by replaying steps
    /// <c>N…endpoint</c> in order, inside ONE transaction.
    /// </para>
    /// <para>
    /// A migration with no entry here is deliberately NOT upgradable in place: the
    /// provisioner falls back to the <c>UnsupportedSchema</c> recovery surface
    /// (archive/reset) rather than guessing at a destructive or lossy rewrite.
    /// </para>
    /// </remarks>
    internal static readonly WindowsSchemaUpgradeStep[] AdditiveUpgradeSteps =
    {
        // v60_billing_kind — mirrors OpenBurnBarDatabase+DataMigrationV60.swift
        // (and its byte-identical AgentLens copy) statement for statement.
        new WindowsSchemaUpgradeStep(
            "v60_billing_kind",
            new[]
            {
                WindowsSchemaUpgradeStatement.AddColumn(
                    "token_usage",
                    "billingKind",
                    "ALTER TABLE token_usage ADD COLUMN billingKind TEXT NOT NULL DEFAULT 'unknown'"),
                WindowsSchemaUpgradeStatement.Always(BillingKindBackfillSql),
                WindowsSchemaUpgradeStatement.Always(
                    "CREATE INDEX IF NOT EXISTS token_usage_billing_kind_time_idx ON token_usage(billingKind, startTime)"),
            }),

        // v61_usage_memory — peer of OpenBurnBarDatabase+UsageMemoryMigrations.swift.
        // Every v61 statement targets chat-memory-authority tables
        // (memory_usage_candidates, memory_salience, memory_links,
        // memory_extraction_jobs), which Windows fresh-install provisioning
        // deliberately does not create (see budgets/migrator-parity-baseline.json),
        // so there is no DDL to replay here: the step only advances the stamp,
        // keeping an upgraded database identical to a freshly provisioned one.
        new WindowsSchemaUpgradeStep(
            "v61_usage_memory",
            Array.Empty<WindowsSchemaUpgradeStatement>()),

        // v62_war_room_originator — peer of OpenBurnBarDatabase+DataMigrationV62.swift.
        // Both columns are nullable with no backfill: a row written before the War
        // Room existed has no originator, and inventing one would attribute work to
        // a machine that never claimed it.
        new WindowsSchemaUpgradeStep(
            "v62_war_room_originator",
            new[]
            {
                WindowsSchemaUpgradeStatement.AddColumn(
                    "token_usage",
                    "originatorKind",
                    "ALTER TABLE token_usage ADD COLUMN originatorKind TEXT"),
                WindowsSchemaUpgradeStatement.AddColumn(
                    "token_usage",
                    "originatorRef",
                    "ALTER TABLE token_usage ADD COLUMN originatorRef TEXT"),
                WindowsSchemaUpgradeStatement.Always(
                    "CREATE INDEX IF NOT EXISTS token_usage_originator_time_idx ON token_usage(originatorKind, startTime)"),
            }),

        // v63_standing_orders — peer of OpenBurnBarDatabase+StandingOrderMigrations.swift.
        new WindowsSchemaUpgradeStep(
            "v63_standing_orders",
            new[]
            {
                WindowsSchemaUpgradeStatement.Always(StandingOrdersTableSql),
                WindowsSchemaUpgradeStatement.Always(
                    "CREATE INDEX IF NOT EXISTS standing_orders_enabled_fired_idx ON standing_orders(isEnabled, lastFiredAt)"),
            }),

        // v64_token_usage_start_time_index — peer of
        // OpenBurnBarDatabase+CommandBoardIndexMigration.swift.
        new WindowsSchemaUpgradeStep(
            "v64_token_usage_start_time_index",
            new[]
            {
                WindowsSchemaUpgradeStatement.Always(
                    "CREATE INDEX IF NOT EXISTS token_usage_start_time_idx ON token_usage(startTime)"),
            }),

        // v65_memory_quarantine_bodies — peer of
        // OpenBurnBarDatabase+CommandBoardIndexMigration.swift.
        new WindowsSchemaUpgradeStep(
            "v65_memory_quarantine_bodies",
            new[]
            {
                WindowsSchemaUpgradeStatement.Always(MemoryQuarantineBodiesTableSql),
                WindowsSchemaUpgradeStatement.Always(
                    "CREATE INDEX IF NOT EXISTS memory_quarantine_bodies_project_idx ON memory_quarantine_bodies(project_id)"),
            }),
    };

    internal const string MemoryQuarantineBodiesTableSql =
        """
        CREATE TABLE IF NOT EXISTS memory_quarantine_bodies (
            memory_id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """;

    /// <summary>
    /// The standing-orders table, kept identical to the fresh-install statement in
    /// <c>WindowsSqlCipherProvisioning.Schema.cs</c> so an upgraded database and a
    /// freshly provisioned one describe the same table.
    /// </summary>
    internal const string StandingOrdersTableSql =
        """
        CREATE TABLE IF NOT EXISTS standing_orders (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            instruction TEXT NOT NULL,
            cadenceKind TEXT NOT NULL,
            cadenceMinutes INTEGER,
            cadenceHour INTEGER,
            cadenceMinute INTEGER,
            cadenceWeekday INTEGER,
            targetBodyId TEXT,
            requiredCapabilities TEXT NOT NULL DEFAULT '',
            isEnabled BOOLEAN NOT NULL DEFAULT 1,
            lastFiredAt DATETIME,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        )
        """;

    /// <summary>
    /// The v60 billing-provenance backfill, kept semantically byte-for-byte with
    /// <c>OpenBurnBarDatabase.billingKindBackfillSQL</c> (Swift/macOS + Linux) and
    /// with <see cref="BillingProvenance.Classify"/> (the Windows write-time
    /// stamp). All three must classify a row identically — a disagreement would
    /// corrupt the money-vs-imputed split permanently, so
    /// <c>BillingKindBackfillMatchesClassifierTests</c> proves it by running this
    /// exact SQL against every combination the classifier distinguishes.
    /// </summary>
    internal const string BillingKindBackfillSql =
        """
        UPDATE token_usage
        SET billingKind = CASE
                WHEN usageSource IN ('billing_api', 'daemon') THEN 'api'
                WHEN usageSource = 'provider_log' AND provider IN (
                    'Claude Code', 'Codex', 'Copilot', 'Cursor', 'Cursor Agent',
                    'Factory', 'Junie', 'Windsurf', 'Warp'
                ) THEN 'subscription'
                WHEN usageSource = 'provider_log' AND provider IN (
                    'Aider', 'Hermes', 'DeepSeek', 'OpenAI', 'xAI'
                ) THEN 'api'
                ELSE 'unknown'
            END
        WHERE billingKind = 'unknown'
        """;

    /// <summary>
    /// Upgrade <paramref name="connection"/> in place when its applied-migration
    /// history is a strict PREFIX of the endpoint history and every missing
    /// identifier has a registered additive step. Returns <c>false</c> — without
    /// touching the database — for anything else (reordered, unknown, or newer
    /// history), which the caller turns into <c>UnsupportedSchema</c>.
    /// </summary>
    private static bool TryUpgradeExistingSchemaToEndpoint(
        SqliteConnection connection,
        IReadOnlyList<string> applied,
        string journalPath,
        string databasePath,
        string keyProvenance,
        string fingerprint)
    {
        // Constant drift (count bumped without the identifier) must never be
        // "fixed" by silently upgrading a user's file.
        if (AppliedMigrationIdentifiers.Length != CurrentMigrationCount)
        {
            return false;
        }

        // A migrations table with no stamps is malformed, not "behind": a real
        // database is stamped in the same transaction that creates its schema.
        if (applied.Count == 0 || applied.Count >= AppliedMigrationIdentifiers.Length)
        {
            return false;
        }

        for (int index = 0; index < applied.Count; index += 1)
        {
            if (!string.Equals(applied[index], AppliedMigrationIdentifiers[index], StringComparison.Ordinal))
            {
                return false;
            }
        }

        var steps = new List<WindowsSchemaUpgradeStep>();
        for (int index = applied.Count; index < AppliedMigrationIdentifiers.Length; index += 1)
        {
            WindowsSchemaUpgradeStep? step = FindUpgradeStep(AppliedMigrationIdentifiers[index]);
            if (step is null)
            {
                return false;
            }

            steps.Add(step);
        }

        // Journal BEFORE mutating: a crash mid-upgrade must surface as
        // InterruptedMigration (retryable) rather than as a silent partial state.
        // The upgrade itself is one transaction, so the retry always starts from
        // a consistent boundary.
        WriteJournal(journalPath, "upgrading", databasePath, keyProvenance, fingerprint, null);

        using (var transaction = connection.BeginTransaction())
        {
            foreach (WindowsSchemaUpgradeStep step in steps)
            {
                foreach (WindowsSchemaUpgradeStatement statement in step.Statements)
                {
                    if (statement.SkipWhenColumnExists
                        && ColumnExists(connection, transaction, statement.Table!, statement.Column!))
                    {
                        continue;
                    }

                    using var command = connection.CreateCommand();
                    command.Transaction = transaction;
                    command.CommandText = statement.Sql;
                    command.ExecuteNonQuery();
                }

                using var stamp = connection.CreateCommand();
                stamp.Transaction = transaction;
                stamp.CommandText = "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES ($identifier)";
                stamp.Parameters.AddWithValue("$identifier", step.Identifier);
                stamp.ExecuteNonQuery();
            }

            transaction.Commit();
        }

        AppendLog(
            RedactedLogPath(databasePath),
            "upgraded-in-place-to-" + steps[^1].Identifier,
            databasePath,
            keyProvenance,
            null);
        return true;
    }

    private static WindowsSchemaUpgradeStep? FindUpgradeStep(string identifier)
    {
        foreach (WindowsSchemaUpgradeStep step in AdditiveUpgradeSteps)
        {
            if (string.Equals(step.Identifier, identifier, StringComparison.Ordinal))
            {
                return step;
            }
        }

        return null;
    }

    /// <summary>
    /// The <c>ensureColumn</c>-style guard: true when <paramref name="column"/> is
    /// already present on <paramref name="table"/>. Makes a half-applied upgrade
    /// (column added, stamp not yet written) replayable instead of fatal.
    /// </summary>
    private static bool ColumnExists(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string table,
        string column)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT 1 FROM pragma_table_info($table) WHERE name = $column LIMIT 1";
        command.Parameters.AddWithValue("$table", table);
        command.Parameters.AddWithValue("$column", column);
        return command.ExecuteScalar() is not null;
    }

    /// <summary>One statement of an additive upgrade step.</summary>
    internal sealed record WindowsSchemaUpgradeStatement
    {
        private WindowsSchemaUpgradeStatement(string sql, string? table, string? column)
        {
            Sql = sql;
            Table = table;
            Column = column;
        }

        internal string Sql { get; }

        internal string? Table { get; }

        internal string? Column { get; }

        internal bool SkipWhenColumnExists => Table is not null && Column is not null;

        /// <summary>A statement that always runs (backfills, <c>IF NOT EXISTS</c> DDL).</summary>
        internal static WindowsSchemaUpgradeStatement Always(string sql) => new(sql, null, null);

        /// <summary>
        /// An <c>ALTER TABLE … ADD COLUMN</c> that is skipped when the column is
        /// already present — SQLite has no <c>ADD COLUMN IF NOT EXISTS</c>.
        /// </summary>
        internal static WindowsSchemaUpgradeStatement AddColumn(string table, string column, string sql) =>
            new(sql, table, column);
    }

    /// <summary>
    /// One migration's worth of additive, in-place upgrade work, plus the
    /// identifier it stamps into <c>grdb_migrations</c> once applied.
    /// </summary>
    internal sealed record WindowsSchemaUpgradeStep(
        string Identifier,
        WindowsSchemaUpgradeStatement[] Statements);
}
