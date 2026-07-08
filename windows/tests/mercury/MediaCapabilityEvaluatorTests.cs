using OpenBurnBar.Integrations.Mercury.Budget;
using OpenBurnBar.Integrations.Mercury.Sessions;
using Xunit;

namespace OpenBurnBar.Integrations.Mercury.Tests;

public sealed class MediaCapabilityEvaluatorTests
{
    private readonly MediaCapabilityEvaluator _evaluator = new();

    private static MediaBudgetStatus Budget(MediaBudgetLevel level, MediaBudgetEnvelope envelope) =>
        new(level, 0, 0, System.DateTimeOffset.UnixEpoch, envelope);

    private static MediaBudgetStatus NormalBudget() => Budget(MediaBudgetLevel.Normal, MediaBudgetEnvelope.Normal);

    private MediaCapabilityCheck Evaluate(
        MediaFeature feature,
        MediaEntitlementState? entitlement = null,
        MediaBudgetStatus? budget = null,
        MediaQuotaUsageSnapshot? usage = null,
        bool killSwitch = false,
        int concurrent = 0,
        int? durationLimit = null,
        long? byteBudget = null,
        MediaCapabilityTransferDirection? direction = null) =>
        _evaluator.Evaluate(
            feature,
            durationLimit,
            byteBudget,
            direction,
            entitlement ?? MediaEntitlementState.All,
            budget ?? NormalBudget(),
            usage ?? new MediaQuotaUsageSnapshot(),
            killSwitch,
            concurrent);

    [Fact]
    public void InactiveEntitlement_DeniesEntitlementMissing()
    {
        var check = Evaluate(MediaFeature.ScreenShare, entitlement: MediaEntitlementState.None);
        Assert.False(check.IsAllowed);
        Assert.Equal(MediaCapabilityDenialReason.EntitlementMissing, check.DenialReason);
    }

    [Fact]
    public void FeatureNotEntitled_DeniesEntitlementMissing()
    {
        var entitlement = new MediaEntitlementState(active: true, fileTransfer: true, screenShare: false, videoCall: true);
        var check = Evaluate(MediaFeature.ScreenShare, entitlement: entitlement);
        Assert.Equal(MediaCapabilityDenialReason.EntitlementMissing, check.DenialReason);
    }

    [Fact]
    public void ComputerUse_UsesScreenShareEntitlement()
    {
        var entitlement = new MediaEntitlementState(active: true, fileTransfer: true, screenShare: false, videoCall: true);
        var check = Evaluate(MediaFeature.ComputerUse, entitlement: entitlement);
        Assert.Equal(MediaCapabilityDenialReason.EntitlementMissing, check.DenialReason);
    }

    [Fact]
    public void KillSwitch_DeniesBeforeBudgetMath()
    {
        // Kill switch is evaluated before the budget-level switch — even a hard
        // cap surfaces as KillSwitchActive because the switch wins the race.
        var check = Evaluate(
            MediaFeature.ScreenShare,
            budget: Budget(MediaBudgetLevel.HardCap, MediaBudgetEnvelope.HardCap),
            killSwitch: true);
        Assert.Equal(MediaCapabilityDenialReason.KillSwitchActive, check.DenialReason);
    }

    [Fact]
    public void HardCap_DeniesBudgetHardCap()
    {
        var check = Evaluate(MediaFeature.ScreenShare, budget: Budget(MediaBudgetLevel.HardCap, MediaBudgetEnvelope.HardCap));
        Assert.Equal(MediaCapabilityDenialReason.BudgetHardCapReached, check.DenialReason);
    }

    [Fact]
    public void SoftCap_EnvelopeDisallowsFeature_DeniesBudgetSoftCap()
    {
        // Soft cap with a zero envelope for screen share → the per-session
        // ceiling is zero, so admission is refused with BudgetSoftCapReached.
        var check = Evaluate(MediaFeature.ScreenShare, budget: Budget(MediaBudgetLevel.SoftCap, MediaBudgetEnvelope.HardCap));
        Assert.Equal(MediaCapabilityDenialReason.BudgetSoftCapReached, check.DenialReason);
    }

    [Fact]
    public void SoftCap_EnvelopeAllowsFeature_ProceedsAndAllows()
    {
        var check = Evaluate(MediaFeature.ScreenShare, budget: Budget(MediaBudgetLevel.SoftCap, MediaBudgetEnvelope.SoftCap));
        Assert.True(check.IsAllowed);
        Assert.Equal(30 * 60, check.Envelope!.PerSessionMaxSeconds);
    }

