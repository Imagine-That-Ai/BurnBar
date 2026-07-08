// The PINNED update-feed public key (Phase 5 · signed distribution).
//
// This is the Windows analog of macOS Sparkle's SUPublicEDKey: the ONE Ed25519 public key the
// shipped app trusts to authenticate update offers, pinned into the binary and INDEPENDENT of
// the Authenticode code-signing certificate. Its private half (WINDOWS_UPDATE_SIGNING_KEY) is
// held only by the release pipeline and never touches the Authenticode / Trusted Signing path.
//
// The real pinned key bytes are injected at release time (the public half of
// WINDOWS_UPDATE_SIGNING_KEY). The compiled-in default below is an all-zero PLACEHOLDER that is
// deliberately REJECTED (fail-closed) — a build that forgets to inject the real pin cannot
// silently trust arbitrary updates; it simply refuses to verify anything.

using System;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>A validated 32-byte Ed25519 public key trusted to sign update offers.</summary>
public sealed class PinnedUpdateKey
{
    private readonly byte[] _publicKey;

    private PinnedUpdateKey(byte[] publicKey) => _publicKey = publicKey;

    /// <summary>The raw 32-byte public key (defensive copy).</summary>
    public ReadOnlySpan<byte> PublicKey => _publicKey;

    /// <summary>The base64 encoding of the pinned public key (for logging / diagnostics).</summary>
    public string ToBase64() => Convert.ToBase64String(_publicKey);

    /// <summary>
    /// Build a pinned key from raw bytes. Throws <see cref="ArgumentException"/> if the length is
    /// wrong or the bytes are the all-zero placeholder (a build that never injected the real pin
    /// must fail closed rather than trust an update).
    /// </summary>
    public static PinnedUpdateKey FromBytes(ReadOnlySpan<byte> publicKey)
    {
        if (publicKey.Length != UpdateDescriptorCanonicalizer.PublicKeySize)
        {
            throw new ArgumentException(
                $"Pinned update key must be exactly {UpdateDescriptorCanonicalizer.PublicKeySize} bytes.",
                nameof(publicKey));
        }

        if (IsAllZero(publicKey))
        {
            throw new ArgumentException(
                "Pinned update key is the all-zero placeholder; inject the real WINDOWS_UPDATE_SIGNING_KEY public half.",
                nameof(publicKey));
        }

        return new PinnedUpdateKey(publicKey.ToArray());
    }

    /// <summary>Build a pinned key from a base64 public key. Throws on malformed base64 or an
    /// invalid/placeholder key (fail-closed).</summary>
    public static PinnedUpdateKey FromBase64(string publicKeyBase64)
    {
        if (string.IsNullOrWhiteSpace(publicKeyBase64))
        {
            throw new ArgumentException("Pinned update key base64 must be non-empty.", nameof(publicKeyBase64));
        }

        byte[] raw;
        try
        {
            raw = Convert.FromBase64String(publicKeyBase64.Trim());
        }
        catch (FormatException ex)
        {
            throw new ArgumentException("Pinned update key is not valid base64.", nameof(publicKeyBase64), ex);
        }

        return FromBytes(raw);
    }

    /// <summary>Try-build a pinned key; false (never throws) on any invalid/placeholder input.</summary>
    public static bool TryFromBase64(string? publicKeyBase64, out PinnedUpdateKey? key)
    {
        key = null;
        if (string.IsNullOrWhiteSpace(publicKeyBase64))
        {
            return false;
        }

        try
        {
            key = FromBase64(publicKeyBase64);
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static bool IsAllZero(ReadOnlySpan<byte> bytes)
    {
        foreach (var b in bytes)
        {
            if (b != 0)
            {
                return false;
            }
        }

        return true;
    }
}
