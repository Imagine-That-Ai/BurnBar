// SHA-256 helpers for the update artifact integrity check.
//
// The feed carries a lowercase-hex SHA-256 of the download artifact (the same
// `sha256` field the macOS latest-macos.json ships). This is a fail-fast
// integrity check that runs BEFORE (and in addition to) the Ed25519 pin-verify;
// it is NOT a substitute for it — an attacker who rewrites the feed's sha256 to
// match a malicious payload still cannot forge the Ed25519 signature over that
// payload. Hex compare is constant-time to avoid leaking match position.

using System;
using System.Security.Cryptography;

namespace OpenBurnBar.Updater.Core.Crypto;

/// <summary>Lowercase-hex SHA-256 digest + constant-time comparison.</summary>
public static class Sha256Digest
{
    /// <summary>Computes the lowercase-hex SHA-256 of <paramref name="data"/>.</summary>
    public static string HexOf(ReadOnlySpan<byte> data)
    {
        Span<byte> digest = stackalloc byte[32];
        SHA256.HashData(data, digest);
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    /// <summary>
    /// True iff the SHA-256 of <paramref name="data"/> equals
    /// <paramref name="expectedHex"/> (case-insensitive), compared in
    /// constant time. Returns false — never throws — for a null / malformed /
    /// wrong-length expected hex so callers fail closed.
    /// </summary>
    public static bool Matches(ReadOnlySpan<byte> data, string? expectedHex)
    {
        if (string.IsNullOrWhiteSpace(expectedHex))
        {
            return false;
        }

        var trimmed = expectedHex.Trim();
        if (trimmed.Length != 64)
        {
            return false;
        }

        byte[] expected;
        try
        {
            expected = Convert.FromHexString(trimmed);
        }
        catch (FormatException)
        {
            return false;
        }

        Span<byte> actual = stackalloc byte[32];
        SHA256.HashData(data, actual);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }
}
