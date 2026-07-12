// Emits a Sparkle / WinSparkle appcast XML for one release.
//
// Byte-for-byte the same SHAPE scripts/generate-macos-appcast.mjs emits for
// macOS, retargeted for Windows: an RSS 2.0 channel + a single <item> with the
// short/monotonic versions, minimum-system-version, release-notes link, the
// optional <sparkle:criticalUpdate> tag, a <sparkle:channel> for non-default
// channels, and an <enclosure> carrying url / length / type /
// sparkle:edSignature (Ed25519 over the ARTIFACT BYTES — Sparkle/WinSparkle
// native semantics) + our sparkle:sha256 and sparkle:edDescriptorSignature
// (Ed25519 over the canonical metadata descriptor) extensions. All
// interpolated values are XML-escaped. The result parses cleanly back through
// AppcastFeedReader (proven by the round-trip tests) and validates under
// xmllint.

using System;
using System.Text;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Serializes an <see cref="UpdateReleaseDescriptor"/> to appcast XML.</summary>
public static class AppcastFeedWriter
{
    /// <summary>The channel that is implied when no &lt;sparkle:channel&gt; element is present.</summary>
    public const string DefaultChannel = "direct-download";

    /// <summary>Renders the appcast XML for <paramref name="release"/>.</summary>
    public static string Write(UpdateReleaseDescriptor release)
    {
        ArgumentNullException.ThrowIfNull(release);

        var pubDate = release.PubDate ?? DateTimeOffset.UtcNow.ToString("R");
        var appcastUrl = release.AppcastUrl ?? release.DownloadUrl;

        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
        sb.Append(
            "<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">\n");
        sb.Append("  <channel>\n");
        sb.Append("    <title>OpenBurnBar Windows Updates</title>\n");
        sb.Append($"    <link>{Escape(appcastUrl)}</link>\n");
        sb.Append("    <description>OpenBurnBar direct-download Windows releases.</description>\n");
        sb.Append("    <language>en</language>\n");
        sb.Append("    <item>\n");
        sb.Append($"      <title>OpenBurnBar {Escape(release.Version)}</title>\n");
        sb.Append($"      <pubDate>{Escape(pubDate)}</pubDate>\n");
        sb.Append($"      <sparkle:version>{Escape(release.Build)}</sparkle:version>\n");
        sb.Append(
            $"      <sparkle:shortVersionString>{Escape(release.Version)}</sparkle:shortVersionString>\n");
        sb.Append(
            "      <sparkle:minimumSystemVersion>" +
            $"{Escape(release.MinimumSystemVersion)}</sparkle:minimumSystemVersion>\n");
        if (!string.IsNullOrWhiteSpace(release.ReleaseNotesUrl))
        {
            sb.Append(
                $"      <sparkle:releaseNotesLink>{Escape(release.ReleaseNotesUrl)}</sparkle:releaseNotesLink>\n");
        }

        if (release.Critical)
        {
            sb.Append("      <sparkle:tags>\n");
            sb.Append("        <sparkle:criticalUpdate></sparkle:criticalUpdate>\n");
            sb.Append("      </sparkle:tags>\n");
        }

        // Sparkle channel semantics: an item WITHOUT <sparkle:channel> is on the
        // default channel, so the default ("direct-download") is omitted. A
        // non-default channel MUST round-trip because the descriptor signature
        // binds it (the reader restores the default when the element is absent).
        if (!string.Equals(release.Channel, DefaultChannel, StringComparison.Ordinal))
        {
            sb.Append($"      <sparkle:channel>{Escape(release.Channel)}</sparkle:channel>\n");
        }

        sb.Append(
            $"      <enclosure url=\"{Escape(release.DownloadUrl)}\" " +
            $"length=\"{release.Length}\" " +
            $"type=\"{Escape(release.ArtifactMimeType)}\" " +
            $"sparkle:sha256=\"{Escape(release.Sha256)}\" " +
            $"sparkle:edSignature=\"{Escape(release.EdSignatureBase64)}\" " +
            $"sparkle:edDescriptorSignature=\"{Escape(release.DescriptorSignatureBase64)}\" />\n");
        sb.Append("    </item>\n");
        sb.Append("  </channel>\n");
        sb.Append("</rss>\n");
        return sb.ToString();
    }

    private static string Escape(string value) =>
        value
            .Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal)
            .Replace("\"", "&quot;", StringComparison.Ordinal)
            .Replace("'", "&apos;", StringComparison.Ordinal);
}
