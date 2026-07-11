// The pinned Ed25519 feed public key + how it reaches the app.
//
// R19 invariant: this key is PINNED and INDEPENDENT of the Authenticode signing
// certificate — exactly as macOS pins SUPublicEDKey in Info.plist independent of
// the codesign identity. It is NOT baked into this portable core: the core takes
// it at construction so (a) the real PRODUCTION key can be injected at build
// time from a CI secret (W0 procurement, dev-host/CI-deferred) without editing
// code, and (b) the tests can inject an ephemeral key. Rotating the key is a
// build-input change, never a code change.
//
// The public key is safe to embed in the shipped binary; only the matching
// PRIVATE key (held in the release signer / CI secret store) can mint a feed
// signature. A build MUST refuse to start its updater with an empty or malformed
// pin — TryLoad returns null so the caller fails closed.

using OpenBurnBar.Updater.Core.Crypto;

namespace OpenBurnBar.Updater.Core.Verification;

/// <summary>A validated, base64 pinned Ed25519 update-feed public key.</summary>
public readonly struct PinnedUpdateKey
{
    private PinnedUpdateKey(string base64) => Base64 = base64;

    /// <summary>The 32-byte raw Ed25519 public key, base64.</summary>
    public string Base64 { get; }

    /// <summary>
    /// Validates a candidate pinned key, returning null if it is empty, not
    /// base64, or not 32 bytes. A null result MUST disable the updater rather
    /// than fall through to an unpinned "verify against nothing" path.
    /// </summary>
    public static PinnedUpdateKey? TryLoad(string? base64)
    {
        var verifier = Ed25519UpdateSignatureVerifier.FromBase64PublicKey(base64);
        return verifier is null ? null : new PinnedUpdateKey(verifier.PinnedPublicKeyBase64);
    }

    /// <summary>Builds a feed verifier bound to this pinned key.</summary>
    public UpdateFeedVerifier CreateVerifier() =>
        new(Ed25519UpdateSignatureVerifier.FromBase64PublicKey(Base64)!);

    public override string ToString() => Base64;
}
