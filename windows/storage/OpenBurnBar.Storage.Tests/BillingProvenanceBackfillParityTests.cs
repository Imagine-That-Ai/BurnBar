using System;
using System.Collections.Generic;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// Three surfaces can decide a <c>token_usage</c> row's <c>billingKind</c>: the
/// macOS/Linux Swift classifier, the Windows <see cref="BillingProvenance"/>
/// classifier that stamps rows at write time, and the v60 SQL backfill that
/// classifies history. They must agree on EVERY row — a disagreement splits real
/// dollars from plan-covered value differently depending on which platform touched
/// the row last, and the resulting ledger cannot be repaired after the fact.
///
/// <para>
/// So this suite does not compare the classifier to a hand-written table of
/// expectations (which would only prove the table agrees with itself). It runs the
/// REAL backfill SQL — <c>WindowsSqlCipherProvisioner.BillingKindBackfillSql</c>,
/// the same constant the upgrade path executes, kept semantically identical to the
/// Swift <c>OpenBurnBarDatabase.billingKindBackfillSQL</c> — against a real
/// provisioned database holding one row per combination, and requires the SQL and
/// the classifier to return the same answer for each.
/// </para>
/// </summary>
public sealed class BillingProvenanceBackfillParityTests
{
    private const string Passphrase = "OBB-WinPort-BillingParity-Test-Key-00000000=";
    private const string KeyProvenance = "test-static:billing-parity";

    /// <summary>
    /// Every provider name the CASE distinguishes, plus names it must NOT special
    /// case (unrecognized harnesses, a differently-cased spelling, the empty
    /// string) so the "exact match" property is proven, not assumed.
    /// </summary>
    private static readonly string[] Providers =
    {
        "Claude Code", "Codex", "Copilot", "Cursor", "Cursor Agent",
        "Factory", "Junie", "Windsurf", "Warp",
        "Aider", "Hermes", "DeepSeek", "OpenAI", "xAI",
        "Gemini", "Kimi", "", "cursor", "CLAUDE CODE", "Unheard-Of Harness",
    };

    /// <summary>
    /// Every <c>UsageSource</c> raw value, plus values no enum case produces — a
    /// row written by an older or newer build, and the historical Windows column
    /// default (<c>measured</c>), which must classify as <c>unknown</c> rather
    /// than crash or land in a money bucket.
    /// </summary>
    private static readonly string[] UsageSources =
    {
        "provider_log", "in_app_chat", "cursor_bridge", "billing_api",
        "daemon", "unknown", "measured", "",
    };

    [Fact]
    public void BackfillSql_ClassifiesEveryCombination_ExactlyLikeTheWindowsClassifier()
    {
        using var profile = TempProfile.Create();
        new WindowsSqlCipherProvisioner().EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        var expected = new Dictionary<string, string>(StringComparer.Ordinal);
        using var connection = SqlCipherConnection.Open(profile.DatabasePath, Passphrase);
        using (var transaction = connection.BeginTransaction())
        {
            foreach (string usageSource in UsageSources)
            {
                foreach (string provider in Providers)
                {
                    string id = $"row|{usageSource}|{provider}";
                    Insert(connection, transaction, id, provider, usageSource);
                    expected[id] = BillingProvenance.Classify(provider, usageSource);
                }
            }

            transaction.Commit();
        }

        Execute(connection, WindowsSqlCipherProvisioner.BillingKindBackfillSql);

        IReadOnlyDictionary<string, string> actual = ReadBillingKinds(connection);
        Assert.Equal(expected.Count, actual.Count);
        foreach (KeyValuePair<string, string> pair in expected)
        {
            Assert.True(
                actual.TryGetValue(pair.Key, out string? kind),
                $"backfill produced no row for {pair.Key}");
            Assert.True(
                string.Equals(pair.Value, kind, StringComparison.Ordinal),
                $"SQL backfill and Windows classifier disagree for {pair.Key}: SQL={kind}, classifier={pair.Value}");
        }

        // Not vacuous: the matrix genuinely exercises all three buckets.
        Assert.Contains(BillingProvenance.Api, expected.Values);
        Assert.Contains(BillingProvenance.Subscription, expected.Values);
        Assert.Contains(BillingProvenance.Unknown, expected.Values);
    }

    [Fact]
    public void BackfillSql_LeavesAlreadyClassifiedRowsAlone()
    {
        using var profile = TempProfile.Create();
        new WindowsSqlCipherProvisioner().EnsureReady(profile.DatabasePath, Passphrase, KeyProvenance);

        using var connection = SqlCipherConnection.Open(profile.DatabasePath, Passphrase);
        // A row stamped `subscription` whose provider/usageSource would classify as
        // `api`: the backfill's WHERE billingKind = 'unknown' must not relitigate a
        // decision a writer already made.
        Insert(connection, null, "stamped", "OpenAI", "provider_log", BillingProvenance.Subscription);
        Execute(connection, WindowsSqlCipherProvisioner.BillingKindBackfillSql);

        Assert.Equal(BillingProvenance.Subscription, ReadBillingKinds(connection)["stamped"]);
    }

    private static void Insert(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        string id,
        string provider,
        string usageSource,
        string billingKind = BillingProvenance.Unknown)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO token_usage (
                id, provider, sessionId, projectName, model, totalTokens, cost,
                startTime, endTime, createdAt, usageSource, billingKind
            ) VALUES (
                $id, $provider, $sessionId, 'BurnBar', 'opus-4.8', 1, 0,
                '2026-08-01 00:00:00.000', '2026-08-01 00:01:00.000',
                '2026-08-01 00:02:00.000', $usageSource, $billingKind
            )
            """;
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$provider", provider);
        // The natural-key unique index is (provider, sessionId, model, …); give
        // every combination its own session so none of them collide.
        command.Parameters.AddWithValue("$sessionId", "session-" + id);
        command.Parameters.AddWithValue("$usageSource", usageSource);
        command.Parameters.AddWithValue("$billingKind", billingKind);
        command.ExecuteNonQuery();
    }

    private static void Execute(SqliteConnection connection, string sql)
    {
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
}
