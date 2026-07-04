// Canonical-JSON hasher for the audit chain.
//
// Port of ComputerUseAuditHasher (OpenBurnBarComputerUseCore). Two requirements
// keep the chain re-hashable byte-identically across runtimes:
//   * canonical JSON (sorted keys, omitted nulls) — CanonicalJson, and
//   * dates encoded as an Int64 millisecond count — the caller supplies that.
//
// The algorithm is SHA-256 (the Swift field names say "Blake3", reflecting the
// long-term intent to upgrade once an iroh-blobs Swift binding lands; the
// validator re-hashes with whatever primitive wrote the chain). The genesis
// parent hash — 64 hex zeros — seeds a fresh chain.

using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Crypto;

/// <summary>Hex-digest hasher over canonical JSON, SHA-256.</summary>
public sealed class AuditHasher
{
    /// <summary>The shared SHA-256 hasher instance.</summary>
    public static readonly AuditHasher Current = new();

    /// <summary>The all-zero 64-hex parent hash that seeds an empty chain.</summary>
    public const string GenesisParentHashHex =
        "0000000000000000000000000000000000000000000000000000000000000000";

    /// <summary>Hex digest of the canonical-JSON encoding of <paramref name="value"/>.</summary>
    public string Hash(CanonicalJsonObject value) => Hash(CanonicalJson.Encode(value));

    /// <summary>Hex digest of raw <paramref name="data"/>.</summary>
    public string Hash(ReadOnlySpan<byte> data)
    {
        Span<byte> digest = stackalloc byte[32];
        if (!SHA256.TryHashData(data, digest, out _))
        {
            throw new CryptographicException("SHA-256 hashing failed.");
        }

        return ToHex(digest);
    }

    private static string ToHex(ReadOnlySpan<byte> bytes)
    {
        var builder = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
        {
            builder.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        }

        return builder.ToString();
    }
}