    [Fact]
    public void ScreenShare_DailyCapReached_Denies()
    {
        var usage = new MediaQuotaUsageSnapshot { ScreenShareSecondsUsed = 120 * 60 };
        var check = Evaluate(MediaFeature.ScreenShare, usage: usage);
        Assert.Equal(MediaCapabilityDenialReason.DailyCapReached, check.DenialReason);
    }

    [Fact]
    public void ScreenShare_SessionOverPerSessionCap_Denies()
    {
        var check = Evaluate(MediaFeature.ScreenShare, durationLimit: 60 * 60 + 1);
        Assert.Equal(MediaCapabilityDenialReason.SessionCapReached, check.DenialReason);
    }

    [Fact]
    public void ScreenShare_ConcurrentCapReached_Denies()
    {
        var check = Evaluate(MediaFeature.ScreenShare, concurrent: 3);
        Assert.Equal(MediaCapabilityDenialReason.ConcurrentSessionCapReached, check.DenialReason);
    }

    [Fact]
    public void ScreenShare_Allowed_ReturnsEnvelope()
    {
        var check = Evaluate(MediaFeature.ScreenShare, durationLimit: 60 * 60);
        Assert.True(check.IsAllowed);
        var envelope = check.Envelope!;
        Assert.Equal(MediaFeature.ScreenShare, envelope.Feature);
        Assert.Equal(120 * 60, envelope.RemainingSecondsToday);
        Assert.Equal(60 * 60, envelope.PerSessionMaxSeconds);
        Assert.Equal(3, envelope.ConcurrentSessionsRemaining);
    }

    [Fact]
    public void VideoCall_ConcurrentLimitIsOne()
    {
        var check = Evaluate(MediaFeature.VideoCall, concurrent: 1);
        Assert.Equal(MediaCapabilityDenialReason.ConcurrentSessionCapReached, check.DenialReason);
    }

    [Fact]
    public void FileTransfer_InboundDailyCapReached_Denies()
    {
        var usage = new MediaQuotaUsageSnapshot { BytesDownloadedFile = 5_000_000_000 };
        var check = Evaluate(MediaFeature.FileTransfer, usage: usage, direction: MediaCapabilityTransferDirection.Inbound);
        Assert.Equal(MediaCapabilityDenialReason.DailyCapReached, check.DenialReason);
    }

    [Fact]
    public void FileTransfer_OutboundDailyCapReached_Denies()
    {
        var usage = new MediaQuotaUsageSnapshot { BytesUploadedFile = 5_000_000_000 };
        var check = Evaluate(MediaFeature.FileTransfer, usage: usage, direction: MediaCapabilityTransferDirection.Outbound);
        Assert.Equal(MediaCapabilityDenialReason.DailyCapReached, check.DenialReason);
    }

    [Fact]
    public void FileTransfer_OverPerFileCap_DeniesSessionCap()
    {
        var check = Evaluate(
            MediaFeature.FileTransfer,
            byteBudget: 1_000_000_001,
            direction: MediaCapabilityTransferDirection.Inbound);
        Assert.Equal(MediaCapabilityDenialReason.SessionCapReached, check.DenialReason);
    }

    [Fact]
    public void FileTransfer_NegativeByteBudget_DeniesSessionCap()
    {
        var check = Evaluate(MediaFeature.FileTransfer, byteBudget: -1);
        Assert.Equal(MediaCapabilityDenialReason.SessionCapReached, check.DenialReason);
    }

    [Fact]
    public void FileTransfer_Allowed_ReturnsRemainingBytes()
    {
        var check = Evaluate(
            MediaFeature.FileTransfer,
            byteBudget: 500_000_000,
            direction: MediaCapabilityTransferDirection.Inbound);
        Assert.True(check.IsAllowed);
        Assert.Equal(5_000_000_000, check.Envelope!.RemainingBytesToday);
        Assert.Equal(4, check.Envelope!.ConcurrentSessionsRemaining);
    }

    [Fact]
    public void FailsClosed_EntitlementCheckedBeforeKillSwitchAndBudget()
    {
        // Inactive entitlement short-circuits even with kill switch + hard cap
        // both engaged: the very first gate wins, and nothing downstream leaks.
        var check = Evaluate(
            MediaFeature.ScreenShare,
            entitlement: MediaEntitlementState.None,
            budget: Budget(MediaBudgetLevel.HardCap, MediaBudgetEnvelope.HardCap),
            killSwitch: true);
        Assert.Equal(MediaCapabilityDenialReason.EntitlementMissing, check.DenialReason);
    }
}
