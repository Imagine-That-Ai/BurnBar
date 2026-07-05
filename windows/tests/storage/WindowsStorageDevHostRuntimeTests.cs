using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Budget;
using OpenBurnBar.App.Presentation.Switcher;
using OpenBurnBar.App.Storage;
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
}