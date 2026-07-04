// Canonical App Check attestation digest.
//
// Port of AppCheckAttestationBinding.swift. The wire field
// `attestationHashBlake3` carries the controller app's SHA-256 hex digest (the
// name is historical). The digest binds the token to the presenting app id + a
// bind timestamp; freshness is bounded to 30 days.

using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.ComputerUse.Core;

/// <summary>Deterministic App Check attestation digest, shared with Mac/iOS/Cloud.</summary>
public static class AppCheckAttestationBinding
{
    /// <summary>Claim key inside the App Check token payload.</summary>
    public const string ClaimKey = "obb_app_check";

    /// <summary>Domain-separation prefix mixed into the digest.</summary>
    public const string CanonicalPrefix = "openburnbar.appcheck.v1";

    /// <summary>Maximum claim age — 30 days in milliseconds.</summary>
    public const long MaxAgeMillis = 30L * 24 * 60 * 60 * 1000;

    /// <summary>A parsed attestation claim.</summary>
    public sealed class Claim
    {
        public Claim(string appId, long boundAtMillis)
        {
            AppId = appId ?? throw new ArgumentNullException(nameof(appId));
            BoundAtMillis = boundAtMillis;
        }

        public string AppId { get; }

        public long BoundAtMillis { get; }
    }

    /// <summary>SHA-256 hex digest binding <paramref name="appId"/> at <paramref name="boundAtMillis"/>.</summary>
    public static string DigestHex(string appId, long boundAtMillis)
    {
        var payload = $"{CanonicalPrefix}|{appId}|{boundAtMillis.ToString(CultureInfo.InvariantCulture)}";
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(payload));
        var builder = new StringBuilder(hash.Length * 2);
        foreach (var b in hash)
        {
            builder.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        }

        return builder.ToString();
    }

    /// <summary>SHA-256 hex digest for <paramref name="claim"/>.</summary>
    public static string DigestHex(Claim claim) => DigestHex(claim.AppId, claim.BoundAtMillis);

    /// <summary>True iff <paramref name="claim"/> is within the freshness window at <paramref name="nowMillis"/>.</summary>
    public static bool IsFresh(Claim claim, long nowMillis)
        => nowMillis - claim.BoundAtMillis <= MaxAgeMillis;
}
