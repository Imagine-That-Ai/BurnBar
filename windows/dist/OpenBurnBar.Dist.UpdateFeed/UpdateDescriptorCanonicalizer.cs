// Canonical signable bytes for a release descriptor (Phase 5 · signed distribution).
//
// The pinned Ed25519 key signs THESE bytes, so the signer (release CI) and the verifier
// (the shipped app) must produce byte-identical output for the same logical release. The
// format is a fixed-order, key=value, newline-delimited UTF-8 block with a versioned magic
// header. It is injection-safe: every field value is validated to contain no CR/LF, the
// version is NORMALIZED through UpdateVersion (so "1.0.28" and "1.0.28.0" sign identically),
// and the sha256 must be exactly 64 lowercase hex chars.
//
// SECURITY: the byte format is a signed contract. Changing field order, keys, the magic, or
// the header version is a signature-breaking change and MUST bump FormatVersion (which is
// itself part of the signed bytes) so an old client cannot be tricked by a re-ordered feed.

using System;
using System.Globalization;
using System.Text;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>Produces the deterministic UTF-8 bytes the pinned Ed25519 key signs/verifies.</summary>
public static class UpdateDescriptorCanonicalizer
{
    /// <summary>Magic header line. Never reused for any other signed payload.</summary>
    public const string Magic = "OBBWIN-UPDATE-DESCRIPTOR";

    /// <summary>Canonical format version (part of the signed bytes).</summary>
    public const int FormatVersion = 1;

    /// <summary>Raw Ed25519 public-key length (bytes).</summary>
    public const int PublicKeySize = 32;

    /// <summary>Ed25519 detached-signature length (bytes).</summary>
    public const int SignatureSize = 64;

    /// <summary>
    /// Build the canonical signable bytes for <paramref name="entry"/> (the signature field is
    /// intentionally excluded — it signs everything else). Throws <see cref="FormatException"/>
    /// on any malformed field so a bad descriptor can never be signed AND so verification of a
    /// malformed feed fails closed (the verifier catches and returns invalid).
    /// </summary>
    public static byte[] CanonicalBytes(UpdateFeedEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);

        if (!UpdateVersion.TryParse(entry.Version, out var version) || version is null)
        {
            throw new FormatException($"Descriptor version is not a valid release version: '{entry.Version}'");
        }

        if (entry.SizeBytes < 0)
        {
            throw new FormatException("Descriptor size must be non-negative.");
        }

        if (entry.MinimumOsBuild < 0)
        {
            throw new FormatException("Descriptor minimum OS build must be non-negative.");
        }

        var sha256 = NormalizeSha256(entry.Sha256);
        var url = RequireSingleLine(entry.Url, nameof(entry.Url));
        if (url.Length == 0)
        {
            throw new FormatException("Descriptor url must be non-empty.");
        }

        var releaseNotesUrl = RequireSingleLine(entry.ReleaseNotesUrl ?? string.Empty, nameof(entry.ReleaseNotesUrl));

        var builder = new StringBuilder();
        builder.Append(Magic).Append('\n');
        builder.Append("v").Append(FormatVersion.ToString(CultureInfo.InvariantCulture)).Append('\n');
        builder.Append("version=").Append(version.ToNormalizedString()).Append('\n');
        builder.Append("platform=").Append(entry.Platform.ToToken()).Append('\n');
        builder.Append("channel=").Append(entry.Channel.ToToken()).Append('\n');
        builder.Append("url=").Append(url).Append('\n');
        builder.Append("size=").Append(entry.SizeBytes.ToString(CultureInfo.InvariantCulture)).Append('\n');
        builder.Append("sha256=").Append(sha256).Append('\n');
        builder.Append("minOsBuild=").Append(entry.MinimumOsBuild.ToString(CultureInfo.InvariantCulture)).Append('\n');
        builder.Append("critical=").Append(entry.Critical ? "true" : "false").Append('\n');
        builder.Append("publishedAt=").Append(FormatTimestamp(entry.PublishedAtUtc)).Append('\n');
        builder.Append("releaseNotesUrl=").Append(releaseNotesUrl).Append('\n');

        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    /// <summary>Validate + lowercase a 64-char hex SHA-256. Throws on anything else.</summary>
    public static string NormalizeSha256(string? sha256)
    {
        if (string.IsNullOrEmpty(sha256) || sha256.Length != 64)
        {
            throw new FormatException("Descriptor sha256 must be exactly 64 hex characters.");
        }

        Span<char> normalized = stackalloc char[64];
        for (var i = 0; i < sha256.Length; i++)
        {
            var ch = sha256[i];
            char lowered;
            if (ch is >= '0' and <= '9')
            {
                lowered = ch;
            }
            else if (ch is >= 'a' and <= 'f')
            {
                lowered = ch;
            }
            else if (ch is >= 'A' and <= 'F')
            {
                lowered = (char)(ch - 'A' + 'a');
            }
            else
            {
                throw new FormatException("Descriptor sha256 contains a non-hex character.");
            }

            normalized[i] = lowered;
        }

        return new string(normalized);
    }

    private static string FormatTimestamp(DateTimeOffset timestamp)
    {
        // Fixed-precision ISO-8601 in UTC ('Z'), seconds granularity — deterministic across
        // signer/verifier regardless of the incoming offset.
        return timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
    }

    private static string RequireSingleLine(string value, string field)
    {
        if (value.IndexOf('\n') >= 0 || value.IndexOf('\r') >= 0)
        {
            throw new FormatException($"Descriptor field '{field}' must not contain CR/LF.");
        }

        return value;
    }
}
