using System;
using System.Globalization;
using System.Text;
using OpenBurnBar.Updater.Core.Versioning;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Builds the deterministic metadata descriptor signed by the pinned update key.</summary>
public static class UpdateDescriptorCanonicalizer
{
    public const string Magic = "OBBWIN-APPCAST-DESCRIPTOR";
    public const int FormatVersion = 1;

    public static byte[] CanonicalBytes(UpdateReleaseDescriptor release)
    {
        ArgumentNullException.ThrowIfNull(release);

        return CanonicalBytes(
            version: release.Version,
            build: release.Build,
            url: release.DownloadUrl,
            length: release.Length,
            sha256: release.Sha256,
            critical: release.Critical,
            channel: release.Channel,
            minimumSystemVersion: release.MinimumSystemVersion,
            releaseNotesUrl: release.ReleaseNotesUrl);
    }

    public static byte[] CanonicalBytes(UpdateManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(manifest);

        return CanonicalBytes(
            version: manifest.Version,
            build: manifest.Build,
            url: manifest.Url,
            length: manifest.Length,
            sha256: manifest.Sha256,
            critical: manifest.Critical,
            channel: manifest.Channel,
            minimumSystemVersion: manifest.MinimumSystemVersion,
            releaseNotesUrl: manifest.ReleaseNotesUrl);
    }

    private static byte[] CanonicalBytes(
        string version,
        string? build,
        string url,
        long? length,
        string? sha256,
        bool critical,
        string? channel,
        string? minimumSystemVersion,
        string? releaseNotesUrl)
    {
        if (!UpdateVersion.TryParse(version, out var parsedVersion))
        {
            throw new FormatException($"Descriptor version is not valid: '{version}'.");
        }

        if (length is null || length < 0)
        {
            throw new FormatException("Descriptor length must be a non-negative integer.");
        }

        var normalizedSha256 = NormalizeSha256(sha256);
        var normalizedUrl = RequireNonEmptySingleLine(url, nameof(url));
        var normalizedBuild = RequireSingleLine(build ?? string.Empty, nameof(build));
        var normalizedChannel = RequireSingleLine(channel ?? "direct-download", nameof(channel));
        var normalizedMinimumSystemVersion = RequireSingleLine(minimumSystemVersion ?? string.Empty, nameof(minimumSystemVersion));
        var normalizedReleaseNotesUrl = RequireSingleLine(releaseNotesUrl ?? string.Empty, nameof(releaseNotesUrl));

        var builder = new StringBuilder();
        builder.Append(Magic).Append('\n');
        builder.Append("v").Append(FormatVersion.ToString(CultureInfo.InvariantCulture)).Append('\n');
        builder.Append("version=").Append(parsedVersion.ToNormalizedString()).Append('\n');
        builder.Append("build=").Append(normalizedBuild).Append('\n');
        builder.Append("url=").Append(normalizedUrl).Append('\n');
        builder.Append("length=").Append(length.Value.ToString(CultureInfo.InvariantCulture)).Append('\n');
        builder.Append("sha256=").Append(normalizedSha256).Append('\n');
        builder.Append("critical=").Append(critical ? "true" : "false").Append('\n');
        builder.Append("channel=").Append(normalizedChannel).Append('\n');
        builder.Append("minimumSystemVersion=").Append(normalizedMinimumSystemVersion).Append('\n');
        builder.Append("releaseNotesUrl=").Append(normalizedReleaseNotesUrl).Append('\n');
        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    public static string NormalizeSha256(string? sha256)
    {
        if (string.IsNullOrWhiteSpace(sha256) || sha256.Trim().Length != 64)
        {
            throw new FormatException("Descriptor sha256 must be exactly 64 hex characters.");
        }

        var trimmed = sha256.Trim();
        Span<char> normalized = stackalloc char[64];
        for (var i = 0; i < trimmed.Length; i++)
        {
            var ch = trimmed[i];
            if (ch is >= '0' and <= '9' || ch is >= 'a' and <= 'f')
            {
                normalized[i] = ch;
            }
            else if (ch is >= 'A' and <= 'F')
            {
                normalized[i] = (char)(ch - 'A' + 'a');
            }
            else
            {
                throw new FormatException("Descriptor sha256 contains a non-hex character.");
            }
        }

        return new string(normalized);
    }

    private static string RequireNonEmptySingleLine(string value, string field)
    {
        var normalized = RequireSingleLine(value, field);
        if (normalized.Length == 0)
        {
            throw new FormatException($"Descriptor field '{field}' must be non-empty.");
        }

        return normalized;
    }

    private static string RequireSingleLine(string value, string field)
    {
        var trimmed = value.Trim();
        if (trimmed.IndexOf('\n') >= 0 || trimmed.IndexOf('\r') >= 0)
        {
            throw new FormatException($"Descriptor field '{field}' must not contain CR/LF.");
        }

        return trimmed;
    }
}
