using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class AlertsSettingsViewModelTests
{
    [Fact]
    public void Defaults_MatchAlertSettings()
    {
        var vm = new AlertsSettingsViewModel();
        Assert.Null(vm.CostAlertThreshold);
        Assert.False(vm.CostAlertEnabled);
        Assert.Equal("Off", vm.ThresholdDisplay);
        Assert.False(vm.DailyDigestEnabled);
        Assert.Equal(18, vm.DailyDigestHour);
        Assert.Equal("18:00", vm.DailyDigestHourDisplay);
    }

    [Fact]
    public void EnablingCostAlert_SeedsTwentyFiveWithFloorOne()
    {
        var vm = new AlertsSettingsViewModel { CostAlertEnabled = true };
        Assert.Equal(AlertsSettingsViewModel.DefaultThresholdSeed, vm.CostAlertThreshold);
        Assert.True(vm.CostAlertEnabled);
    }

    [Fact]
    public void ThresholdOfZeroOrLess_ClearsToOff()
    {
        var vm = new AlertsSettingsViewModel { CostAlertThreshold = 40 };
        Assert.Equal(40, vm.CostAlertThreshold);

        vm.CostAlertThreshold = 0;
        Assert.Null(vm.CostAlertThreshold);
        Assert.False(vm.CostAlertEnabled);

        vm.CostAlertThreshold = -3;
        Assert.Null(vm.CostAlertThreshold);
    }

    [Fact]
    public void DisablingCostAlert_ClearsThreshold()
    {
        var vm = new AlertsSettingsViewModel { CostAlertThreshold = 50 };
        vm.CostAlertEnabled = false;
        Assert.Null(vm.CostAlertThreshold);
    }

    [Fact]
    public void EnablingCostAlert_KeepsExistingThresholdAboveFloor()
    {
        var vm = new AlertsSettingsViewModel();
        vm.CostAlertThreshold = 5; // stays, then disable + re-enable keeps 5 (>=1)
        vm.CostAlertEnabled = false;
        vm.CostAlertEnabled = true;
        Assert.Equal(AlertsSettingsViewModel.DefaultThresholdSeed, vm.CostAlertThreshold);
    }

    [Fact]
    public void DigestHour_ClampsOutOfRangeToDefault()
    {
        var vm = new AlertsSettingsViewModel { DailyDigestHour = 30 };
        Assert.Equal(18, vm.DailyDigestHour);
        vm.DailyDigestHour = -1;
        Assert.Equal(18, vm.DailyDigestHour);
        vm.DailyDigestHour = 6;
        Assert.Equal(6, vm.DailyDigestHour);
        Assert.Equal("06:00", vm.DailyDigestHourDisplay);
    }

    [Fact]
    public void HourChoices_CoverZeroToTwentyThree()
    {
        var vm = new AlertsSettingsViewModel();
        Assert.Equal(24, vm.HourChoices.Count);
        Assert.Equal(0, vm.HourChoices[0]);
        Assert.Equal(23, vm.HourChoices[^1]);
    }

    [Fact]
    public void LoadClamp_FixesAnOutOfRangeStoredHour()
    {
        var store = new InMemoryAlertSettingsStore(new AlertSettingsSnapshot(null, false, 99));
        var vm = new AlertsSettingsViewModel(store);
        Assert.Equal(18, vm.DailyDigestHour);
    }

    [Fact]
    public void Mutations_PersistThroughStore()
    {
        var store = new InMemoryAlertSettingsStore();
        var vm = new AlertsSettingsViewModel(store);
        vm.CostAlertThreshold = 12.5;
        vm.DailyDigestEnabled = true;
        vm.DailyDigestHour = 9;

        var reloaded = new AlertsSettingsViewModel(store);
        Assert.Equal(12.5, reloaded.CostAlertThreshold);
        Assert.True(reloaded.DailyDigestEnabled);
        Assert.Equal(9, reloaded.DailyDigestHour);
    }
}
