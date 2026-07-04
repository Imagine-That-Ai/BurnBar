using System;

namespace OpenBurnBar.CloudSync.AppCheck.Token;

/// <summary>
/// Monotonic-enough wall clock seam. Abstracted so TTL / refresh / expiry logic is
/// deterministically testable without sleeping. The mint pipeline reads epoch
/// millis from here for both the attestation <c>issuedAtMs</c> and the token
/// freshness math, so a single injected clock drives the whole timeline in tests.
/// </summary>
public interface IClock
{
    /// <summary>Current time in epoch milliseconds (UTC).</summary>
    long NowMillis { get; }
}

/// <summary>Production clock backed by <see cref="DateTimeOffset.UtcNow"/>.</summary>
public sealed class SystemClock : IClock
{
    public static readonly SystemClock Instance = new();

    public long NowMillis => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// <summary>
/// Test / deterministic clock whose time is set explicitly and advanced by hand.
/// </summary>
public sealed class MutableClock : IClock
{
    private long _nowMillis;

    public MutableClock(long nowMillis)
    {
        _nowMillis = nowMillis;
    }

    public long NowMillis => _nowMillis;

    /// <summary>Advance the clock by <paramref name="deltaMillis"/> (may be negative for skew tests).</summary>
    public void Advance(long deltaMillis)
    {
        _nowMillis += deltaMillis;
    }

    /// <summary>Jump the clock to an absolute epoch-millis instant.</summary>
    public void Set(long nowMillis)
    {
        _nowMillis = nowMillis;
    }
}
