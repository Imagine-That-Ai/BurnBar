using OpenBurnBar.App.Onboarding;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>
/// Parity tests for the Prepare-Hermes state machine ported from
/// <c>HermesSetupWizardController.swift</c>: reachability derivation (the Connect hero's
/// single source of truth), the per-state copy/action, and the step-gating rules.
/// </summary>
public sealed class HermesSetupModelTests
{
    private static HermesSetupModel Ready()
    {
        // The fully-configured, gateway-running baseline.
        return new HermesSetupModel
        {
            HermesCliInstalled = true,
            ApiServerEnabled = true,
            HasApiServerKey = true,
            IsGatewayRunning = true,
            ProbeAttempts = 1,
        };
    }

    [Fact]
    public void Reachability_CliMissing_DominatesEverything()
    {
        var model = Ready();
        model.HermesCliInstalled = false;
        Assert.Equal(GatewayReachabilityState.CliMissing, model.Reachability);
        Assert.Equal("BLOCKED", model.Reachability.Eyebrow());
        Assert.Null(model.Reachability.PrimaryActionLabel()); // Prepare owns the install flow
        Assert.Equal(GatewayReachabilityAccent.Blocked, model.Reachability.Accent());
    }

    [Fact]
    public void Reachability_ApiServerDisabled_WhenEnabledOrKeyMissing()
    {
        var model = Ready();
        model.ApiServerEnabled = false;
        Assert.Equal(GatewayReachabilityState.ApiServerDisabled, model.Reachability);

        model = Ready();
        model.HasApiServerKey = false;
        Assert.Equal(GatewayReachabilityState.ApiServerDisabled, model.Reachability);
        Assert.Equal("Prepare API Server", model.Reachability.PrimaryActionLabel());
    }

    [Fact]
    public void Reachability_GatewayRunning_IsReady()
    {
        var model = Ready();
        Assert.Equal(GatewayReachabilityState.GatewayRunning, model.Reachability);
        Assert.True(model.Reachability.IsReady());
        Assert.Null(model.Reachability.PrimaryActionLabel());
        Assert.Equal(GatewayReachabilityAccent.Ready, model.Reachability.Accent());
    }

    [Fact]
    public void Reachability_DashboardOnly_WhenDashboardUpButGatewayDown()
    {
        var model = Ready();
        model.IsGatewayRunning = false;
        model.IsDashboardRunning = true;
        Assert.Equal(GatewayReachabilityState.DashboardOnly, model.Reachability);
        Assert.Equal("Make Gateway Reachable", model.Reachability.PrimaryActionLabel());
        Assert.Equal(GatewayReachabilityAccent.Warning, model.Reachability.Accent());
    }

    [Fact]
    public void Reachability_Unknown_BeforeAnyProbe()
    {
        var model = Ready();
        model.IsGatewayRunning = false;
        model.IsDashboardRunning = false;
        model.ProbeAttempts = 0;
        Assert.Equal(GatewayReachabilityState.Unknown, model.Reachability);
        Assert.Equal("GATEWAY", model.Reachability.Eyebrow());
    }

    [Fact]
    public void Reachability_Unreachable_AfterProbeFindsNothing()
    {
        var model = Ready();
        model.IsGatewayRunning = false;
        model.IsDashboardRunning = false;
        model.ProbeAttempts = 3;
        Assert.Equal(GatewayReachabilityState.Unreachable, model.Reachability);
        Assert.Equal("Make Gateway Reachable", model.Reachability.PrimaryActionLabel());
        Assert.Equal(GatewayReachabilityAccent.Blocked, model.Reachability.Accent());
    }

    [Fact]
    public void CanContinueFromPrepare_RequiresCliAndApiServer()
    {
        var model = new HermesSetupModel();
        Assert.False(model.CanContinueFromPrepare);

        model.HermesCliInstalled = true;
        model.ApiServerEnabled = true;
        model.HasApiServerKey = true;
        Assert.True(model.CanContinueFromPrepare);

        model.HasApiServerKey = false;
        Assert.False(model.CanContinueFromPrepare);
    }

    [Fact]
    public void CanContinueFromConnect_RequiresRunningGateway()
    {
        var model = new HermesSetupModel();
        Assert.False(model.CanContinueFromConnect);
        model.IsGatewayRunning = true;
        Assert.True(model.CanContinueFromConnect);
    }

    [Fact]
    public void Navigation_WalksPrepareConnectChat_AndClamps()
    {
        var model = new HermesSetupModel();
        Assert.Equal(HermesSetupStep.Prepare, model.CurrentStep);

        Assert.True(model.NavigateForward());
        Assert.Equal(HermesSetupStep.Connect, model.CurrentStep);
        Assert.Equal(OnboardingNavigationDirection.Forward, model.LastNavigationDirection);

        Assert.True(model.NavigateForward());
        Assert.Equal(HermesSetupStep.Chat, model.CurrentStep);

        Assert.False(model.NavigateForward()); // clamp at Chat
        Assert.Equal(HermesSetupStep.Chat, model.CurrentStep);

        Assert.True(model.NavigateBack());
        Assert.Equal(HermesSetupStep.Connect, model.CurrentStep);
        Assert.Equal(OnboardingNavigationDirection.Backward, model.LastNavigationDirection);

        Assert.True(model.NavigateBack());
        Assert.False(model.NavigateBack()); // clamp at Prepare
        Assert.Equal(HermesSetupStep.Prepare, model.CurrentStep);
    }

    [Fact]
    public void StepLabels_MatchSwift()
    {
        Assert.Equal("1 · Prepare", HermesSetupStep.Prepare.StepLabel());
        Assert.Equal("2 · Connect", HermesSetupStep.Connect.StepLabel());
        Assert.Equal("3 · Chat", HermesSetupStep.Chat.StepLabel());
        Assert.Equal(0.0, HermesSetupStep.Prepare.ProgressFraction(), 6);
        Assert.Equal(1.0, HermesSetupStep.Chat.ProgressFraction(), 6);
    }
}
