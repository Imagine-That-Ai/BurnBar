namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// An installed Firebase sign-in session: the current Firebase id token, the
/// refresh token used to renew it, the resolved Firebase uid, and the mint-time
/// clock reading so expiry/refresh math never depends on parsing the JWT.
/// </summary>
/// <remarks>
/// Mirrors the App Check <c>AppCheckToken</c> TTL discipline: the client records
/// <see cref="MintedAtMs"/> (the injected clock reading at install time) so that
/// <see cref="ExpiresAtMs"/> and <see cref="ShouldRefresh"/> are computed against the
/// same injectable clock and never trust a client-uncontrolled expiry field.
/// </remarks>
public sealed record FirebaseOAuthSession
{
    /// <summary>The Firebase id token for <c>Authorization: Bearer</c> (Firestore + App Check mint).</summary>
    public required string IdToken { get; init; }

    /// <summary>The Firebase refresh token used at the <c>securetoken</c> endpoint.</summary>
    public required string RefreshToken { get; init; }

    /// <summary>The Firebase uid (<c>localId</c> / <c>user_id</c>).</summary>
    public required string Uid { get; init; }

    /// <summary>Server-granted lifetime in milliseconds (Firebase id tokens are ~1h).</summary>
    public required long TtlMillis { get; init; }

    /// <summary>Client clock reading (epoch millis) at the moment the token was installed.</summary>
    public required long MintedAtMs { get; init; }

    /// <summary>The signed-in account's email, when the provider returned one.</summary>
    public string? Email { get; init; }

    /// <summary>Absolute expiry instant in epoch millis.</summary>
    public long ExpiresAtMs => MintedAtMs + TtlMillis;

    /// <summary>True once the token has reached or passed its expiry instant.</summary>
    public bool IsExpired(long nowMillis) => nowMillis >= ExpiresAtMs;

    /// <summary>
    /// True when the token is within <paramref name="refreshLeadMillis"/> of expiry
    /// (or already expired) and should be proactively refreshed.
    /// </summary>
    public bool ShouldRefresh(long nowMillis, long refreshLeadMillis) =>
        nowMillis >= ExpiresAtMs - refreshLeadMillis;
}
