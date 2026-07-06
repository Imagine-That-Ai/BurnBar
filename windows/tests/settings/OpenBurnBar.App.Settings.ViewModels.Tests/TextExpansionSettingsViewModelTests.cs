using System;
using System.Linq;
using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.App.TextExpansion;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class TextExpansionSettingsViewModelTests
{
    private static TextExpansionSettingsViewModel NewVm(
        ITextExpansionSettingsStore? store = null,
        bool accessibilityTrusted = false)
    {
        return new TextExpansionSettingsViewModel(
            store ?? new InMemoryTextExpansionSettingsStore(),
            new StaticAccessibilityProbe(accessibilityTrusted),
            now: () => new DateTimeOffset(2026, 7, 6, 0, 0, 0, TimeSpan.Zero),
            idFactory: () => "snip-1");
    }

    [Fact]
    public void RuntimeToggles_DefaultToTextExpansionSettings()
    {
        var vm = NewVm();
        Assert.True(vm.InAppEnabled);
        Assert.False(vm.MacGlobalEnabled);
        Assert.True(vm.LlmPreviewEnabled);
        Assert.True(vm.ExportSnapshotEnabled);
        Assert.True(vm.CloudSyncEnabled);
    }

    [Fact]
    public void MacGlobal_BlockedWhenAccessibilityMissing()
    {
        var vm = NewVm(accessibilityTrusted: false);
        vm.MacGlobalEnabled = true;
        Assert.True(vm.MacGlobalBlocked);
        Assert.NotNull(vm.MacGlobalBlockedMessage);
    }

    [Fact]
    public void MacGlobal_NotBlockedWhenTrusted()
    {
        var vm = NewVm(accessibilityTrusted: true);
        vm.MacGlobalEnabled = true;
        Assert.False(vm.MacGlobalBlocked);
        Assert.Null(vm.MacGlobalBlockedMessage);
    }

    [Fact]
    public void TriggerValidation_EnforcesMinTwoChars()
    {
        var vm = NewVm();
        vm.DraftTrigger = "a";
        Assert.NotNull(vm.TriggerError);
    }

    [Fact]
    public void TriggerValidation_RejectsIllegalCharacters()
    {
        var vm = NewVm();
        vm.DraftTrigger = "Bad Trigger!";
        Assert.NotNull(vm.TriggerError);
    }

    [Fact]
    public void CanSave_RequiresTitleTriggerAndBody()
    {
        var vm = NewVm();
        Assert.False(vm.CanSave);
        vm.DraftTitle = "Greeting";
        vm.DraftTrigger = "hi";
        Assert.False(vm.CanSave); // body still empty
        vm.DraftBody = "Hello there";
        Assert.True(vm.CanSave);
        Assert.Null(vm.TriggerError);
    }

    [Fact]
    public void Save_PersistsAndReloadsSnippet()
    {
        var store = new InMemoryTextExpansionSettingsStore();
        var vm = NewVm(store);
        vm.DraftTitle = "Greeting";
        vm.DraftTrigger = "hi";
        vm.DraftBody = "Hello there";

        Assert.True(vm.Save());
        Assert.Equal(1, vm.SnippetCount);
        Assert.Single(store.LoadSnippets());
        Assert.Equal("hi", store.LoadSnippets()[0].Trigger);
    }

    [Fact]
    public void DuplicateTrigger_IsRejected()
    {
        var existing = new TextExpansionSnippet("Greeting", "hi", "Hello");
        var store = new InMemoryTextExpansionSettingsStore(new[] { existing });
        var vm = NewVm(store);
        vm.CreateDraft();
        vm.DraftTitle = "Other";
        vm.DraftTrigger = "hi";
        vm.DraftBody = "Hey";

        Assert.NotNull(vm.DuplicateTriggerError);
        Assert.False(vm.CanSave);
        Assert.False(vm.Save());
    }

    [Fact]
    public void EditingOwnSnippet_IsNotADuplicate()
    {
        var existing = new TextExpansionSnippet("Greeting", "hi", "Hello", id: "s1");
        var store = new InMemoryTextExpansionSettingsStore(new[] { existing });
        var vm = NewVm(store);
        vm.Select("s1");
        Assert.Null(vm.DuplicateTriggerError);
        vm.DraftBody = "Updated";
        Assert.True(vm.CanSave);
    }

    [Fact]
    public void DeleteSelected_RemovesSnippetAndResetsDraft()
    {
        var existing = new TextExpansionSnippet("Greeting", "hi", "Hello", id: "s1");
        var store = new InMemoryTextExpansionSettingsStore(new[] { existing });
        var vm = NewVm(store);
        vm.Select("s1");
        Assert.True(vm.DeleteSelected());
        Assert.Empty(store.LoadSnippets());
        Assert.Null(vm.SelectedId);
    }

    [Fact]
    public void Search_FiltersSnippetList()
    {
        var store = new InMemoryTextExpansionSettingsStore(new[]
        {
            new TextExpansionSnippet("Greeting", "hi", "Hello"),
            new TextExpansionSnippet("Signature", "sig", "Best regards"),
        });
        var vm = NewVm(store);
        Assert.Equal(2, vm.Snippets.Count);
        vm.SearchQuery = "sign";
        Assert.Single(vm.Snippets);
        Assert.Equal("Signature", vm.Snippets[0].Title);
    }

    [Fact]
    public void RuntimeToggles_PersistThroughStore()
    {
        var store = new InMemoryTextExpansionSettingsStore();
        var vm = NewVm(store);
        vm.InAppEnabled = false;
        vm.CloudSyncEnabled = false;

        var reloaded = NewVm(store);
        Assert.False(reloaded.InAppEnabled);
        Assert.False(reloaded.CloudSyncEnabled);
    }
}
