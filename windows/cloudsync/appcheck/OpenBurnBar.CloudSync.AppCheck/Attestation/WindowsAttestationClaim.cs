using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.AppCheck.Attestation;

/// <summary>
/// A Windows platform attestation claim presented to the greenfield
/// <c>mintWindowsAppCheckToken</c> callable (Phase 0 / AC-011, server half in
/// <c>functions/src/callables/windowsAppCheck.ts</c>).
/// </summary>
/// <remarks>
/// This record is the CLIENT mirror of the server's <c>WindowsAttestationClaim</c>
/// interface. The JSON wire shape MUST stay byte-identical to the server's
/// <c>parseAttestationClaim</c> reader: camelCase keys <c>kind</c>, <c>appId</c>,
/// <c>nonce</c>, <c>issuedAtMs</c>, <c>mac</c>. The property-name attributes pin
/// the wire names so a future rename of a C# property can never silently break
/// the wire contract.
///
/// A Windows client cannot use Apple App Attest or Android Play Integrity, so it
/// proves it is a genuine, unmodified app via a platform attestation (a TPM quote
/// in the real design — AC-013) and exchanges that attestation for a Firebase App
/// Check token. In Phase 0 the only accepted <see cref="Kind"/> is
/// <c>"mock"</c> (<see cref="MockAttestationProducer"/>); the real TPM producer
/// (<c>OpenBurnBar.CloudSync.AppCheck.Windows.TpmAttestationProducer</c>) emits a
/// different kind that AC-013's server verifier accepts.
/// </remarks>
public sealed record WindowsAttestationClaim
{
    /// <summary>Verifier discriminator, e.g. <c>"mock"</c> or <c>"tpm"</c>.</summary>
    [JsonPropertyName("kind")]
    public required string Kind { get; init; }

    /// <summary>App Check app id the attestation is bound to (must be allowlisted server-side).</summary>
    [JsonPropertyName("appId")]
    public required string AppId { get; init; }

    /// <summary>Single-use, replay-defeating nonce (16..256 chars, per the server bounds).</summary>
    [JsonPropertyName("nonce")]
    public required string Nonce { get; init; }

    /// <summary>Client-asserted issue time in epoch millis (freshness-checked server-side).</summary>
    [JsonPropertyName("issuedAtMs")]
    public required long IssuedAtMs { get; init; }

    /// <summary>Attestation signature/MAC over the claim (lowercase hex).</summary>
    [JsonPropertyName("mac")]
    public required string Mac { get; init; }
}
