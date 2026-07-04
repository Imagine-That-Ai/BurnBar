using OpenBurnBar.Integrations.Mercury.Budget;
using OpenBurnBar.Integrations.Mercury.Sessions;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MediaSessionStateMachineTests
{
    private static MediaCapabilityCheck Allowed(MediaFeature feature) =>
        MediaCapabilityCheck.Allowed(new MediaCapabilityEnvelope(feature));

    private static MediaCapabilityCheck Denied(MediaCapabilityDenialReason reason) =>
        MediaCapabilityCheck.Denied(reason);

    [Fact]
    public void InitialState_IsIdleAndRestartable()
    {
        var sm = new MediaSessionStateMachine();
        Assert.Equal(MediaSessionPhaseKind.Idle, sm.Phase.Kind);
        Assert.True(sm.IsRestartable);
        Assert.Equal(0, sm.ActiveViewerCount);
    }

    [Fact]
    public void BeginStart_Allowed_TransitionsToStarting()
    {
        var sm = new MediaSessionStateMachine();
        var outcome = sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());

        Assert.Equal(MediaSessionStartResult.Starting, outcome.Result);
        Assert.Equal(MediaSessionPhase.Starting(MediaFeature.ScreenShare), sm.Phase);
        Assert.Equal(1, sm.ActiveViewerCount);
        Assert.False(sm.IsRestartable);
    }

    [Fact]
    public void CompleteStart_PromotesToActive()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());
        sm.CompleteStart();
        Assert.Equal(MediaSessionPhase.Active(MediaFeature.ScreenShare), sm.Phase);
    }

    [Fact]
    public void BeginStart_AlreadyActiveSameFeature_AttachesSink()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());
        sm.CompleteStart();

        var outcome = sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v2", new object());
        Assert.Equal(MediaSessionStartResult.AttachedToActive, outcome.Result);
        Assert.Equal(2, sm.ActiveViewerCount);
        Assert.Equal(MediaSessionPhaseKind.Active, sm.Phase.Kind);
    }

    [Fact]
    public void BeginStart_WhileStarting_RejectsNotRestartable()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());

        var outcome = sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v2", new object());
        Assert.Equal(MediaSessionStartResult.RejectedNotRestartable, outcome.Result);
    }

    [Fact]
    public void BeginStart_Denied_EndsWithMappedReason()
    {
        var sm = new MediaSessionStateMachine();
        var outcome = sm.BeginStart(
            MediaFeature.ScreenShare,
            Denied(MediaCapabilityDenialReason.BudgetHardCapReached),
            "v1",
            new object());

        Assert.Equal(MediaSessionStartResult.RejectedDenied, outcome.Result);
        Assert.Equal(MediaCapabilityDenialReason.BudgetHardCapReached, outcome.DenialReason);
        Assert.Equal(MediaSessionPhase.Ended(MediaSessionEndReason.BudgetHardCap), sm.Phase);
        Assert.True(sm.IsRestartable);
    }

    [Fact]
    public void BeginStart_KillSwitchDenial_MapsToBudgetHardCapEnd()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Denied(MediaCapabilityDenialReason.KillSwitchActive), "v1", new object());
        Assert.Equal(MediaSessionEndReason.BudgetHardCap, sm.Phase.EndReason);
    }

    [Fact]
    public void Stop_ClearsViewersAndEnds()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());
        sm.CompleteStart();

        sm.Stop(MediaSessionEndReason.CompletedUserCancel);
        Assert.Equal(MediaSessionPhase.Ended(MediaSessionEndReason.CompletedUserCancel), sm.Phase);
        Assert.Equal(0, sm.ActiveViewerCount);
        Assert.True(sm.IsRestartable);
    }

    [Fact]
    public void DetachViewer_LastViewerStopsSession()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());
        sm.CompleteStart();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v2", new object());

        Assert.True(sm.DetachViewer("v1"));
        Assert.Equal(MediaSessionPhaseKind.Active, sm.Phase.Kind);
        Assert.Equal(1, sm.ActiveViewerCount);

        Assert.True(sm.DetachViewer("v2"));
        Assert.Equal(MediaSessionPhaseKind.Ended, sm.Phase.Kind);
    }

    [Fact]
    public void DetachViewer_UnknownKey_ReturnsFalse()
    {
        var sm = new MediaSessionStateMachine();
        Assert.False(sm.DetachViewer("nope"));
    }

    [Fact]
    public void RecheckAdmission_DeniedWhileActive_StopsWithMappedReason()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());
        sm.CompleteStart();

        var stopped = sm.RecheckAdmission(MediaFeature.ScreenShare, Denied(MediaCapabilityDenialReason.BudgetSoftCapReached));
        Assert.True(stopped);
        Assert.Equal(MediaSessionPhase.Ended(MediaSessionEndReason.BudgetSoftCap), sm.Phase);
    }

    [Fact]
    public void RecheckAdmission_AllowedWhileActive_DoesNotStop()
    {
        var sm = new MediaSessionStateMachine();
        sm.BeginStart(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare), "v1", new object());
        sm.CompleteStart();

        Assert.False(sm.RecheckAdmission(MediaFeature.ScreenShare, Allowed(MediaFeature.ScreenShare)));
        Assert.Equal(MediaSessionPhaseKind.Active, sm.Phase.Kind);
    }

    [Fact]
    public void RecheckAdmission_NotActive_ReturnsFalse()
    {
        var sm = new MediaSessionStateMachine();
        Assert.False(sm.RecheckAdmission(MediaFeature.ScreenShare, Denied(MediaCapabilityDenialReason.KillSwitchActive)));
    }

    [Theory]
    [InlineData(MediaCapabilityDenialReason.BudgetSoftCapReached, MediaSessionEndReason.BudgetSoftCap)]
    [InlineData(MediaCapabilityDenialReason.BudgetHardCapReached, MediaSessionEndReason.BudgetHardCap)]
    [InlineData(MediaCapabilityDenialReason.KillSwitchActive, MediaSessionEndReason.BudgetHardCap)]
    [InlineData(MediaCapabilityDenialReason.DailyCapReached, MediaSessionEndReason.Error)]
    [InlineData(MediaCapabilityDenialReason.EntitlementMissing, MediaSessionEndReason.Error)]
    public void EndReasonFor_MapsDenialToEndReason(MediaCapabilityDenialReason reason, MediaSessionEndReason expected)
    {
        Assert.Equal(expected, MediaSessionStateMachine.EndReasonFor(reason));
    }
}
