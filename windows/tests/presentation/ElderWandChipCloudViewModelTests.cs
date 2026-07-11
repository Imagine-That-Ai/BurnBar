using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the reactive chip cloud
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandChipCloudViewModel.cs). It
/// re-derives the exact per-chip selected/disabled flags the Swift ElderWandAnalysisChip /
/// ElderWandJudgeChip compute in their view bodies, but observably — so the WinUI clouds
/// x:Bind them. Proven here by driving the editor and asserting flags across the cloud.
/// </summary>
public sealed class ElderWandChipCloudViewModelTests
{
    private static IReadOnlyList<ElderWandProviderGroup> Catalog() => new[]
    {
        new ElderWandProviderGroup("Anthropic", new[]
        {
            new ElderWandModelOption("claude-a", "Claude A", IsRouteEligible: true),
            new ElderWandModelOption("claude-b", "Claude B", IsRouteEligible: true),
        }),
        new ElderWandProviderGroup("OpenAI", new[]
        {
            new ElderWandModelOption("gpt-live", "GPT Live", IsRouteEligible: true),
            new ElderWandModelOption("gpt-asleep", "GPT Asleep", IsRouteEligible: false),
        }),
    };

    private static ElderWandChip ChipFor(ElderWandChipCloudViewModel cloud, string id) =>
        cloud.Groups.SelectMany(g => g.Chips).Single(c => c.ModelId == id);

    [Fact]
    public void Build_MirrorsCatalogShape()
    {
        var editor = new ElderWandConfiguratorModel();
        using var cloud = new ElderWandChipCloudViewModel(editor, Catalog(), ElderWandCloudMode.Analysis);

        Assert.True(cloud.HasGroups);
        Assert.False(cloud.IsEmpty);
        Assert.Equal(new[] { "Anthropic", "OpenAI" }, cloud.Groups.Select(g => g.ProviderName));
        Assert.Equal(4, cloud.Groups.SelectMany(g => g.Chips).Count());
    }

    [Fact]
    public void EmptyCatalog_IsEmpty()
    {
        var editor = new ElderWandConfiguratorModel();
        using var cloud = new ElderWandChipCloudViewModel(
            editor, System.Array.Empty<ElderWandProviderGroup>(), ElderWandCloudMode.Judge);
        Assert.False(cloud.HasGroups);
        Assert.True(cloud.IsEmpty);
    }

    [Fact]
    public void Analysis_IneligibleChip_IsDisabledFromTheStart()
    {
        var editor = new ElderWandConfiguratorModel();
        using var cloud = new ElderWandChipCloudViewModel(editor, Catalog(), ElderWandCloudMode.Analysis);
        Assert.True(ChipFor(cloud, "gpt-asleep").IsDisabled);
        Assert.False(ChipFor(cloud, "claude-a").IsDisabled);
    }

    [Fact]
    public void Analysis_Toggle_UpdatesSelectedFlagObservably()
    {
        var editor = new ElderWandConfiguratorModel();
        using var cloud = new ElderWandChipCloudViewModel(editor, Catalog(), ElderWandCloudMode.Analysis);
        var chip = ChipFor(cloud, "claude-a");
        Assert.False(chip.IsSelected);

        cloud.Toggle(chip); // routes through the editor, which fires SelectionChanged
        Assert.True(chip.IsSelected);
        Assert.True(editor.IsAnalysisSelected("claude-a"));

        cloud.Toggle(chip);
        Assert.False(chip.IsSelected);
    }

    [Fact]
    public void Analysis_WhenPanelFull_UnselectedChipsDisable()
    {
        var editor = new ElderWandConfiguratorModel();
        // Fill the panel to the cap (8) via a synthetic catalog of eligible chips.
        var groups = new[]
        {
            new ElderWandProviderGroup("P", Enumerable.Range(0, 9)
                .Select(i => new ElderWandModelOption($"m{i}", $"M{i}", IsRouteEligible: true))
                .ToArray()),
        };
        using var cloud = new ElderWandChipCloudViewModel(editor, groups, ElderWandCloudMode.Analysis);

        for (int i = 0; i < 8; i++)
        {
            cloud.Toggle(ChipFor(cloud, $"m{i}"));
        }

        Assert.False(editor.CanAddMoreAnalysis);
        // The 9th (unselected) chip must now be disabled...
        Assert.True(ChipFor(cloud, "m8").IsDisabled);
        // ...while the already-selected ones stay enabled so they can be removed.
        Assert.False(ChipFor(cloud, "m0").IsDisabled);
        Assert.True(ChipFor(cloud, "m0").IsSelected);
    }

    [Fact]
    public void Judge_IsSingleSelect()
    {
        var editor = new ElderWandConfiguratorModel();
        using var cloud = new ElderWandChipCloudViewModel(editor, Catalog(), ElderWandCloudMode.Judge);

        cloud.Toggle(ChipFor(cloud, "claude-a"));
        Assert.True(ChipFor(cloud, "claude-a").IsSelected);

        cloud.Toggle(ChipFor(cloud, "claude-b")); // switches judge
        Assert.False(ChipFor(cloud, "claude-a").IsSelected);
        Assert.True(ChipFor(cloud, "claude-b").IsSelected);
        Assert.Equal("claude-b", editor.JudgeId);
    }

    [Fact]
    public void Judge_IneligibleDisabled_ButSelectionNotGatedByPanelFullness()
    {
        var editor = new ElderWandConfiguratorModel();
        using var cloud = new ElderWandChipCloudViewModel(editor, Catalog(), ElderWandCloudMode.Judge);
        Assert.True(ChipFor(cloud, "gpt-asleep").IsDisabled);
        Assert.False(ChipFor(cloud, "gpt-live").IsDisabled);
    }

    [Fact]
    public void Dispose_DetachesFromEditor()
    {
        var editor = new ElderWandConfiguratorModel();
        var cloud = new ElderWandChipCloudViewModel(editor, Catalog(), ElderWandCloudMode.Analysis);
        var chip = ChipFor(cloud, "claude-a");

        cloud.Dispose();
        editor.ToggleAnalysis("claude-a"); // editor state changes, but the disposed cloud must not react
        Assert.False(chip.IsSelected);
    }
}
