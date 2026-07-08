using System;
using OpenBurnBar.Integrations.Mercury.Sessions;

namespace OpenBurnBar.Integrations.Mercury.Budget;

/// <summary>
/// Mirror of the <c>ops/media_budget_status/state/current</c> Firestore
/// document. Byte-exact port of
/// <c>OpenBurnBarCore/Sources/OpenBurnBarMedia/MediaBudgetEnvelope.swift</c>.
/// Read-only on the client; the canonical writer is the hourly
/// <c>evaluateMediaBudget</c> Cloud Function.
/// </summary>
public sealed class MediaBudgetStatus : IEquatable<MediaBudgetStatus>
{
    public MediaBudgetLevel Level { get; }

    public double ProjectedMonthEndUsd { get; }

    public double MonthToDateUsd { get; }

    public DateTimeOffset LastEvaluatedAt { get; }

    public MediaBudgetEnvelope ActiveEnvelope { get; }

    public MediaBudgetStatus(
        MediaBudgetLevel level,
        double projectedMonthEndUsd,
        double monthToDateUsd,
        DateTimeOffset lastEvaluatedAt,
        MediaBudgetEnvelope activeEnvelope)
    {
        Level = level;
        ProjectedMonthEndUsd = projectedMonthEndUsd;
        MonthToDateUsd = monthToDateUsd;
        LastEvaluatedAt = lastEvaluatedAt;
        ActiveEnvelope = activeEnvelope ?? throw new ArgumentNullException(nameof(activeEnvelope));
    }

    public bool Equals(MediaBudgetStatus? other)
    {
        if (other is null)
        {
            return false;
        }

        return Level == other.Level
            && ProjectedMonthEndUsd.Equals(other.ProjectedMonthEndUsd)
            && MonthToDateUsd.Equals(other.MonthToDateUsd)
            && LastEvaluatedAt.Equals(other.LastEvaluatedAt)
            && ActiveEnvelope.Equals(other.ActiveEnvelope);
    }

    public override bool Equals(object? obj) => Equals(obj as MediaBudgetStatus);

    public override int GetHashCode() =>
        HashCode.Combine(Level, ProjectedMonthEndUsd, MonthToDateUsd, LastEvaluatedAt, ActiveEnvelope);
}

/// <summary>Budget level (parity: MediaBudgetStatus.Level with wire strings).</summary>
public enum MediaBudgetLevel
{
    Normal,
    SoftCap,
    HardCap,
}

/// <summary>Wire-string mapping for <see cref="MediaBudgetLevel"/> (parity: RawValue).</summary>
public static class MediaBudgetLevelWire
{
    public const string Normal = "normal";
    public const string SoftCap = "soft_cap";
    public const string HardCap = "hard_cap";

    public static MediaBudgetLevel Parse(string? raw) => raw switch
    {
        SoftCap => MediaBudgetLevel.SoftCap,
        HardCap => MediaBudgetLevel.HardCap,
        _ => MediaBudgetLevel.Normal,
    };

    public static string ToWire(MediaBudgetLevel level) => level switch
    {
        MediaBudgetLevel.SoftCap => SoftCap,
        MediaBudgetLevel.HardCap => HardCap,
        _ => Normal,
    };
}

/// <summary>
/// Per-feature caps (parity: MediaBudgetEnvelope). The three static presets
/// match the master plan § F.2 capability matrix exactly.
/// </summary>
public sealed class MediaBudgetEnvelope : IEquatable<MediaBudgetEnvelope>
{
    public int ScreenShareDailyMinutes { get; }

    public int ScreenSharePerSessionMinutes { get; }

    public int VideoCallDailyMinutes { get; }

    public int VideoCallPerCallMinutes { get; }

    public int FileTransferDailyGbIn { get; }

    public int FileTransferDailyGbOut { get; }

    public MediaBudgetEnvelope(
        int screenShareDailyMinutes,
        int screenSharePerSessionMinutes,
        int videoCallDailyMinutes,
        int videoCallPerCallMinutes,
        int fileTransferDailyGbIn,
        int fileTransferDailyGbOut)
    {
        ScreenShareDailyMinutes = screenShareDailyMinutes;
        ScreenSharePerSessionMinutes = screenSharePerSessionMinutes;
        VideoCallDailyMinutes = videoCallDailyMinutes;
        VideoCallPerCallMinutes = videoCallPerCallMinutes;
        FileTransferDailyGbIn = fileTransferDailyGbIn;
        FileTransferDailyGbOut = fileTransferDailyGbOut;
    }

    /// <summary>Caps in normal mode (parity: MediaBudgetEnvelope.normal).</summary>
    public static readonly MediaBudgetEnvelope Normal = new(120, 60, 240, 30, 5, 5);

    /// <summary>Soft-cap envelope, tightened past $600/mo (parity: .softCap).</summary>
    public static readonly MediaBudgetEnvelope SoftCap = new(30, 30, 120, 20, 2, 2);

    /// <summary>Hard-cap envelope — effectively zero (parity: .hardCap).</summary>
    public static readonly MediaBudgetEnvelope HardCap = new(0, 0, 0, 0, 0, 0);

    /// <summary>
    /// Whether a session of the given feature can start under this envelope
    /// (parity: allowsSession(for:)). <c>false</c> means the per-session ceiling
    /// is zero and the receiver must refuse the session.
    /// </summary>
    public bool AllowsSession(MediaFeature feature) => feature switch
    {
        MediaFeature.FileTransfer => FileTransferDailyGbIn > 0 || FileTransferDailyGbOut > 0,
        MediaFeature.ScreenShare => ScreenSharePerSessionMinutes > 0,
        MediaFeature.ComputerUse => ScreenSharePerSessionMinutes > 0,
        MediaFeature.VideoCall => VideoCallPerCallMinutes > 0,
        _ => false,
    };

    public bool Equals(MediaBudgetEnvelope? other)
    {
        if (other is null)
        {
            return false;
        }

        return ScreenShareDailyMinutes == other.ScreenShareDailyMinutes
            && ScreenSharePerSessionMinutes == other.ScreenSharePerSessionMinutes
            && VideoCallDailyMinutes == other.VideoCallDailyMinutes
            && VideoCallPerCallMinutes == other.VideoCallPerCallMinutes
            && FileTransferDailyGbIn == other.FileTransferDailyGbIn
            && FileTransferDailyGbOut == other.FileTransferDailyGbOut;
    }

    public override bool Equals(object? obj) => Equals(obj as MediaBudgetEnvelope);

    public override int GetHashCode() => HashCode.Combine(
        ScreenShareDailyMinutes,
        ScreenSharePerSessionMinutes,
        VideoCallDailyMinutes,
        VideoCallPerCallMinutes,
        FileTransferDailyGbIn,
        FileTransferDailyGbOut);
}
