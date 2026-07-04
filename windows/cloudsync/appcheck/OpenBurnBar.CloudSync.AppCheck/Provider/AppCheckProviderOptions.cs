using System;

namespace OpenBurnBar.CloudSync.AppCheck.Provider;

/// <summary>
/// Configuration for <see cref="WindowsAppCheckProvider"/>.
/// </summary>
public sealed record AppCheckProviderOptions
{
    /// <summary>The App Check app id the attestation is bound to and the token is minted for.</summary>
    public required string AppId { get; init; }

    /// <summary>
    /// Proactive-refresh lead time in milliseconds: the provider mints a fresh
    /// token once the cached one is within this window of expiry, so a valid token
    /// is always on hand before the old one lapses. Defaults to 5 minutes,
    /// comfortably inside the server's 30-minute minimum TTL.
    /// </summary>
    public long RefreshLeadMillis { get; init; } = 5 * 60 * 1000;

    /// <summary>
    /// Optional requested TTL for the minted token; the server clamps to
    /// 30 min .. 7 days. Null lets the server apply its 30-minute default.
    /// </summary>
    public long? RequestedTtlMillis { get; init; }

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(AppId))
        {
            throw new ArgumentException("AppId is required.", nameof(AppId));
        }
        if (RefreshLeadMillis < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(RefreshLeadMillis), RefreshLeadMillis, "RefreshLeadMillis must be non-negative.");
        }
    }
}
