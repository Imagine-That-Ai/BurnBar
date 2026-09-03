using System;
using System.IO;
using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// End-to-end proof that the ported <see cref="SqlCipherSwitcherProfileStore"/> — the real
/// encrypted backing that retires <see cref="SwitcherSampleData"/> — round-trips the whole
/// <see cref="ISwitcherProfileStore"/> contract against the COMMITTED byte-compat fixture (the
/// same Mac-produced encrypted DB the macOS validator opens), including browser/CLI metadata
/// mapping, enum raw-value parity, active-profile + per-provider drain targets, reorder, delete,
/// and normalized-name uniqueness. Writes go to a fresh COPY of the fixture so the committed
/// bytes are never mutated; a capstone assertion proves the schema hash is unchanged (no
/// accidental migration — the file stays reopenable on Mac).
///
/// Runs today on the macOS authoring host via <c>dotnet test</c>; the SAME managed assemblies
/// ship on Windows (native SQLCipher per-RID from the bundle).
/// </summary>
public sealed class SqlCipherSwitcherProfileStoreTests
{
    private static readonly DateTimeOffset Clock = new(2026, 7, 4, 12, 0, 0, TimeSpan.Zero);

    private static SqlCipherSwitcherProfileStore OpenStore(string working, Func<DateTimeOffset>? now = null) =>
        new(working, SqlCipherParameters.FixturePassphrase, now ?? (() => Clock));

    [Fact]
    public void Create_ThenFetchAll_MapsBrowserAndCliRecords_WithMacReadableJson()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using (var store = OpenStore(working))
            {
                store.Create(BrowserRecord("s-browser", "Default", "openai"));
                store.Create(CliRecord("s-cli", SwitcherCLIProfileType.Codex, "work@imagine-that.ai"));
            }

            using (var store = OpenStore(working))
            {
                var all = store.FetchAllProfiles();
                var browser = all.Single(p => p.Id == "s-browser");
                var cli = all.Single(p => p.Id == "s-cli");

                Assert.Equal(SwitcherProfileTargetKind.Browser, browser.TargetKind);
                Assert.Equal(SwitcherBrowserProfileType.Chrome, browser.BrowserType);
                Assert.NotNull(browser.BrowserMetadata);
                Assert.Equal("Default", browser.BrowserMetadata!.ProfileIdentifier);
                Assert.Equal("openai", browser.BrowserMetadata.ProviderIdentifier);
                Assert.Null(browser.CliMetadata);

                Assert.Equal(SwitcherProfileTargetKind.Cli, cli.TargetKind);
                Assert.Equal(SwitcherCLIProfileType.Codex, cli.CliType);
                Assert.NotNull(cli.CliMetadata);
                Assert.Equal("work@imagine-that.ai", cli.CliMetadata!.AccountDescription);
                Assert.Null(cli.BrowserMetadata);
            }

            // The stored browser JSON uses Swift-compatible camelCase keys so the Mac reader
            // (JSONDecoder over SwitcherBrowserProfileMetadata) decodes it unchanged.
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                using var command = connection.CreateCommand();
                command.CommandText = "SELECT browserMetadataJSON FROM switcher_profiles WHERE id='s-browser'";
                string json = command.ExecuteScalar()?.ToString() ?? string.Empty;
                Assert.Contains("\"profileIdentifier\":\"Default\"", json);
                Assert.Contains("\"providerIdentifier\":\"openai\"", json);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void Create_AssignsSequentialSortKeys_AndStampsTimestamps()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using var store = OpenStore(working);
            var first = store.Create(CliRecord("a", SwitcherCLIProfileType.Claude));
            var second = store.Create(CliRecord("b", SwitcherCLIProfileType.Codex));

            Assert.Equal(0, first.SortKey);
            Assert.Equal(1, second.SortKey);
            Assert.Equal(Clock, first.CreatedAt);
            Assert.Equal(Clock, first.UpdatedAt);
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void Update_PreservesSortKeyAndCreatedAt_BumpsUpdatedAt()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            var created = Clock;
            var edited = Clock.AddHours(3);

