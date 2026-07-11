using System.Text.Json.Serialization;

namespace OpenBurnBar.CloudSync.Callable;

// Concrete callable example: the Phase-0 Windows App Check mint endpoint
// (functions/src/callables/windowsAppCheck.ts, AC-011). These types define the
// request `data` and the success `result` payloads exactly as the callable
// contract specifies, so the request/response ENVELOPE round-trip is proven
// against a real endpoint shape (not a toy).

/// <summary>A Windows platform attestation claim presented to the mint endpoint.</summary>
public sealed record WindowsAttestationClaim
{
    [JsonPropertyName("kind")] public required string Kind { get; init; }
    [JsonPropertyName("appId")] public required string AppId { get; init; }
    [JsonPropertyName("nonce")] public required string Nonce { get; init; }
    [JsonPropertyName("issuedAtMs")] public required long IssuedAtMs { get; init; }
    [JsonPropertyName("mac")] public required string Mac { get; init; }
}

/// <summary>The <c>data</c> payload for <c>mintWindowsAppCheckToken</c>.</summary>
public sealed record MintWindowsAppCheckTokenRequest
{
    [JsonPropertyName("attestation")] public required WindowsAttestationClaim Attestation { get; init; }
    [JsonPropertyName("ttlMillis")] public long? TtlMillis { get; init; }
}

/// <summary>The <c>result</c> payload from <c>mintWindowsAppCheckToken</c> (<c>{ ok, ...result }</c>).</summary>
public sealed record MintWindowsAppCheckTokenResult
{
    [JsonPropertyName("ok")] public required bool Ok { get; init; }
    [JsonPropertyName("appCheckToken")] public required string AppCheckToken { get; init; }
    [JsonPropertyName("ttlMillis")] public required long TtlMillis { get; init; }
    [JsonPropertyName("appId")] public required string AppId { get; init; }
}
