using System;

namespace OpenBurnBar.CloudSync.Sync;

/// <summary>
/// Exponential-with-cap backoff for the live sync poll loop. A pure function of the
/// consecutive-failure count, so the schedule is unit-testable without sleeping.
/// Mirrors the Swift <c>CloudSyncBackoffPolicy</c> intent (grow the retry gap on
/// repeated permission/transport faults, never hammer a failing backend).
/// </summary>
public sealed class SyncBackoffPolicy
{
    public long BaseDelayMillis { get; }
    public long MaxDelayMillis { get; }
    public double Multiplier { get; }

    public SyncBackoffPolicy(long baseDelayMillis = 2_000, long maxDelayMillis = 5 * 60_000, double multiplier = 2.0)
    {
        if (baseDelayMillis <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(baseDelayMillis), baseDelayMillis, "Base delay must be positive.");
        }
        if (maxDelayMillis < baseDelayMillis)
        {
            throw new ArgumentOutOfRangeException(nameof(maxDelayMillis), maxDelayMillis, "Max delay must be >= base delay.");
        }
        if (multiplier < 1.0)
        {
            throw new ArgumentOutOfRangeException(nameof(multiplier), multiplier, "Multiplier must be >= 1.");
        }
        BaseDelayMillis = baseDelayMillis;
        MaxDelayMillis = maxDelayMillis;
        Multiplier = multiplier;
    }

    /// <summary>The default policy (2s base, ×2, capped at 5 min).</summary>
    public static SyncBackoffPolicy Default { get; } = new();

    /// <summary>
    /// The delay before the next attempt after <paramref name="consecutiveFailures"/>
    /// consecutive failures (1 = the first failure). Zero/negative ⇒ base delay.
    /// The result is capped at <see cref="MaxDelayMillis"/> and never overflows.
    /// </summary>
    public long DelayMillisFor(int consecutiveFailures)
    {
        if (consecutiveFailures <= 1)
        {
            return BaseDelayMillis;
        }

        double delay = BaseDelayMillis;
        for (int i = 1; i < consecutiveFailures && delay < MaxDelayMillis; i++)
        {
            delay *= Multiplier;
        }
        if (double.IsInfinity(delay) || delay > MaxDelayMillis)
        {
            return MaxDelayMillis;
        }
        return (long)delay;
    }
}
