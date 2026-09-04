using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.Storage.Tests;

/// <summary>
/// VAL-SWITCH-STORE — the account-switcher WRITE + MIGRATION round-trip proof.
///
/// The Windows peer of the macOS <c>SwitcherProfileStore</c> (GRDB migrations
/// <c>v32_switcher_profiles</c> + <c>v46_drain_target_per_provider</c>). Opens the
/// committed Mac-produced SQLCipher fixture with the pinned SQLCipher-4 params +
/// non-secret key, exercises <see cref="SwitcherProfileWriteSeam"/> CRUD against the
/// REAL <c>switcher_profiles</c> / <c>switcher_active_profile</c> tables, reopens the
/// file, and asserts every write round-trips AND the schema hash + migration marker +
/// <c>user_version</c> stay unchanged — proving a Windows switcher write leaves the
/// file byte-compatible and reopenable on Mac (schema-faithfulness + byte-compat).
///
/// This retires the "SwitcherSampleData is the only backing" gap: the real encrypted
/// store is now proven end-to-end against the same bytes the macOS validator opens.
/// </summary>
public sealed class SwitcherProfileWriteSeamRoundTripTests
{
    private const string FixtureName = "openburnbar-db-compat-v64.sqlcipher";

    // Ground-truth invariants of the committed byte-compat fixture (pinned in the
    // sibling TokenUsageWriteRoundTripTests, and regenerated together with it).
    // A switcher write must not move any of these.
    private const string ExpectedSchemaHash =
        "23af836877b33d1ad1f592c2a4ab2cff127daa2e2e0177dd4725827ada9d2184";
    private const string ExpectedMigrationEndpoint = "v66_agent_memory_bodies";
    private const long ExpectedMigrationCount = 67;
    private const long ExpectedUserVersion = 0;

    private static string FixtureSource =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", FixtureName);

    private static string CopyFixtureToWorkingFile()
    {
        Assert.True(File.Exists(FixtureSource), $"Committed fixture missing from test output: {FixtureSource}");
        string working = Path.Combine(Path.GetTempPath(), $"obb-switcherseam-{Guid.NewGuid():N}.sqlcipher");
        File.Copy(FixtureSource, working, overwrite: true);
        return working;
    }