            using (var store = OpenStore(working, () => created))
            {
                store.Create(CliRecord("edit-me", SwitcherCLIProfileType.Claude, "before@x.ai"));
            }

            using (var store = OpenStore(working, () => edited))
            {
                var target = store.FetchAllProfiles().Single(p => p.Id == "edit-me");
                var updated = store.Update(target with
                {
                    CliMetadata = new SwitcherCLIProfileMetadata(DisplayLabel: "after", AccountDescription: "after@x.ai"),
                });

                Assert.Equal(target.SortKey, updated.SortKey);
                Assert.Equal(created, updated.CreatedAt);
                Assert.Equal(edited, updated.UpdatedAt);
            }

            using (var store = OpenStore(working))
            {
                var reread = store.FetchAllProfiles().Single(p => p.Id == "edit-me");
                Assert.Equal("after@x.ai", reread.CliMetadata!.AccountDescription);
                Assert.Equal(created, reread.CreatedAt);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void GlobalActiveProfile_RoundTrips_AndClearsOnNull()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using (var store = OpenStore(working))
            {
                store.Create(CliRecord("act", SwitcherCLIProfileType.Claude));
                store.SetActiveProfile("act");
            }

            using (var store = OpenStore(working))
            {
                Assert.Equal("act", store.FetchActiveProfileState().ActiveProfileId);
                store.SetActiveProfile((string?)null);
            }

            using (var store = OpenStore(working))
            {
                Assert.Null(store.FetchActiveProfileState().ActiveProfileId);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void PerProviderDrainTargets_RoundTrip()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using (var store = OpenStore(working))
            {
                store.Create(CliRecord("cli-a", SwitcherCLIProfileType.Claude));
                store.Create(CliRecord("cli-b", SwitcherCLIProfileType.Codex));
                store.SetActiveProfile("cli-a", "claude");
                store.SetActiveProfile("cli-b", "openai");
            }

            using (var store = OpenStore(working))
            {
                Assert.Equal("cli-a", store.FetchActiveProfileId("claude"));
                Assert.Equal("cli-b", store.FetchActiveProfileId("openai"));

                var map = store.FetchAllActiveDrainTargets();
                Assert.Equal("cli-a", map["claude"]);
                Assert.Equal("cli-b", map["openai"]);

                store.SetActiveProfile((string?)null, "openai");
            }

            using (var store = OpenStore(working))
            {
                Assert.Null(store.FetchActiveProfileId("openai"));
                Assert.Equal("cli-a", store.FetchActiveProfileId("claude"));
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void DeleteProfile_RemovesRecord_AndClearsGlobalActive()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using (var store = OpenStore(working))
            {
                store.Create(CliRecord("keep", SwitcherCLIProfileType.Claude));
                store.Create(CliRecord("drop", SwitcherCLIProfileType.Codex));
                store.SetActiveProfile("drop");
            }

            using (var store = OpenStore(working))
            {
                store.DeleteProfile("drop");
            }

            using (var store = OpenStore(working))
            {
                Assert.DoesNotContain(store.FetchAllProfiles(), p => p.Id == "drop");
                Assert.Contains(store.FetchAllProfiles(), p => p.Id == "keep");
                Assert.Null(store.FetchActiveProfileState().ActiveProfileId);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void ReorderProfiles_ReordersById()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using (var store = OpenStore(working))
            {
                store.Create(CliRecord("p1", SwitcherCLIProfileType.Claude));
                store.Create(CliRecord("p2", SwitcherCLIProfileType.Codex));
                store.Create(CliRecord("p3", SwitcherCLIProfileType.Claude));
                store.ReorderProfiles(new[] { "p3", "p1", "p2" });
            }

            using (var store = OpenStore(working))
            {
                var order = store.FetchAllProfiles().Select(p => p.Id).ToArray();
                Assert.Equal(new[] { "p3", "p1", "p2" }, order);
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void ExistsProfileWithNormalizedName_MatchesCaseAndWhitespaceInsensitively()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using var store = OpenStore(working);
            store.Create(CliRecord("named", SwitcherCLIProfileType.Claude, label: "Claude Code Personal"));

            Assert.True(store.ExistsProfileWithNormalizedName("  claude   code   personal ", excludingId: null));
            Assert.False(store.ExistsProfileWithNormalizedName("Claude Code Personal", excludingId: "named"));
            Assert.False(store.ExistsProfileWithNormalizedName("Something Else", excludingId: null));
        }
        finally
        {
            Cleanup(working);
        }
    }

    [Fact]
    public void RealStore_PersistsAcrossReopen_ProvingItBacksTheSurface_NotSampleData()
    {
        string working = CopyFixtureToWorkingFile();
        try
        {
            using (var store = OpenStore(working))
            {
                store.Create(CliRecord("persisted", SwitcherCLIProfileType.Codex, "real@imagine-that.ai"));
            }

            // A brand-new store instance over the same encrypted file sees the real row —
            // and none of the SwitcherSampleData dev-host ids leak into the real backing.
            using (var store = OpenStore(working))
            {
                var ids = store.FetchAllProfiles().Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
                Assert.Contains("persisted", ids);
                foreach (var sample in SwitcherSampleData.DevHostProfiles())
                {
                    Assert.DoesNotContain(sample.Id, ids);
                }
            }

            // Capstone: the schema hash is unchanged after every store write — no accidental
            // migration, so the file remains byte-compatible + reopenable on Mac.
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                Assert.Equal(
                    "81ebde43292fa3e38674f0f28da94f41a6a9488488c87fdb60250e88b328695e",
                    SqlCipherConnection.ComputeSchemaHash(connection));
            }
        }
        finally
        {
            Cleanup(working);
        }
    }

    // ── record factories ────────────────────────────────────────────────────────

    private static SwitcherProfileRecord BrowserRecord(string id, string profileIdentifier, string provider) => new(
        Id: id,
        TargetKind: SwitcherProfileTargetKind.Browser,
        SortKey: 0,
        BrowserType: SwitcherBrowserProfileType.Chrome,
        BrowserMetadata: new SwitcherBrowserProfileMetadata(
            ProfileIdentifier: profileIdentifier,
            DisplayLabel: "Chrome",
            AccountEmail: "a@b.com",
            ProviderIdentifier: provider),
        CreatedAt: Clock,
        UpdatedAt: Clock);

    private static SwitcherProfileRecord CliRecord(
        string id,
        SwitcherCLIProfileType type,
        string? account = null,
        string? label = null) => new(
        Id: id,
        TargetKind: SwitcherProfileTargetKind.Cli,
        SortKey: 0,
        CliType: type,
        CliMetadata: new SwitcherCLIProfileMetadata(DisplayLabel: label, AccountDescription: account),
        CreatedAt: Clock,
        UpdatedAt: Clock);

    // ── fixture plumbing (walk up to the committed DBByteCompat fixture, copy to temp) ──

    private static string CopyFixtureToWorkingFile()
    {
        string source = FixturePath();
        string working = Path.Combine(Path.GetTempPath(), $"obb-switcherstore-{Guid.NewGuid():N}.sqlcipher");
        File.Copy(source, working, overwrite: true);
        return working;
    }

    private static void Cleanup(string path)
    {
        foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            try { File.Delete(path + suffix); } catch { /* best-effort */ }
        }
    }

    private static string FixturePath()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            string candidate = Path.Combine(dir.FullName, "AgentLensTests", "Fixtures", "DBByteCompat");
            if (File.Exists(Path.Combine(candidate, "openburnbar-db-compat-vector.json")))
            {
            var pinned = Path.Combine(candidate, "openburnbar-db-compat-v64.sqlcipher");
                if (File.Exists(pinned))
                {
                    return pinned;
                }

                string[] any = Directory.GetFiles(candidate, "*.sqlcipher");
                if (any.Length == 1)
                {
                    return any[0];
                }
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException(
            "Could not locate AgentLensTests/Fixtures/DBByteCompat by walking up from " + AppContext.BaseDirectory);
    }
}
