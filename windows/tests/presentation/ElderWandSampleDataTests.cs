using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Tests for the dev-host seed the Windows Elder Wand host page injects into
/// <c>ElderWandConfiguratorView.Configure(...)</c>
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandSampleData.cs +
/// InMemoryElderWandPersistence.cs). Proves the seed lowers through the real grouping pass and
/// backs a working preset store so the hosted surface shows its live form.
/// </summary>
public sealed class ElderWandSampleDataTests
{
    [Fact]
    public void DevHostGroups_AreGroupedByProvider_InFirstSeenOrder()
    {
        var groups = ElderWandSampleData.DevHostGroups();

        Assert.Equal(new[] { "Anthropic", "OpenAI", "Google" }, groups.Select(g => g.ProviderName).ToArray());
        Assert.Equal(2, groups.First(g => g.ProviderName == "Anthropic").Options.Count);
    }

    [Fact]
    public void DevHostGroups_IncludeAnIneligibleOption()
    {
        var groups = ElderWandSampleData.DevHostGroups();

        Assert.Contains(groups.SelectMany(g => g.Options), o => !o.IsRouteEligible);
        Assert.Contains(groups.SelectMany(g => g.Options), o => o.IsRouteEligible);
    }

    [Fact]
    public void InMemoryPersistence_RoundTripsWrites()
    {
        var persistence = new InMemoryElderWandPersistence();
        Assert.Null(persistence.ReadString("k"));

        persistence.WriteString("k", "v");
        Assert.Equal("v", persistence.ReadString("k"));

        persistence.WriteString("k", "v2");
        Assert.Equal("v2", persistence.ReadString("k"));
    }

    [Fact]
    public void InMemoryPersistence_Seed_IsReadable()
    {
        var persistence = new InMemoryElderWandPersistence(
            new[] { new System.Collections.Generic.KeyValuePair<string, string>("seeded", "value") });

        Assert.Equal("value", persistence.ReadString("seeded"));
    }

    [Fact]
    public void CreateDevHostSettings_YieldsAnEmptyMutablePresetStore()
    {
        var settings = ElderWandSampleData.CreateDevHostSettings();
        Assert.False(settings.HasPresets);

        settings.Save(new ElderWandPreset("p1", "Anthropic panel", new[] { "anthropic/claude-opus-4" }, "openai/gpt-5", 8, IsDefault: false));

        Assert.True(settings.HasPresets);
        Assert.Equal("p1", settings.ActivePreset!.Id);
    }
}
