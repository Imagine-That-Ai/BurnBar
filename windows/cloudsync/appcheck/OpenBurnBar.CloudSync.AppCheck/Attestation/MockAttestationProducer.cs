using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.CloudSync.AppCheck.Attestation;

/// <summary>
/// Phase-0 MOCK attestation producer. Emits a well-formed, freshly-signed,
/// single-use <c>"mock"</c> claim that the server's mock verifier accepts under
/// non-production config, and that its production config rejects (no mock verifier
/// registered). Drives all portable macOS <c>dotnet test</c> coverage.
/// </summary>
/// <remarks>
/// The produced claim is byte-parity with the server's <c>signMockAttestation</c>
/// via <see cref="MockAttestationMac"/>. This class does NOT talk to a TPM and is
/// inert in production — it exists so the full mint→install→refresh→attach
/// pipeline is provable off-Windows without a real attestation root.
/// </remarks>
public sealed class MockAttestationProducer : IAttestationProducer
{
    private readonly INonceSource _nonceSource;
    private readonly string _sharedSecret;

    /// <summary>
    /// Create a mock producer.
    /// </summary>
    /// <param name="nonceSource">
    /// Nonce supplier; defaults to a CSPRNG source. Tests inject a deterministic
    /// sequence to pin the produced claim against a golden vector.
    /// </param>
    /// <param name="sharedSecret">
    /// The mock fixture secret; defaults to <see cref="MockAttestationMac.SharedSecret"/>.
    /// Overriding it lets a test prove the server would reject a claim signed with
    /// the wrong secret (forged path).
    /// </param>
    public MockAttestationProducer(INonceSource? nonceSource = null, string? sharedSecret = null)
    {
        _nonceSource = nonceSource ?? new RandomNonceSource();
        _sharedSecret = sharedSecret ?? MockAttestationMac.SharedSecret;
    }

    /// <inheritdoc />
    public string Kind => MockAttestationMac.Kind;

    /// <inheritdoc />
    public bool RequiresServerChallenge => false;

    /// <inheritdoc />
    public ValueTask<WindowsAttestationClaim> ProduceAsync(
        string appId,
        long nowMillis,
        AttestationChallenge? challenge = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(appId))
        {
            throw new ArgumentException("appId is required to bind the attestation.", nameof(appId));
        }
        cancellationToken.ThrowIfCancellationRequested();

        var nonce = challenge?.Nonce ?? _nonceSource.NextNonce();
        var mac = MockAttestationMac.Sign(appId, nonce, nowMillis, _sharedSecret);

        var claim = new WindowsAttestationClaim
        {
            Kind = MockAttestationMac.Kind,
            AppId = appId,
            Nonce = nonce,
            IssuedAtMs = nowMillis,
            Mac = mac,
            ChallengeId = challenge?.ChallengeId,
        };
        return new ValueTask<WindowsAttestationClaim>(claim);
    }
}
