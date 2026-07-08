// Emits a Sparkle / WinSparkle appcast XML for one release.
//
// Byte-for-byte the same SHAPE scripts/generate-macos-appcast.mjs emits for
// macOS, retargeted for Windows: an RSS 2.0 channel + a single <item> with the
// short/monotonic versions, minimum-system-version, release-notes link, the
// optional <sparkle:criticalUpdate> tag, and an <enclosure> carrying url /
// length / type / sparkle:edSignature (+ our sparkle:sha256 extension). All
// interpolated values are XML-escaped. The result parses cleanly back through
// AppcastFeedReader (proven by the round-trip tests) and validates under
// xmllint.

using System;
using System.Text;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Serializes an <see cref="UpdateReleaseDescriptor"/> to appcast XML.</summary>
public static class AppcastFeedWriter
{
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

        sb.Append(
            $"      <enclosure url=\"{Escape(release.DownloadUrl)}\" " +
            $"length=\"{release.Length}\" " +
            $"type=\"{Escape(release.ArtifactMimeType)}\" " +
            $"sparkle:sha256=\"{Escape(release.Sha256)}\" " +
            $"sparkle:edSignature=\"{Escape(release.EdSignatureBase64)}\" />\n");
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
