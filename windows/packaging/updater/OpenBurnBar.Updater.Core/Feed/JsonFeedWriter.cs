// Emits the latest-windows.json companion feed for one release.
//
// Mirrors the latest-macos.json object from scripts/generate-macos-appcast.mjs
// (sorted, stable keys; a trailing newline) so the direct-download JSON channel
// on Windows has the same shape as macOS. Parses back cleanly through
// JsonFeedReader (proven by the round-trip tests).

using System;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Serializes an <see cref="UpdateReleaseDescriptor"/> to latest-windows.json.</summary>
public static class JsonFeedWriter
{
    // Relaxed escaping so base64 '+' stays literal (matches the macOS
    // latest-macos.json output). The feed is a data file, never embedded in
    // HTML, so relaxed escaping is safe here.
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>Renders the JSON feed for <paramref name="release"/>.</summary>
    public static string Write(UpdateReleaseDescriptor release)
    {
        ArgumentNullException.ThrowIfNull(release);

        var createdAt = release.CreatedAt ?? DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");

        var obj = new JsonObject
        {
            ["appcastUrl"] = release.AppcastUrl,
            ["build"] = release.Build,
            ["bundleId"] = release.BundleId,
            ["channel"] = release.Channel,
            ["commit"] = release.Commit,
            ["createdAt"] = createdAt,
            ["critical"] = release.Critical,
            ["downloadUrl"] = release.DownloadUrl,
            ["edSignature"] = release.EdSignatureBase64,
            ["length"] = release.Length,
            ["minimumSystemVersion"] = release.MinimumSystemVersion,
            ["package"] = release.PackageName,
            ["releaseNotesUrl"] = release.ReleaseNotesUrl,
            ["sha256"] = release.Sha256,
            ["version"] = release.Version,
        };

        return obj.ToJsonString(Options) + "\n";
    }
}
