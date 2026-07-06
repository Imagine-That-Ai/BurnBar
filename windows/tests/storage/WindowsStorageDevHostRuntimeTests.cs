using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Budget;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.App.Storage;
using OpenBurnBar.Storage;
using Xunit;

namespace OpenBurnBar.App.Storage.Tests;

public sealed class WindowsStorageDevHostRuntimeTests
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";
    private const string SqlPathEnv = "OPENBURNBAR_SQLCIPHER_PATH";
    private const string SqlPassEnv = "OPENBURNBAR_SQLCIPHER_PASSPHRASE";

    [Fact]
    public async Task CreateBudgetRuleStore_without_credentials_and_without_sample_mode_starts_empty()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);

            IBudgetRuleStore store = WindowsStorageDevHost.CreateBudgetRuleStore(
                seedWhenInMemory: new[] { new BudgetRule { Id = "seed-1" } });
            IReadOnlyList<BudgetRule> rules = await store.FetchAllRulesAsync(includeDisabled: true);

            Assert.Empty(rules);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
        }
    }

    [Fact]
    public async Task CreateBudgetRuleStore_without_credentials_with_sample_mode_applies_seed()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);

            IBudgetRuleStore store = WindowsStorageDevHost.CreateBudgetRuleStore(
                seedWhenInMemory: new[] { new BudgetRule { Id = "seed-1" } });
            IReadOnlyList<BudgetRule> rules = await store.FetchAllRulesAsync(includeDisabled: true);

            Assert.Single(rules);
            Assert.Equal("seed-1", rules[0].Id);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
        }
    }

    [Fact]
    public void CreateSwitcherProfileStore_without_credentials_and_without_sample_mode_is_empty()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);

            ISwitcherProfileStore store = WindowsStorageDevHost.CreateSwitcherProfileStore();

            Assert.Empty(store.FetchAllProfiles());
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
        }
    }

    [Fact]
    public void CreateSwitcherProfileStore_without_credentials_with_sample_mode_seeds_profiles()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);

            ISwitcherProfileStore store = WindowsStorageDevHost.CreateSwitcherProfileStore();

            Assert.Equal(5, store.FetchAllProfiles().Count);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
        }
    }

    [Fact]
    public void LoadDashboardUsageSummary_without_sqlcipher_env_reports_no_data()
    {
        try
        {
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);

            var summary = WindowsStorageDevHost.LoadDashboardUsageSummary();

            Assert.False(summary.HasData);
            Assert.Equal(0, summary.SessionCount);
            Assert.Equal(0, summary.TotalTokens);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
        }
    }

    [Fact]
    public async Task CreateStores_with_unopenable_configured_database_fall_back_without_throwing()
    {
        string path = Path.Combine(Path.GetTempPath(), "obb-invalid-" + Guid.NewGuid().ToString("N") + ".sqlcipher");
        try
        {
            File.WriteAllText(path, "not a SQLCipher database");
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, path);
            Environment.SetEnvironmentVariable(SqlPassEnv, "ValidBase64Key-000=");

            IBudgetRuleStore budget = WindowsStorageDevHost.CreateBudgetRuleStore();
            ISwitcherProfileStore switcher = WindowsStorageDevHost.CreateSwitcherProfileStore();

            Assert.Empty(await budget.FetchAllRulesAsync(includeDisabled: true));
            Assert.Empty(switcher.FetchAllProfiles());
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    [Fact]
    public void LoadDashboardUsageSummary_with_unopenable_configured_database_reports_no_data()
    {
        string path = Path.Combine(Path.GetTempPath(), "obb-invalid-" + Guid.NewGuid().ToString("N") + ".sqlcipher");
        try
        {
            File.WriteAllText(path, "not a SQLCipher database");
            Environment.SetEnvironmentVariable(SqlPathEnv, path);
            Environment.SetEnvironmentVariable(SqlPassEnv, "ValidBase64Key-000=");

            var summary = WindowsStorageDevHost.LoadDashboardUsageSummary();

            Assert.False(summary.HasData);
            Assert.Equal(0, summary.SessionCount);
            Assert.Equal(0, summary.TotalTokens);
            Assert.Equal(0, summary.SpendThisMonthUsd);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    [Fact]
    public void CreateSwitcherProfileStore_with_real_credentials_prefers_the_real_store_over_sample()
    {
        // Copy the committed byte-compat fixture, WRITE a distinctive real profile into its
        // switcher_profiles table, then point the dev-host at it WITH sample mode also enabled.
        // The real encrypted store must win: SwitcherSampleData is only the empty-host fallback.
        string working = Path.Combine(Path.GetTempPath(), "obb-prefer-real-" + Guid.NewGuid().ToString("N") + ".sqlcipher");
        File.Copy(LocateFixture(), working, overwrite: true);
        try
        {
            var now = new DateTimeOffset(2026, 7, 4, 12, 0, 0, TimeSpan.Zero);
            using (var connection = SqlCipherConnection.Open(working, SqlCipherParameters.FixturePassphrase))
            {
                SwitcherProfileWriteSeam.UpsertProfile(connection, new SwitcherProfileRow(
                    Id: "real-db-profile",
                    TargetKind: "cli",
                    BrowserType: null,
                    BrowserMetadataJson: null,
                    CliType: "claude",
                    CliMetadataJson: "{\"displayLabel\":\"Real DB Profile\"}",
                    SortKey: 0,
                    CreatedAt: now,
                    UpdatedAt: now));
            }

            Environment.SetEnvironmentVariable(SampleEnv, "1");
            Environment.SetEnvironmentVariable(SqlPathEnv, working);
            Environment.SetEnvironmentVariable(SqlPassEnv, SqlCipherParameters.FixturePassphrase);

            ISwitcherProfileStore store = WindowsStorageDevHost.CreateSwitcherProfileStore();
            try
            {
                Assert.IsType<SqlCipherSwitcherProfileStore>(store);

                var ids = store.FetchAllProfiles().Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
                Assert.Contains("real-db-profile", ids);

                // Sample data must NOT leak in even though OPENBURNBAR_SAMPLE_MODE=1.
                foreach (var sample in SwitcherSampleData.DevHostProfiles())
                {
                    Assert.DoesNotContain(sample.Id, ids);
                }
            }
            finally
            {
                (store as IDisposable)?.Dispose();
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Environment.SetEnvironmentVariable(SqlPathEnv, null);
            Environment.SetEnvironmentVariable(SqlPassEnv, null);
            foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
            {
                try { File.Delete(working + suffix); } catch { /* best-effort */ }
            }
        }
    }

    private static string LocateFixture()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            string candidate = Path.Combine(dir.FullName, "AgentLensTests", "Fixtures", "DBByteCompat");
            if (File.Exists(Path.Combine(candidate, "openburnbar-db-compat-vector.json")))
            {
                string pinned = Path.Combine(candidate, "openburnbar-db-compat-v54.sqlcipher");
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
