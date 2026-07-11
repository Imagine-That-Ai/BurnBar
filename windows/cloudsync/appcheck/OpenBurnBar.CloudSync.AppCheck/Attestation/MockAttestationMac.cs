using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.CloudSync.AppCheck.Attestation;

/// <summary>
/// The Phase-0 MOCK attestation MAC — the exact client-side mirror of the
/// server's <c>signMockAttestation</c> in
/// <c>functions/src/callables/windowsAppCheck.ts</c>.
/// </summary>
/// <remarks>
/// PARITY CONTRACT (byte-identical to the TypeScript server):
/// <code>
///   payload = `${DOMAIN}|${appId}|${nonce}|${issuedAtMs}|${secret}`
///   mac     = sha256(payload) as lowercase hex
/// </code>
/// with
/// <code>
///   DOMAIN = "openburnbar.appcheck.windows.mock.v1"
///   SECRET = "openburnbar-windows-appcheck-mock-fixture-secret"
/// </code>
/// The server computes the same value and constant-time compares it against the
/// claim's <c>mac</c>; a single differing byte is rejected as <c>forged</c>. The
/// committed golden vectors in
/// <c>windows/tests/cloudsync-appcheck/Fixtures/mock-attestation-vectors.json</c>
/// were produced by an INDEPENDENT oracle (openssl sha256) and pin this parity,
/// so a drift in either the domain string, the field order, the separator, the
/// secret, or the hex casing fails a test rather than silently minting nothing.
///
/// This is the MOCK fixture secret ONLY. It is inert in production: the server
/// never registers the mock verifier under production config, so a mock claim can
/// never mint there. The real TPM producer (AC-013) does NOT use this class.
/// </remarks>
public static class MockAttestationMac
{
    /// <summary>
    /// Domain-separation prefix for the mock attestation MAC. Distinct from any
    /// real attestation domain so a mock signature can never be mistaken for a
    /// real one. Must equal the server's <c>MOCK_ATTESTATION_DOMAIN</c>.
    /// </summary>
    public const string Domain = "openburnbar.appcheck.windows.mock.v1";

    /// <summary>
    /// Shared secret for the MOCK fixture ONLY (never a production secret). Must
    /// equal the server's <c>MOCK_ATTESTATION_SHARED_SECRET</c>.
    /// </summary>
    public const string SharedSecret = "openburnbar-windows-appcheck-mock-fixture-secret";

    /// <summary>The claim <see cref="WindowsAttestationClaim.Kind"/> value the mock verifier answers to.</summary>
    public const string Kind = "mock";

    /// <summary>Server-enforced lower bound on nonce length.</summary>
    public const int MinNonceLength = 16;

    /// <summary>Server-enforced upper bound on nonce length.</summary>
    public const int MaxNonceLength = 256;

    /// <summary>
    /// Compute the lowercase-hex mock attestation MAC for a claim's fields, using
    /// the exact server domain, field order, separator, and secret.
    /// </summary>
    public static string Sign(string appId, string nonce, long issuedAtMs, string? secret = null)
    {
        if (appId is null) throw new ArgumentNullException(nameof(appId));
        if (nonce is null) throw new ArgumentNullException(nameof(nonce));

        var effectiveSecret = secret ?? SharedSecret;
        // Invariant-culture stringification of the long matches JS number->string
        // for the (large, positive) epoch-millis domain used here.
        var issuedAt = issuedAtMs.ToString(CultureInfo.InvariantCulture);
        var payload = string.Concat(Domain, "|", appId, "|", nonce, "|", issuedAt, "|", effectiveSecret);

        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(payload));
        // net8.0-safe: Convert.ToHexString is uppercase; the server emits lowercase
        // hex (Node's crypto digest("hex")), so lower it to match byte-for-byte.
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
