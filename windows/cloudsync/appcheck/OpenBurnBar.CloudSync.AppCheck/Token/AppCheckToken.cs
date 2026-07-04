using System;

namespace OpenBurnBar.CloudSync.AppCheck.Token;

/// <summary>
/// An installed Firebase App Check token, minted by the server's
/// <c>mintWindowsAppCheckToken</c> callable and stamped with the client's mint
/// time so its expiry and refresh window are computable against an <see cref="IClock"/>.
/// </summary>
/// <remarks>
/// The server returns only <c>appCheckToken</c>, <c>ttlMillis</c>, and <c>appId</c>;
/// the client records <see cref="MintedAtMs"/> (the clock reading at install time)
/// so that <see cref="ExpiresAtMs"/> and <see cref="ShouldRefresh"/> never depend on
/// parsing the JWT. This keeps the refresh logic simple and testable and never
/// trusts a client-uncontrolled expiry field.
/// </remarks>
public sealed record AppCheckToken
{
    /// <summary>The opaque App Check JWT to attach as <c>X-Firebase-AppCheck</c>.</summary>
    public required string Token { get; init; }

    /// <summary>Server-granted TTL in milliseconds (30 min .. 7 days per Firebase).</summary>
    public required long TtlMillis { get; init; }

    /// <summary>The App Check app id the token is bound to.</summary>
    public required string AppId { get; init; }

    /// <summary>Client clock reading (epoch millis) at the moment the token was installed.</summary>
    public required long MintedAtMs { get; init; }

    /// <summary>Absolute expiry instant in epoch millis (<see cref="MintedAtMs"/> + <see cref="TtlMillis"/>).</summary>
    public long ExpiresAtMs => MintedAtMs + TtlMillis;

    /// <summary>Milliseconds until expiry relative to <paramref name="nowMillis"/> (negative once expired).</summary>
    public long RemainingMillis(long nowMillis) => ExpiresAtMs - nowMillis;

    /// <summary>True once the token has reached or passed its expiry instant.</summary>
    public bool IsExpired(long nowMillis) => nowMillis >= ExpiresAtMs;

    /// <summary>
    /// True when the token should be proactively refreshed: it is within
    /// <paramref name="refreshLeadMillis"/> of expiry (or already expired). A
    /// non-positive lead degenerates to "refresh only once expired".
    /// </summary>
    public bool ShouldRefresh(long nowMillis, long refreshLeadMillis)
    {
        if (refreshLeadMillis < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(refreshLeadMillis), refreshLeadMillis, "Refresh lead must be non-negative.");
        }
        return nowMillis >= ExpiresAtMs - refreshLeadMillis;
    }
}
