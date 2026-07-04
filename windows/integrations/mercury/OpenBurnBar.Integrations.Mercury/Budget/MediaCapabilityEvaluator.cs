using System;
using OpenBurnBar.Integrations.Mercury.Sessions;

namespace OpenBurnBar.Integrations.Mercury.Budget;

/// <summary>
/// Pure port of the Mac authoritative admission decision in
/// <c>AgentLens/Services/Media/MacMediaCapabilityGate.swift</c>
/// (<c>check</c> / <c>dailyCapDecision</c> / <c>effectiveEnvelope</c> /
/// <c>concurrentLimit</c> / remaining/perSession helpers).
///
/// Security invariant preserved EXACTLY (master plan § 9.5 / R17): the gate
/// evaluates, in order, entitlement → kill-switch → budget level (hard/soft) →
/// daily cap → per-session cap → concurrent cap, and fails CLOSED — any
/// deny short-circuits before an <c>Allowed</c> envelope is ever produced. The
/// kill switch and hard cap both refuse a session outright before quota math.
/// </summary>
public sealed class MediaCapabilityEvaluator
{
    private const long BytesPerGb = 1_000_000_000;
    private const long PerFileMaxBytes = 1_000_000_000; // 1 GB / file (parity: perSessionMaxBytes)

    /// <summary>
    /// Evaluate an admission request against a full snapshot of the three
    /// signals (entitlement, budget envelope, cached quota usage) plus the live
    /// kill-switch and concurrent-session count.
    /// </summary>
    public MediaCapabilityCheck Evaluate(
        MediaFeature feature,
        int? sessionDurationLimitSeconds,
        long? sessionByteBudget,
        MediaCapabilityTransferDirection? transferDirection,
        MediaEntitlementState entitlement,
        MediaBudgetStatus budget,
        MediaQuotaUsageSnapshot usage,
        bool killSwitchActive,
        int concurrentSessions)
    {
        if (entitlement is null)
        {
            throw new ArgumentNullException(nameof(entitlement));
        }

        if (budget is null)
        {
            throw new ArgumentNullException(nameof(budget));
        }

        if (usage is null)
        {
            throw new ArgumentNullException(nameof(usage));
        }

        if (!entitlement.Active)
        {
            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.EntitlementMissing);
        }

