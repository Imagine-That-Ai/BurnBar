using System.Linq;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Switcher;

/// <summary>
/// Tests for the dev-host seed the Windows account-switcher host page injects
/// (windows/app/OpenBurnBar.App.Presentation/Switcher/SwitcherSampleData.cs). Proves the seed
/// drives a real, grouped, loadable <see cref="SwitcherSettingsViewModel"/> so the hosted surface
/// renders live sections before the encrypted profile store lands.
/// </summary>
public sealed class SwitcherSampleDataTests
{
    [Fact]
    public void CreateDevHostStore_SeedsProfiles_WithFirstActive()
    {
        var store = SwitcherSampleData.CreateDevHostStore();

        var profiles = store.FetchAllProfiles();
        Assert.Equal(5, profiles.Count);
        Assert.Equal(SwitcherSampleData.DevHostProfiles()[0].Id, store.FetchActiveProfileState().ActiveProfileId);
    }

    [Fact]
    public void DevHostProfiles_CoverCliAndBrowser_WithOneDisabled()
    {
        var profiles = SwitcherSampleData.DevHostProfiles();

        Assert.Contains(profiles, p => p.TargetKind == SwitcherProfileTargetKind.Cli);
        Assert.Contains(profiles, p => p.TargetKind == SwitcherProfileTargetKind.Browser);
        Assert.Contains(profiles, p => p.IsDisabled);
        // Every seeded profile carries a human label (no "Unknown Profile" fallbacks).
        Assert.All(profiles, p => Assert.NotEqual("Unknown Profile", p.DisplayName));
    }

    [Fact]
    public void SeededStore_LoadsIntoViewModel_WithBothSectionKinds()
    {
        var store = SwitcherSampleData.CreateDevHostStore();
        var vm = new SwitcherSettingsViewModel(store, now: () => SwitcherSampleData.SeedNow);

        vm.Load();

        Assert.NotEmpty(vm.CliSections);
        Assert.NotEmpty(vm.BrowserSections);
        Assert.True(vm.HasActiveProfile);
        Assert.Null(vm.ErrorMessage);
    }

    [Fact]
    public void SeededStore_IsMutable_CreateThenDeleteRoundTrips()
    {
        var store = SwitcherSampleData.CreateDevHostStore();
        int before = store.FetchAllProfiles().Count;

        var created = store.Create(new SwitcherProfileRecord(
            Id: "extra",
            TargetKind: SwitcherProfileTargetKind.Cli,
            SortKey: 0,
            CliType: SwitcherCLIProfileType.Gemini,
            CliMetadata: new SwitcherCLIProfileMetadata(DisplayLabel: "Gemini · extra")));

        Assert.Equal(before + 1, store.FetchAllProfiles().Count);

        store.DeleteProfile(created.Id);
        Assert.Equal(before, store.FetchAllProfiles().Count);
    }
}
