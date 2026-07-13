using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class GeneralSettingsViewModelTests
{
    [Fact]
    public void Defaults_MatchMacBehaviorSettings()
    {
        var vm = new GeneralSettingsViewModel();

        Assert.Equal(GeneralTimeRange.Today, vm.TimeRange);
        Assert.Equal(GeneralUsageDisplayMode.Currency, vm.UsageDisplayMode);
        Assert.Equal(600, vm.RefreshIntervalSeconds);
        Assert.False(vm.IndexingEnabled);
        Assert.True(vm.AutoSummariesEnabled);
        Assert.Equal(GeneralEmbeddingProvider.Deterministic, vm.EmbeddingProvider);
        Assert.Equal("text-embedding-3-small", vm.OpenAIEmbeddingModel);
    }

    [Fact]
    public void RefreshInterval_NormalizesUnsupportedValues()
    {
        var vm = new GeneralSettingsViewModel { RefreshIntervalSeconds = 17 };
        Assert.Equal(600, vm.RefreshIntervalSeconds);

        vm.RefreshIntervalSeconds = 300;
        Assert.Equal(300, vm.RefreshIntervalSeconds);
    }

    [Fact]
    public void EmbeddingModel_NormalizesUnknownValues()
    {
        var vm = new GeneralSettingsViewModel { OpenAIEmbeddingModel = "unknown-model" };
        Assert.Equal("text-embedding-3-small", vm.OpenAIEmbeddingModel);

        vm.OpenAIEmbeddingModel = "TEXT-EMBEDDING-3-LARGE";
        Assert.Equal("text-embedding-3-large", vm.OpenAIEmbeddingModel);
    }

    [Fact]
    public void Mutations_PersistAndReload()
    {
        var store = new InMemoryGeneralSettingsStore();
        var vm = new GeneralSettingsViewModel(store)
        {
            TimeRange = GeneralTimeRange.Month,
            UsageDisplayMode = GeneralUsageDisplayMode.Tokens,
            RefreshIntervalSeconds = 900,
            IndexingEnabled = true,
            AutoSummariesEnabled = false,
            EmbeddingProvider = GeneralEmbeddingProvider.OpenAI,
            OpenAIEmbeddingModel = "text-embedding-ada-002",
        };

        var reloaded = new GeneralSettingsViewModel(store);
        Assert.Equal(GeneralTimeRange.Month, reloaded.TimeRange);
        Assert.Equal(GeneralUsageDisplayMode.Tokens, reloaded.UsageDisplayMode);
        Assert.Equal(900, reloaded.RefreshIntervalSeconds);
        Assert.True(reloaded.IndexingEnabled);
        Assert.False(reloaded.AutoSummariesEnabled);
        Assert.Equal(GeneralEmbeddingProvider.OpenAI, reloaded.EmbeddingProvider);
        Assert.Equal("text-embedding-ada-002", reloaded.OpenAIEmbeddingModel);
    }

    [Fact]
    public void Load_NormalizesMalformedSnapshot()
    {
        var store = new InMemoryGeneralSettingsStore(new GeneralSettingsSnapshot(
            (GeneralTimeRange)99,
            (GeneralUsageDisplayMode)99,
            1,
            false,
            true,
            (GeneralEmbeddingProvider)99,
            "nope"));

        var vm = new GeneralSettingsViewModel(store);

        Assert.Equal(GeneralTimeRange.Today, vm.TimeRange);
        Assert.Equal(GeneralUsageDisplayMode.Currency, vm.UsageDisplayMode);
        Assert.Equal(600, vm.RefreshIntervalSeconds);
        Assert.Equal(GeneralEmbeddingProvider.Deterministic, vm.EmbeddingProvider);
        Assert.Equal("text-embedding-3-small", vm.OpenAIEmbeddingModel);
    }
}
