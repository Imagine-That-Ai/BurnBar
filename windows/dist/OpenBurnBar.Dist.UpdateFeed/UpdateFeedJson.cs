// Strict JSON (de)serialization of the update feed (Phase 5 · signed distribution).
//
// Parsing is deliberately strict + fail-closed: a missing/malformed required field makes the
// WHOLE feed fail to parse rather than silently dropping to a default (a lenient parser could
// hide a downgrade or an unsigned entry). Enums parse only from their canonical wire tokens.
// Unknown extra properties are ignored (forward-compatible), but every required property must be
// present and well-typed. Serialization emits the same canonical shape the release CI publishes.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace OpenBurnBar.Dist.UpdateFeed;

/// <summary>Parses + serializes <see cref="UpdateFeedDocument"/> JSON.</summary>
public static class UpdateFeedJson
{
    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
    };

    /// <summary>Serialize a feed document to canonical, indented JSON (UTF-8 string).</summary>
    public static string Serialize(UpdateFeedDocument document)
    {
        ArgumentNullException.ThrowIfNull(document);

        using var stream = new System.IO.MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, WriterOptions))
        {
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", document.SchemaVersion);
            writer.WriteString("feed", document.Feed);
            writer.WriteString("generatedAtUtc", FormatTimestamp(document.GeneratedAtUtc));
            writer.WriteStartArray("entries");
            foreach (var entry in document.Entries)
            {
                WriteEntry(writer, entry);
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static void WriteEntry(Utf8JsonWriter writer, UpdateFeedEntry entry)
    {
        writer.WriteStartObject();
        writer.WriteString("version", entry.Version);
        writer.WriteString("platform", entry.Platform.ToToken());
        writer.WriteString("channel", entry.Channel.ToToken());
        writer.WriteString("url", entry.Url);
        writer.WriteNumber("sizeBytes", entry.SizeBytes);
        writer.WriteString("sha256", entry.Sha256);
        writer.WriteNumber("minimumOsBuild", entry.MinimumOsBuild);
        writer.WriteBoolean("critical", entry.Critical);
        writer.WriteString("publishedAtUtc", FormatTimestamp(entry.PublishedAtUtc));
        writer.WriteString("releaseNotesUrl", entry.ReleaseNotesUrl ?? string.Empty);
        writer.WriteString("ed25519Signature", entry.Signature ?? string.Empty);
        writer.WriteEndObject();
    }

    /// <summary>Parse strictly. Returns false (never throws) with a diagnostic on any malformed
    /// or incomplete feed — the updater treats an unparseable feed as fail-closed.</summary>
    public static bool TryParse(string? json, out UpdateFeedDocument? document, out string error)
    {
        document = null;
        error = string.Empty;
        if (string.IsNullOrWhiteSpace(json))
        {
            error = "Feed JSON was empty.";
            return false;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "Feed root is not a JSON object.";
                return false;
            }

            var schemaVersion = RequireInt(root, "schemaVersion");
            var feed = RequireString(root, "feed");
            var generatedAt = RequireTimestamp(root, "generatedAtUtc");

            if (!root.TryGetProperty("entries", out var entriesElement) || entriesElement.ValueKind != JsonValueKind.Array)
            {
                error = "Feed 'entries' must be an array.";
                return false;
            }

            var entries = new List<UpdateFeedEntry>();
            foreach (var element in entriesElement.EnumerateArray())
            {
                entries.Add(ParseEntry(element));
            }

            document = new UpdateFeedDocument
            {
                SchemaVersion = schemaVersion,
                Feed = feed,
                GeneratedAtUtc = generatedAt,
                Entries = entries,
            };
            return true;
        }
        catch (FeedFormatException ex)
        {
            error = ex.Message;
            return false;
        }
        catch (JsonException ex)
        {
            error = $"Feed JSON is malformed: {ex.Message}";
            return false;
        }
    }

    private static UpdateFeedEntry ParseEntry(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new FeedFormatException("Feed entry is not a JSON object.");
        }

        var platformToken = RequireString(element, "platform");
        if (!UpdateEnumTokens.TryParsePlatform(platformToken, out var platform))
        {
            throw new FeedFormatException($"Feed entry has an unknown platform token '{platformToken}'.");
        }

        var channelToken = RequireString(element, "channel");
        if (!UpdateEnumTokens.TryParseChannel(channelToken, out var channel))
        {
            throw new FeedFormatException($"Feed entry has an unknown channel token '{channelToken}'.");
        }

        return new UpdateFeedEntry
        {
            Version = RequireString(element, "version"),
            Platform = platform,
            Channel = channel,
            Url = RequireString(element, "url"),
            SizeBytes = RequireLong(element, "sizeBytes"),
            Sha256 = RequireString(element, "sha256"),
            MinimumOsBuild = OptionalInt(element, "minimumOsBuild", 0),
            Critical = OptionalBool(element, "critical", false),
            PublishedAtUtc = RequireTimestamp(element, "publishedAtUtc"),
            ReleaseNotesUrl = OptionalString(element, "releaseNotesUrl", string.Empty),
            Signature = RequireString(element, "ed25519Signature"),
        };
    }

    private static string RequireString(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw new FeedFormatException($"Required string property '{name}' is missing or not a string.");
        }

        return value.GetString() ?? throw new FeedFormatException($"Property '{name}' was null.");
    }

    private static string OptionalString(JsonElement parent, string name, string fallback)
    {
        if (!parent.TryGetProperty(name, out var value))
        {
            return fallback;
        }

        if (value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }

        if (value.ValueKind != JsonValueKind.String)
        {
            throw new FeedFormatException($"Property '{name}' must be a string when present.");
        }

        return value.GetString() ?? fallback;
    }

    private static int RequireInt(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
        {
            throw new FeedFormatException($"Required integer property '{name}' is missing or not an int.");
        }

        return result;
    }

    private static int OptionalInt(JsonElement parent, string name, int fallback)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }

        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
        {
            throw new FeedFormatException($"Property '{name}' must be an int when present.");
        }

        return result;
    }

    private static long RequireLong(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var result))
        {
            throw new FeedFormatException($"Required integer property '{name}' is missing or not a long.");
        }

        return result;
    }

    private static bool OptionalBool(JsonElement parent, string name, bool fallback)
    {
        if (!parent.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }

        if (value.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            return value.GetBoolean();
        }

        throw new FeedFormatException($"Property '{name}' must be a boolean when present.");
    }

    private static DateTimeOffset RequireTimestamp(JsonElement parent, string name)
    {
        var raw = RequireString(parent, name);
        if (!DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            throw new FeedFormatException($"Property '{name}' is not an ISO-8601 timestamp: '{raw}'.");
        }

        return parsed;
    }

    private static string FormatTimestamp(DateTimeOffset timestamp) =>
        timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    private sealed class FeedFormatException : Exception
    {
        public FeedFormatException(string message) : base(message)
        {
        }
    }
}