        var featureEntitled = feature switch
        {
            MediaFeature.FileTransfer => entitlement.FileTransfer,
            MediaFeature.ScreenShare => entitlement.ScreenShare,
            MediaFeature.VideoCall => entitlement.VideoCall,
            MediaFeature.ComputerUse => entitlement.ScreenShare,
            _ => false,
        };
        if (!featureEntitled)
        {
            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.EntitlementMissing);
        }

        // Kill switch first — a hard stop that precedes any quota math (R17).
        if (killSwitchActive)
        {
            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.KillSwitchActive);
        }

        switch (budget.Level)
        {
            case MediaBudgetLevel.HardCap:
                return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.BudgetHardCapReached);
            case MediaBudgetLevel.SoftCap:
                if (!budget.ActiveEnvelope.AllowsSession(feature))
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.BudgetSoftCapReached);
                }

                break;
            case MediaBudgetLevel.Normal:
                break;
            default:
                break;
        }

        var envelope = EffectiveEnvelope(budget.Level, budget.ActiveEnvelope);
        var dailyDecision = DailyCapDecision(
            feature,
            envelope,
            usage,
            sessionDurationLimitSeconds,
            sessionByteBudget,
            transferDirection);
        if (!dailyDecision.IsAllowed)
        {
            return dailyDecision;
        }

        var limit = ConcurrentLimit(feature);
        if (concurrentSessions >= limit)
        {
            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.ConcurrentSessionCapReached);
        }

        var result = new MediaCapabilityEnvelope(
            feature,
            remainingSecondsToday: RemainingSeconds(feature, envelope, usage),
            remainingBytesToday: RemainingBytes(feature, envelope, usage),
            perSessionMaxSeconds: PerSessionMaxSeconds(feature, envelope),
            perSessionMaxBytes: PerSessionMaxBytes(feature),
            concurrentSessionsRemaining: Math.Max(0, limit - concurrentSessions));
        return MediaCapabilityCheck.Allowed(result);
    }

    /// <summary>Parity: effectiveEnvelope(level:base:).</summary>
    public MediaBudgetEnvelope EffectiveEnvelope(MediaBudgetLevel level, MediaBudgetEnvelope @base) => level switch
    {
        MediaBudgetLevel.Normal => @base.AllowsSession(MediaFeature.FileTransfer) ? @base : MediaBudgetEnvelope.Normal,
        MediaBudgetLevel.SoftCap => @base,
        MediaBudgetLevel.HardCap => MediaBudgetEnvelope.HardCap,
        _ => @base,
    };

    /// <summary>Parity: concurrentLimit(for:).</summary>
    public int ConcurrentLimit(MediaFeature feature) => feature switch
    {
        MediaFeature.FileTransfer => 4,
        MediaFeature.ScreenShare => 3,
        MediaFeature.VideoCall => 1,
        MediaFeature.ComputerUse => 1,
        _ => 1,
    };

    /// <summary>Parity: dailyCapDecision(...).</summary>
    private MediaCapabilityCheck DailyCapDecision(
        MediaFeature feature,
        MediaBudgetEnvelope envelope,
        MediaQuotaUsageSnapshot usage,
        int? sessionDurationLimitSeconds,
        long? sessionByteBudget,
        MediaCapabilityTransferDirection? transferDirection)
    {
        switch (feature)
        {
            case MediaFeature.FileTransfer:
            {
                var dailyBytesIn = (long)envelope.FileTransferDailyGbIn * BytesPerGb;
                var dailyBytesOut = (long)envelope.FileTransferDailyGbOut * BytesPerGb;
                var perFileBytes = PerSessionMaxBytes(MediaFeature.FileTransfer) ?? dailyBytesOut;
                if (sessionByteBudget is < 0)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                }

                var requestedBytes = sessionByteBudget ?? 0;
                switch (transferDirection)
                {
                    case MediaCapabilityTransferDirection.Inbound:
                        if (usage.BytesDownloadedFile >= dailyBytesIn)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.DailyCapReached);
                        }

                        if (sessionByteBudget != null && requestedBytes > perFileBytes)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                        }

                        if (sessionByteBudget != null && usage.BytesDownloadedFile + requestedBytes > dailyBytesIn)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                        }

                        break;
                    case MediaCapabilityTransferDirection.Outbound:
                        if (usage.BytesUploadedFile >= dailyBytesOut)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.DailyCapReached);
                        }

                        if (sessionByteBudget != null && requestedBytes > perFileBytes)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                        }

                        if (sessionByteBudget != null && usage.BytesUploadedFile + requestedBytes > dailyBytesOut)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                        }

                        break;
                    case null:
                        if (usage.BytesDownloadedFile >= dailyBytesIn && usage.BytesUploadedFile >= dailyBytesOut)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.DailyCapReached);
                        }

                        if (sessionByteBudget != null && requestedBytes > perFileBytes)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                        }

                        if (sessionByteBudget != null && usage.BytesUploadedFile + requestedBytes > dailyBytesOut)
                        {
                            return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                        }

                        break;
                }

                break;
            }

            case MediaFeature.ScreenShare:
            {
                var dailyCapSeconds = envelope.ScreenShareDailyMinutes * 60;
                if (usage.ScreenShareSecondsUsed >= dailyCapSeconds)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.DailyCapReached);
                }

                if (sessionDurationLimitSeconds is { } limit && limit > envelope.ScreenSharePerSessionMinutes * 60)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                }

                break;
            }

            case MediaFeature.VideoCall:
            {
                var dailyCapSeconds = envelope.VideoCallDailyMinutes * 60;
                if (usage.VideoCallSecondsUsed >= dailyCapSeconds)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.DailyCapReached);
                }

                if (sessionDurationLimitSeconds is { } limit && limit > envelope.VideoCallPerCallMinutes * 60)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                }

                break;
            }

            case MediaFeature.ComputerUse:
            {
                var dailyCapSeconds = envelope.ScreenShareDailyMinutes * 60;
                if (usage.ScreenShareSecondsUsed >= dailyCapSeconds)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.DailyCapReached);
                }

                if (sessionDurationLimitSeconds is { } limit && limit > envelope.ScreenSharePerSessionMinutes * 60)
                {
                    return MediaCapabilityCheck.Denied(MediaCapabilityDenialReason.SessionCapReached);
                }

                break;
            }
        }

        return MediaCapabilityCheck.Allowed(new MediaCapabilityEnvelope(feature));
    }

    /// <summary>Parity: remainingSeconds(feature:envelope:usage:).</summary>
    private static int? RemainingSeconds(MediaFeature feature, MediaBudgetEnvelope envelope, MediaQuotaUsageSnapshot usage) => feature switch
    {
        MediaFeature.FileTransfer => null,
        MediaFeature.ScreenShare => Math.Max(0, envelope.ScreenShareDailyMinutes * 60 - usage.ScreenShareSecondsUsed),
        MediaFeature.VideoCall => Math.Max(0, envelope.VideoCallDailyMinutes * 60 - usage.VideoCallSecondsUsed),
        MediaFeature.ComputerUse => Math.Max(0, envelope.ScreenShareDailyMinutes * 60 - usage.ScreenShareSecondsUsed),
        _ => null,
    };

    /// <summary>Parity: remainingBytes(feature:envelope:usage:).</summary>
    private static long? RemainingBytes(MediaFeature feature, MediaBudgetEnvelope envelope, MediaQuotaUsageSnapshot usage)
    {
        if (feature != MediaFeature.FileTransfer)
        {
            return null;
        }

        var dailyOut = (long)envelope.FileTransferDailyGbOut * BytesPerGb;
        return Math.Max(0, dailyOut - usage.BytesUploadedFile);
    }

    /// <summary>Parity: perSessionMaxSeconds(feature:envelope:).</summary>
    private static int? PerSessionMaxSeconds(MediaFeature feature, MediaBudgetEnvelope envelope) => feature switch
    {
        MediaFeature.FileTransfer => null,
        MediaFeature.ScreenShare => envelope.ScreenSharePerSessionMinutes * 60,
        MediaFeature.VideoCall => envelope.VideoCallPerCallMinutes * 60,
        MediaFeature.ComputerUse => envelope.ScreenSharePerSessionMinutes * 60,
        _ => null,
    };

    /// <summary>Parity: perSessionMaxBytes(feature:envelope:) — 1 GB / file, file-transfer only.</summary>
    private static long? PerSessionMaxBytes(MediaFeature feature) =>
        feature == MediaFeature.FileTransfer ? PerFileMaxBytes : null;
}
