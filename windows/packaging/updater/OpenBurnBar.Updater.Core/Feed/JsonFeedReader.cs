// Parses the latest-windows.json companion feed into an UpdateManifest.
//
// Mirrors the latest-macos.json object emitted by
// scripts/generate-macos-appcast.mjs (version / build / downloadUrl / length /
// sha256 / sparkleEdSignature -> edSignature / critical / minimumSystemVersion
// / releaseNotesUrl). Parsing is fail-closed: malformed JSON, a wrong root
// type, or a missing required field (version + downloadUrl) returns null, which
// the verifier maps to a MalformedFeed rejection.

using System;
using System.Text.Json;

namespace OpenBurnBar.Updater.Core.Feed;

/// <summary>Reads the latest-windows.json companion feed format.</summary>
public static class JsonFeedReader
{
    /// <summary>
    /// Parses the JSON feed, or returns null on malformed JSON / wrong root
    /// type / missing required field. Never throws on bad input.
    /// </summary>
    public static UpdateManifest? TryParse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return null;
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var version = ReadString(root, "version");
            var url = ReadString(root, "downloadUrl") ?? ReadString(root, "url");
            if (string.IsNullOrWhiteSpace(version) || string.IsNullOrWhiteSpace(url))
            {
                return null;
            }

            return new UpdateManifest
            {
                Version = version!,
                Build = ReadString(root, "build"),
                Url = url!,
                Length = ReadLength(root, "length"),
                Sha256 = ReadString(root, "sha256"),
                EdSignatureBase64 =
                    ReadString(root, "edSignature") ?? ReadString(root, "sparkleEdSignature"),
                DescriptorSignatureBase64 = ReadString(root, "descriptorSignature"),
                Critical = ReadBool(root, "critical"),
                MinimumSystemVersion = ReadString(root, "minimumSystemVersion"),
                Channel = ReadString(root, "channel") ?? "direct-download",
                ReleaseNotesUrl = ReadString(root, "releaseNotesUrl"),
                PubDate = ReadString(root, "pubDate") ?? ReadString(root, "createdAt"),
            };
        }
    }

    private static string? ReadString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() : null;
    }

    private static long? ReadLength(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number >= 0)
        {
            return number;
        }

        if (value.ValueKind == JsonValueKind.String &&
            long.TryParse(value.GetString(), out var parsed) && parsed >= 0)
        {
            return parsed;
        }

        return null;
    }

    private static bool ReadBool(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value))
        {
            return false;
        }

        return value.ValueKind == JsonValueKind.True;
    }
}
