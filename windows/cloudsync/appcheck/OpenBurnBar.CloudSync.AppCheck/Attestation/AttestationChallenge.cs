namespace OpenBurnBar.CloudSync.AppCheck.Attestation;

/// <summary>A single-use server challenge that a platform attestation must bind.</summary>
public sealed record AttestationChallenge
{
    public required string ChallengeId { get; init; }
    public required string Nonce { get; init; }
    public required long ExpiresAtMs { get; init; }
}
