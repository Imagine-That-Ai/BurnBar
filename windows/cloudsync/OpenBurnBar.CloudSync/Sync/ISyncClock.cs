using System;

namespace OpenBurnBar.CloudSync.Sync;

/// <summary>
/// The injectable wall-clock seam for the live Firestore sync orchestration
/// (poll cadence + backoff timing), so the coordinator's timeline is
/// deterministically testable without sleeping.
/// </summary>
/// <remarks>
/// This mirrors the repo's standardized clock discipline (the App Check
/// <c>OpenBurnBar.CloudSync.AppCheck.Token.IClock</c>: epoch-millis + a
/// <see cref="SystemSyncClock"/> production reader + a hand-advanced test clock).
/// It is intentionally re-declared in this dependency-free base module rather than
/// referenced from AppCheck, because <c>OpenBurnBar.CloudSync</c> is a sibling of
/// <c>OpenBurnBar.CloudSync.AppCheck</c> and must not take an upward dependency on
/// the App Check client just to read the time. Same shape, same discipline.
/// </remarks>
public interface ISyncClock
{
    /// <summary>Current time in epoch milliseconds (UTC).</summary>
    long NowMillis { get; }
}

/// <summary>Production clock backed by <see cref="DateTimeOffset.UtcNow"/>.</summary>
public sealed class SystemSyncClock : ISyncClock
{
    public static readonly SystemSyncClock Instance = new();

    public long NowMillis => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// <summary>Test / deterministic clock whose time is set explicitly and advanced by hand.</summary>
public sealed class MutableSyncClock : ISyncClock
{
    private long _nowMillis;

    public MutableSyncClock(long nowMillis) => _nowMillis = nowMillis;

    public long NowMillis => _nowMillis;

    /// <summary>Advance the clock by <paramref name="deltaMillis"/> (may be negative for skew tests).</summary>
    public void Advance(long deltaMillis) => _nowMillis += deltaMillis;

    /// <summary>Jump the clock to an absolute epoch-millis instant.</summary>
    public void Set(long nowMillis) => _nowMillis = nowMillis;
}
