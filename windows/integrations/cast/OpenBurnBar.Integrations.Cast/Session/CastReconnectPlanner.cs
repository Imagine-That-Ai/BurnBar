// Parity source: AgentLens/Services/Cast/CastReconnectStrategy.swift (castWithRecovery)

using System;
using System.Collections.Generic;

namespace OpenBurnBar.Integrations.Cast.Session;

/// <summary>Outcome kind of a single cast attempt.</summary>
public enum CastAttemptOutcomeKind
{
    /// <summary>The cast succeeded.</summary>
    Success,

    /// <summary>The cast failed with a reason.</summary>
    Failure,

    /// <summary>The receiver did not respond in time.</summary>
    Timeout,
}

/// <summary>The result of one cast attempt within the recovery loop.</summary>
public sealed record CastAttemptOutcome
{
    /// <summary>Classification of this attempt.</summary>
    public required CastAttemptOutcomeKind Kind { get; init; }

    /// <summary>Session id when <see cref="Kind"/> is <see cref="CastAttemptOutcomeKind.Success"/>.</summary>
    public string? SessionId { get; init; }

    /// <summary>Reason when <see cref="Kind"/> is <see cref="CastAttemptOutcomeKind.Failure"/>.</summary>
    public string? Reason { get; init; }

    /// <summary>A successful attempt.</summary>
    public static CastAttemptOutcome Ok(string sessionId)
        => new() { Kind = CastAttemptOutcomeKind.Success, SessionId = sessionId };

    /// <summary>A failed attempt.</summary>
    public static CastAttemptOutcome Failed(string reason)
        => new() { Kind = CastAttemptOutcomeKind.Failure, Reason = reason };

    /// <summary>A timed-out attempt.</summary>
    public static CastAttemptOutcome TimedOut()
        => new() { Kind = CastAttemptOutcomeKind.Timeout };
}

/// <summary>Outcome kind of the Home Assistant recovery fallback.</summary>
public enum HomeAssistantOutcomeKind
{
    /// <summary>No webhook was configured, so recovery was skipped.</summary>
    Skipped,

    /// <summary>The webhook accepted the recovery request.</summary>
    Triggered,

    /// <summary>The webhook was attempted but failed.</summary>
    Failed,
}

/// <summary>The result of the Home Assistant recovery fallback.</summary>
public sealed record HomeAssistantOutcome
{
    /// <summary>Classification of the fallback.</summary>
    public required HomeAssistantOutcomeKind Kind { get; init; }

    /// <summary>Failure reason when <see cref="Kind"/> is <see cref="HomeAssistantOutcomeKind.Failed"/>.</summary>
    public string? FailureReason { get; init; }

    /// <summary>Recovery was skipped (no webhook).</summary>
    public static readonly HomeAssistantOutcome Skipped = new() { Kind = HomeAssistantOutcomeKind.Skipped };

    /// <summary>Recovery request accepted.</summary>
    public static readonly HomeAssistantOutcome Triggered = new() { Kind = HomeAssistantOutcomeKind.Triggered };

    /// <summary>Recovery attempted but failed.</summary>
    public static HomeAssistantOutcome Fail(string reason)
        => new() { Kind = HomeAssistantOutcomeKind.Failed, FailureReason = reason };
}

/// <summary>Final classification of the whole reconnect + recovery flow.</summary>
public enum CastRecoveryResultKind
{
    /// <summary>Native Cast succeeded.</summary>
    Success,

    /// <summary>Native Cast failed but Home Assistant recovered.</summary>
    RecoveredViaHomeAssistant,

    /// <summary>Every path failed.</summary>
    Failure,
}

/// <summary>The terminal result of <see cref="CastReconnectPlanner"/>.</summary>
public sealed record CastRecoveryResult
{
    /// <summary>Classification.</summary>
    public required CastRecoveryResultKind Kind { get; init; }

    /// <summary>Session id when successful.</summary>
    public string? SessionId { get; init; }

    /// <summary>Human-readable message (recovery note or failure reason).</summary>
    public string? Message { get; init; }

    /// <summary>Number of native attempts made when the flow failed.</summary>
    public int AttemptsMade { get; init; }
}

/// <summary>
/// Pure decision core for auto-recovery: the backoff schedule + the final
/// classification of an attempt sequence and the Home Assistant fallback. Port
/// of <c>CastReconnectStrategy.castWithRecovery</c>; the timing and the actual
/// socket work belong to the Windows adapter, which consults this to know how
/// many attempts to make, how long to back off, and how to label the result.
/// </summary>
public static class CastReconnectPlanner
{
    /// <summary>Exponential backoff between attempts: 1s, 2s, 4s, 8s.</summary>
    public static readonly IReadOnlyList<TimeSpan> BackoffSchedule = new[]
    {
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
    };

    /// <summary>Number of native cast attempts before falling back to Home Assistant.</summary>
    public static int MaxAttempts => BackoffSchedule.Count;

    /// <summary>Standard message shown when a request times out.</summary>
    public const string TimeoutReason = "Hub didn't respond in time";

    /// <summary>The backoff to wait after attempt <paramref name="attemptIndex"/> (0-based).</summary>
    public static TimeSpan BackoffAfter(int attemptIndex)
    {
        if (attemptIndex < 0 || attemptIndex >= BackoffSchedule.Count)
        {
            throw new ArgumentOutOfRangeException(nameof(attemptIndex));
        }

        return BackoffSchedule[attemptIndex];
    }

    /// <summary>
    /// Classify the whole flow from the ordered native-attempt outcomes and the
    /// Home Assistant fallback outcome. The first successful attempt wins; a
    /// fully-failed sequence is labeled by the fallback (recovered / failed).
    /// </summary>
    public static CastRecoveryResult Resolve(
        string deviceFriendlyName,
        IReadOnlyList<CastAttemptOutcome> attempts,
        HomeAssistantOutcome homeAssistant)
    {
        if (deviceFriendlyName is null)
        {
            throw new ArgumentNullException(nameof(deviceFriendlyName));
        }

        if (attempts is null)
        {
            throw new ArgumentNullException(nameof(attempts));
        }

        if (homeAssistant is null)
        {
            throw new ArgumentNullException(nameof(homeAssistant));
        }

        var lastError = "Unknown";
        foreach (var attempt in attempts)
        {
            switch (attempt.Kind)
            {
                case CastAttemptOutcomeKind.Success:
                    return new CastRecoveryResult
                    {
                        Kind = CastRecoveryResultKind.Success,
                        SessionId = attempt.SessionId ?? string.Empty,
                    };
                case CastAttemptOutcomeKind.Failure:
                    lastError = attempt.Reason ?? "Unknown";
                    break;
                case CastAttemptOutcomeKind.Timeout:
                    lastError = TimeoutReason;
                    break;
            }
        }

        return homeAssistant.Kind switch
        {
            HomeAssistantOutcomeKind.Triggered => new CastRecoveryResult
            {
                Kind = CastRecoveryResultKind.RecoveredViaHomeAssistant,
                Message =
                    $"Native Cast could not reach {deviceFriendlyName}, so Home Assistant was asked to recover and cast the dashboard.",
            },
            HomeAssistantOutcomeKind.Failed => new CastRecoveryResult
            {
                Kind = CastRecoveryResultKind.Failure,
                Message = $"{lastError} Home Assistant recovery also failed: {homeAssistant.FailureReason}",
                AttemptsMade = MaxAttempts,
            },
            _ => new CastRecoveryResult
            {
                Kind = CastRecoveryResultKind.Failure,
                Message = lastError,
                AttemptsMade = MaxAttempts,
            },
        };
    }
}
