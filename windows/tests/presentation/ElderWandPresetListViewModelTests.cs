using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported preset-list projection
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandPresetListViewModel.cs),
/// parity with the ElderWandPresetRow rendering in ElderWandPresetSection.swift.
/// </summary>
public sealed class ElderWandPresetListViewModelTests
{
    private sealed class NullPersistence : IElderWandPresetPersistence
    {
        public string? ReadString(string key) => null;

        public void WriteString(string key, string value)
        {
        }
    }

    private static ElderWandSettingsModel Store() => new(new NullPersistence());

    private static ElderWandPreset Preset(string id, int panel, string judge, bool isDefault = false)
    {
        var models = Enumerable.Range(0, panel).Select(i => $"{id}-m{i}").ToArray();
        return new ElderWandPreset(id, $"Panel {id}", models, judge, 8, isDefault);
    }

    [Fact]
    public void Rows_StartEmpty()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        Assert.True(list.IsEmpty);
        Assert.False(list.HasRows);
        Assert.Empty(list.Rows);
    }

    [Fact]
    public void Rows_RebuildOnSave()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        store.Save(Preset("p1", 2, "anthropic/claude"));

        Assert.False(list.IsEmpty);
        Assert.Single(list.Rows);
        Assert.Equal("Panel p1", list.Rows[0].Name);
    }

    [Fact]
    public void Row_Summary_MatchesSwiftFormat()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        store.Save(Preset("p1", 3, "meta-llama/llama-3.1-70b"));

        Assert.Equal("3 models · judge llama-3.1-70b", list.Rows[0].Summary);
    }

    [Fact]
    public void Row_PanelLabel_SingularAndPlural()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        store.Save(Preset("single", 1, "j"));
        Assert.Equal("1 model", list.Rows[0].PanelLabel);

        store.Save(Preset("multi", 4, "j"));
        var multi = list.Rows.Single(r => r.Id == "multi");
        Assert.Equal("4 models", multi.PanelLabel);
    }

    [Fact]
    public void Row_IsActive_TracksTheDefault()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        store.Save(Preset("p1", 1, "j"));
        store.Save(Preset("p2", 1, "j"));

        Assert.True(list.Rows.Single(r => r.Id == "p1").IsActive);
        Assert.False(list.Rows.Single(r => r.Id == "p2").IsActive);

        store.SetDefault("p2");
        Assert.False(list.Rows.Single(r => r.Id == "p1").IsActive);
        Assert.True(list.Rows.Single(r => r.Id == "p2").IsActive);
        Assert.True(list.Rows.Single(r => r.Id == "p2").IsNotActive == false);
    }

    [Fact]
    public void Row_AccessibilityLabel_IncludesDefaultAndSummary()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        store.Save(Preset("p1", 2, "openai/gpt"));

        Assert.Equal("Panel p1, default. 2 models · judge openai/gpt", list.Rows[0].AccessibilityLabel);
    }

    [Fact]
    public void Rows_RebuildOnDelete()
    {
        var store = Store();
        using var list = new ElderWandPresetListViewModel(store);
        store.Save(Preset("p1", 1, "j"));
        store.Save(Preset("p2", 1, "j"));
        Assert.Equal(2, list.Rows.Count);

        store.Delete("p1");
        Assert.Single(list.Rows);
        Assert.Equal("p2", list.Rows[0].Id);
    }

    [Fact]
    public void Dispose_StopsTrackingTheStore()
    {
        var store = Store();
        var list = new ElderWandPresetListViewModel(store);
        list.Dispose();

        store.Save(Preset("p1", 1, "j")); // mutate after dispose
        Assert.Empty(list.Rows); // projection frozen
    }
}