    private static void Cleanup(string path)
    {
        foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            try { File.Delete(path + suffix); } catch { /* best-effort */ }
        }
    }

    private static SqliteConnection Open(string path) =>
        SqlCipherConnection.Open(path, SqlCipherParameters.FixturePassphrase);

    // ── Schema faithfulness ─────────────────────────────────────────────────────

    [Fact]
    public void CommittedFixture_CarriesSwitcherSchema_WithMacColumnSet()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using var connection = Open(working);

            var profileColumns = TableColumns(connection, "switcher_profiles");
            Assert.Equal(
                new[] { "browserMetadataJSON", "browserType", "cliMetadataJSON", "cliType", "createdAt", "id", "sortKey", "targetKind", "updatedAt" },
                profileColumns.OrderBy(c => c, StringComparer.Ordinal).ToArray());

            var activeColumns = TableColumns(connection, "switcher_active_profile");
            // v32 defined (activeProfileID, updatedAt); v46 added providerID.
            Assert.Contains("activeProfileID", activeColumns);
            Assert.Contains("updatedAt", activeColumns);
            Assert.Contains("providerID", activeColumns);
        }
        finally
        {
            Cleanup(working);
        }
    }

    // ── Profile CRUD round-trip + byte-compat ───────────────────────────────────

    [Fact]
    public void UpsertAndFetch_RoundTripsBrowserAndCliRows_AcrossReopen_PreservingByteCompat()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            string beforeHash;
            using (var connection = Open(working))
            {
                SqlCipherConnection.AssertPinnedParams(connection, out _);
                beforeHash = SqlCipherConnection.ComputeSchemaHash(connection);
                Assert.Equal(ExpectedSchemaHash, beforeHash);
                Assert.Equal(ExpectedMigrationEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
                Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
                Assert.Equal(ExpectedUserVersion, SqlCipherConnection.ReadUserVersion(connection));
            }

            var createdAt = new DateTimeOffset(2026, 7, 4, 12, 0, 0, TimeSpan.Zero);
            var updatedAt = new DateTimeOffset(2026, 7, 4, 12, 5, 0, TimeSpan.Zero);

            var browser = new SwitcherProfileRow(
                Id: "win-seam-browser-1",
                TargetKind: "browser",
                BrowserType: "chrome",
                BrowserMetadataJson: "{\"profileIdentifier\":\"Default\",\"displayLabel\":\"Chrome \\u00B7 ChatGPT\",\"accountEmail\":\"a@b.com\",\"providerIdentifier\":\"openai\"}",
                CliType: null,
                CliMetadataJson: null,
                SortKey: 0,
                CreatedAt: createdAt,
                UpdatedAt: updatedAt);

            var cli = new SwitcherProfileRow(
                Id: "win-seam-cli-1",
                TargetKind: "cli",
                BrowserType: null,
                BrowserMetadataJson: null,
                CliType: "codex",
                CliMetadataJson: "{\"displayLabel\":\"Codex \\u00B7 work\",\"accountDescription\":\"work@imagine-that.ai\"}",
                SortKey: 1,
                CreatedAt: createdAt,
                UpdatedAt: updatedAt);

            using (var connection = Open(working))
            {
                Assert.Equal(1, SwitcherProfileWriteSeam.UpsertProfile(connection, browser));
                Assert.Equal(1, SwitcherProfileWriteSeam.UpsertProfile(connection, cli));
            }

            using (var connection = Open(working))
            {
                var rows = SwitcherProfileWriteSeam.FetchAllProfiles(connection);
                var byId = rows.ToDictionary(r => r.Id, StringComparer.Ordinal);

                Assert.True(byId.ContainsKey("win-seam-browser-1"));
                Assert.True(byId.ContainsKey("win-seam-cli-1"));

                var b = byId["win-seam-browser-1"];
                Assert.Equal("browser", b.TargetKind);
                Assert.Equal("chrome", b.BrowserType);
                Assert.Contains("\"profileIdentifier\":\"Default\"", b.BrowserMetadataJson);
                Assert.Null(b.CliType);
                Assert.Null(b.CliMetadataJson);
                Assert.Equal(0, b.SortKey);
                Assert.Equal(createdAt, b.CreatedAt);
                Assert.Equal(updatedAt, b.UpdatedAt);

                var c = byId["win-seam-cli-1"];
                Assert.Equal("cli", c.TargetKind);
                Assert.Equal("codex", c.CliType);
                Assert.Contains("\"accountDescription\":\"work@imagine-that.ai\"", c.CliMetadataJson);
                Assert.Null(c.BrowserType);
                Assert.Null(c.BrowserMetadataJson);

                // Deterministic order: sortKey ASC (browser sortKey 0 before cli sortKey 1).
                int browserIndex = rows.Select((r, i) => (r, i)).First(x => x.r.Id == "win-seam-browser-1").i;
                int cliIndex = rows.Select((r, i) => (r, i)).First(x => x.r.Id == "win-seam-cli-1").i;
                Assert.True(browserIndex < cliIndex);

                // Byte-compat: no accidental migration/corruption from the writes.
                Assert.Equal(beforeHash, SqlCipherConnection.ComputeSchemaHash(connection));
                Assert.Equal(ExpectedMigrationEndpoint, SqlCipherConnection.ReadMigrationEndpoint(connection));
                Assert.Equal(ExpectedMigrationCount, SqlCipherConnection.ReadMigrationCount(connection));
                Assert.Equal(ExpectedUserVersion, SqlCipherConnection.ReadUserVersion(connection));
            }

            // Dates persisted as ISO-8601 'T'…'Z' text (the Mac ORDER BY oracle format).
            using (var connection = Open(working))
            {
                string stored = ScalarString(connection, "SELECT createdAt FROM switcher_profiles WHERE id='win-seam-browser-1'");
                Assert.StartsWith("2026-07-04T12:00:00", stored, StringComparison.Ordinal);
                Assert.EndsWith("Z", stored, StringComparison.Ordinal);
            }

            Assert.True(SqlCipherConnection.FileIsEncrypted(working), "File lost its encrypted header after a switcher write.");
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void UpsertProfile_OnConflictById_UpdatesInPlace_WithoutDuplicating()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var now = new DateTimeOffset(2026, 7, 4, 9, 0, 0, TimeSpan.Zero);
            var row = new SwitcherProfileRow(
                Id: "win-seam-upsert",
                TargetKind: "cli",
                BrowserType: null,
                BrowserMetadataJson: null,
                CliType: "claude",
                CliMetadataJson: "{\"displayLabel\":\"first\"}",
                SortKey: 3,
                CreatedAt: now,
                UpdatedAt: now);

            long before;
            using (var connection = Open(working))
            {
                before = ScalarLong(connection, "SELECT count(*) FROM switcher_profiles");
                SwitcherProfileWriteSeam.UpsertProfile(connection, row);
            }

            using (var connection = Open(working))
            {
                SwitcherProfileWriteSeam.UpsertProfile(
                    connection,
                    row with { CliMetadataJson = "{\"displayLabel\":\"second\"}", UpdatedAt = now.AddMinutes(10) });
            }

            using (var connection = Open(working))
            {
                Assert.Equal(before + 1, ScalarLong(connection, "SELECT count(*) FROM switcher_profiles"));
                var stored = SwitcherProfileWriteSeam.FetchAllProfiles(connection).Single(r => r.Id == "win-seam-upsert");
                Assert.Contains("second", stored.CliMetadataJson);
                Assert.Equal(now.AddMinutes(10), stored.UpdatedAt);
                // createdAt is preserved by the ON CONFLICT clause (it does not touch createdAt).
                Assert.Equal(now, stored.CreatedAt);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void ReorderProfiles_RewritesSortKeys_ToMatchRequestedOrder()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var now = new DateTimeOffset(2026, 7, 4, 9, 0, 0, TimeSpan.Zero);
            using (var connection = Open(working))
            {
                foreach (var (id, sort) in new[] { ("r-a", 0), ("r-b", 1), ("r-c", 2) })
                {
                    SwitcherProfileWriteSeam.UpsertProfile(connection, CliRow(id, sort, now));
                }
            }

            using (var connection = Open(working))
            {
                SwitcherProfileWriteSeam.ReorderProfiles(connection, new[] { "r-c", "r-a", "r-b" }, now.AddMinutes(1));
            }

            using (var connection = Open(working))
            {
                var order = SwitcherProfileWriteSeam.FetchAllProfiles(connection)
                    .Where(r => r.Id.StartsWith("r-", StringComparison.Ordinal))
                    .Select(r => r.Id)
                    .ToArray();
                Assert.Equal(new[] { "r-c", "r-a", "r-b" }, order);
                Assert.Equal(ExpectedSchemaHash, SqlCipherConnection.ComputeSchemaHash(connection));
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    // ── Active-profile + drain-target round-trip ────────────────────────────────

    [Fact]
    public void SetAndFetchGlobalActiveProfile_RoundTrips_AndClearsOnNull()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var now = new DateTimeOffset(2026, 7, 4, 10, 0, 0, TimeSpan.Zero);
            using (var connection = Open(working))
            {
                SwitcherProfileWriteSeam.UpsertProfile(connection, CliRow("active-1", 0, now));
                SwitcherProfileWriteSeam.SetGlobalActiveProfile(connection, "active-1", now);
            }

            using (var connection = Open(working))
            {
                var state = SwitcherProfileWriteSeam.FetchGlobalActiveState(connection);
                Assert.Equal("active-1", state.ActiveProfileId);

                SwitcherProfileWriteSeam.SetGlobalActiveProfile(connection, null, now.AddMinutes(1));
            }

            using (var connection = Open(working))
            {
                Assert.Null(SwitcherProfileWriteSeam.FetchGlobalActiveState(connection).ActiveProfileId);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void DrainTargets_PerProvider_RoundTrip_OverwriteAndClear()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var now = new DateTimeOffset(2026, 7, 4, 10, 0, 0, TimeSpan.Zero);
            using (var connection = Open(working))
            {
                SwitcherProfileWriteSeam.UpsertProfile(connection, CliRow("cli-claude", 0, now));
                SwitcherProfileWriteSeam.UpsertProfile(connection, CliRow("cli-codex", 1, now));
                SwitcherProfileWriteSeam.SetDrainTarget(connection, "claude", "cli-claude", now);
                SwitcherProfileWriteSeam.SetDrainTarget(connection, "openai", "cli-codex", now);
            }

            using (var connection = Open(working))
            {
                var map = SwitcherProfileWriteSeam.FetchDrainTargets(connection);
                Assert.Equal("cli-claude", map["claude"]);
                Assert.Equal("cli-codex", map["openai"]);

                // Overwrite the claude target; the global (providerID IS NULL) pointer is untouched.
                SwitcherProfileWriteSeam.SetDrainTarget(connection, "claude", "cli-codex", now.AddMinutes(1));
                // Clearing openai (null) removes only that provider row.
                SwitcherProfileWriteSeam.SetDrainTarget(connection, "openai", null, now.AddMinutes(1));
            }

            using (var connection = Open(working))
            {
                var map = SwitcherProfileWriteSeam.FetchDrainTargets(connection);
                Assert.Equal("cli-codex", map["claude"]);
                Assert.False(map.ContainsKey("openai"));
                Assert.Equal(ExpectedSchemaHash, SqlCipherConnection.ComputeSchemaHash(connection));
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void DeleteProfile_RemovesRow_AndClearsGlobalActivePointer()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var now = new DateTimeOffset(2026, 7, 4, 10, 0, 0, TimeSpan.Zero);
            using (var connection = Open(working))
            {
                SwitcherProfileWriteSeam.UpsertProfile(connection, CliRow("doomed", 0, now));
                SwitcherProfileWriteSeam.SetGlobalActiveProfile(connection, "doomed", now);
            }

            using (var connection = Open(working))
            {
                SwitcherProfileWriteSeam.DeleteProfile(connection, "doomed");
            }

            using (var connection = Open(working))
            {
                Assert.DoesNotContain(
                    SwitcherProfileWriteSeam.FetchAllProfiles(connection),
                    r => r.Id == "doomed");
                Assert.Null(SwitcherProfileWriteSeam.FetchGlobalActiveState(connection).ActiveProfileId);
                Assert.Equal(ExpectedSchemaHash, SqlCipherConnection.ComputeSchemaHash(connection));
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    private static SwitcherProfileRow CliRow(string id, int sortKey, DateTimeOffset now) => new(
        Id: id,
        TargetKind: "cli",
        BrowserType: null,
        BrowserMetadataJson: null,
        CliType: "claude",
        CliMetadataJson: "{\"displayLabel\":\"" + id + "\"}",
        SortKey: sortKey,
        CreatedAt: now,
        UpdatedAt: now);

    private static List<string> TableColumns(SqliteConnection connection, string table)
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA table_info({table})";
        var names = new List<string>();
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            names.Add(reader.GetString(reader.GetOrdinal("name")));
        }

        return names;
    }

    private static long ScalarLong(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(command.ExecuteScalar());
    }

    private static string ScalarString(SqliteConnection connection, string sql)
    {
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar()?.ToString() ?? string.Empty;
    }
}
