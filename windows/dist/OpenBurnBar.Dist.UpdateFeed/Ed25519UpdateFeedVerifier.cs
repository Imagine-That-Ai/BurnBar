// Pinned Ed25519 verification of an update offer (Phase 5 · signed distribution).
//
// The verification is the security kernel of the direct-download updater. It NEVER throws on a
// bad signature/feed — it returns a result whose IsAuthentic is false with a reason — so a
// malformed or tampered offer is always fail-closed (the decision layer maps "not authentic"
// to "no update", never to "install"). BouncyCastle Ed25519 is the same primitive as macOS
// CryptoKit Curve25519.Signing over the same canonical bytes, so a descriptor signed by the
// release pipeline verifies here byte-for-byte.

using System;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>Verifies an <see cref="UpdateFeedEntry"/> against a single PINNED Ed25519 key.</summary>
public sealed class Ed25519UpdateFeedVerifier
{
    private readonly PinnedUpdateKey _pinnedKey;

    /// <summary>Create a verifier bound to a pinned public key. The key itself is validated at
    /// construction (rejecting the placeholder), so a verifier can never exist without a real pin.</summary>
    public Ed25519UpdateFeedVerifier(PinnedUpdateKey pinnedKey)
    {
        _pinnedKey = pinnedKey ?? throw new ArgumentNullException(nameof(pinnedKey));
    }

    /// <summary>
    /// Verify the pinned Ed25519 signature over the canonical descriptor of <paramref name="entry"/>.
    /// Returns a result — never throws — so any failure (missing/oversized/malformed signature,
    /// malformed descriptor field, or a cryptographically invalid signature) is fail-closed.
    /// </summary>
    public UpdateVerificationResult VerifyDescriptor(UpdateFeedEntry entry)
    {
        if (entry is null)
        {
            return UpdateVerificationResult.Rejected(UpdateVerificationFailure.MalformedDescriptor, "Entry was null.");
        }

        if (string.IsNullOrEmpty(entry.Signature))
        {
            return UpdateVerificationResult.Rejected(UpdateVerificationFailure.MissingSignature, "Entry has no signature.");
        }

        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(entry.Signature);
        }
        catch (FormatException)
        {
            return UpdateVerificationResult.Rejected(UpdateVerificationFailure.MalformedSignature, "Signature is not valid base64.");
        }

        if (signature.Length != UpdateDescriptorCanonicalizer.SignatureSize)
        {
            return UpdateVerificationResult.Rejected(
                UpdateVerificationFailure.MalformedSignature,
                $"Signature must be {UpdateDescriptorCanonicalizer.SignatureSize} bytes.");
        }

        byte[] canonical;
        try
        {
            canonical = UpdateDescriptorCanonicalizer.CanonicalBytes(entry);
        }
        catch (FormatException ex)
        {
            return UpdateVerificationResult.Rejected(UpdateVerificationFailure.MalformedDescriptor, ex.Message);
        }

        bool valid;
        try
        {
            var parameters = new Ed25519PublicKeyParameters(_pinnedKey.PublicKey.ToArray(), 0);
            var verifier = new Ed25519Signer();
            verifier.Init(false, parameters);
            verifier.BlockUpdate(canonical, 0, canonical.Length);
            valid = verifier.VerifySignature(signature);
        }
        catch (Exception)
        {
            // A malformed key/signature must never authenticate an update.
            return UpdateVerificationResult.Rejected(UpdateVerificationFailure.InvalidSignature, "Signature verification threw.");
        }

        return valid
            ? UpdateVerificationResult.Authentic(entry)
            : UpdateVerificationResult.Rejected(UpdateVerificationFailure.InvalidSignature, "Signature did not verify under the pinned key.");
    }

    /// <summary>
    /// CONTENT integrity: confirm the downloaded artifact bytes hash to the descriptor's signed
    /// sha256. The full trust chain is: pinned-Ed25519 authenticates the descriptor (incl. the
    /// sha256), then THIS confirms the bytes on disk match that signed sha256. Both are required
    /// before install. Returns false (never throws) on any mismatch.
    /// </summary>
    public static bool VerifyArtifactContent(UpdateFeedEntry entry, ReadOnlySpan<byte> artifactBytes)
    {
        if (entry is null)
        {
            return false;
        }

        string expected;
        try
        {
            expected = UpdateDescriptorCanonicalizer.NormalizeSha256(entry.Sha256);
        }
        catch (FormatException)
        {
            return false;
        }

        Span<byte> digest = stackalloc byte[32];
        if (!System.Security.Cryptography.SHA256.TryHashData(artifactBytes, digest, out _))
        {
            return false;
        }

        var actual = Convert.ToHexString(digest).ToLowerInvariant();
        return CryptographicEquals(expected, actual);
    }

    private static bool CryptographicEquals(string a, string b)
    {
        if (a.Length != b.Length)
        {
            return false;
        }

        var diff = 0;
        for (var i = 0; i < a.Length; i++)
        {
            diff |= a[i] ^ b[i];
        }

        return diff == 0;
    }
}
