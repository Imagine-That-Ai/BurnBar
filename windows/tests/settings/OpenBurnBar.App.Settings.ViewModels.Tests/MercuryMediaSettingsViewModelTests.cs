using OpenBurnBar.App.Settings.ViewModels;
using OpenBurnBar.Integrations.Mercury.Budget;
using OpenBurnBar.Integrations.Mercury.Sessions;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class MercuryMediaSettingsViewModelTests
{
    [Fact]
    public void DefaultSourceFailsClosedWithoutEntitlement()
    {
        var vm = new MercuryMediaSettingsViewModel(
            new StaticMercuryMediaCapabilitySource(captureRuntimeSupported: true));

        Assert.False(vm.EntitlementActive);
        Assert.False(vm.HasAllowedCapability);
        Assert.Equal(nameof(MediaCapabilityDenialReason.EntitlementMissing), vm.DenialReason);
        Assert.Contains("authenticated", vm.Summary, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void NormalEntitledScreenShareCanBeEvaluated()
    {
        var vm = new MercuryMediaSettingsViewModel(
            new StaticMercuryMediaCapabilitySource(
                entitlement: MediaEntitlementState.All,
                budget: MediaBudgetStatusStore.InitialNormal,
                captureRuntimeSupported: true));

        vm.CheckSelectedCapability();

        Assert.True(vm.HasAllowedCapability);
        Assert.Equal(string.Empty, vm.DenialReason);
        Assert.Contains("Allowed", vm.DecisionText, System.StringComparison.Ordinal);
    }

    [Fact]
    public void RequestedDurationHonorsPerSessionCap()
    {
        var vm = new MercuryMediaSettingsViewModel(
            new StaticMercuryMediaCapabilitySource(
                entitlement: MediaEntitlementState.All,
                budget: MediaBudgetStatusStore.InitialNormal,
                captureRuntimeSupported: true))
        {
            RequestedDurationSeconds = 3_601,
        };

        Assert.False(vm.HasAllowedCapability);
        Assert.Equal(nameof(MediaCapabilityDenialReason.SessionCapReached), vm.DenialReason);
    }

    [Fact]
    public void KillSwitchAlwaysWinsOverQuotaAndEntitlement()
    {
        var vm = new MercuryMediaSettingsViewModel(
            new StaticMercuryMediaCapabilitySource(
                entitlement: MediaEntitlementState.All,
                budget: MediaBudgetStatusStore.InitialNormal,
                killSwitchActive: true,
                captureRuntimeSupported: true));

        Assert.False(vm.HasAllowedCapability);
        Assert.Equal(nameof(MediaCapabilityDenialReason.KillSwitchActive), vm.DenialReason);
    }
}
