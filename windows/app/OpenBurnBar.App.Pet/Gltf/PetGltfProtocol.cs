using System;
using System.Text.Json;

namespace OpenBurnBar.App.Pet.Gltf;

// MARK: - glTF host <-> page JSON protocol
//
// The tiny request/reply protocol the portable PetGltfSceneController speaks over
// IPetGltfHost. Host -> page is a PetGltfCommand; page -> host is a PetGltfReply.
// Kept as a hand-rolled System.Text.Json shape (no reflection surprises under
// TreatWarningsAsErrors) so the SAME serialisation is exercised by the fake host
// on macOS and by the real WebView2 host on Windows.

/// A command sent host -> page. <see cref="Id"/> correlates the reply; command
/// kind + payload follow.
public sealed class PetGltfCommand
{
    public PetGltfCommand(int id, string cmd, string? url = null, string? name = null,
        bool loop = false, bool draco = false, double crossfadeSeconds = 0.0)
    {
        Id = id;
        Cmd = cmd;
        Url = url;
        Name = name;
        Loop = loop;
        Draco = draco;
        CrossfadeSeconds = crossfadeSeconds;
    }

    public int Id { get; }
    public string Cmd { get; }
    public string? Url { get; }
    public string? Name { get; }
    public bool Loop { get; }
    public bool Draco { get; }
    public double CrossfadeSeconds { get; }

    // Command kinds (peer of the shell's dispatch switch).
    public const string CmdLoad = "load";
    public const string CmdClip = "clip";
    public const string CmdDispose = "dispose";

    public string ToJson()
    {
        using var stream = new System.IO.MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartObject();
            w.WriteNumber("id", Id);
            w.WriteString("cmd", Cmd);
            if (Url is not null)
            {
                w.WriteString("url", Url);
            }
            if (Name is not null)
            {
                w.WriteString("name", Name);
            }
            w.WriteBoolean("loop", Loop);
            w.WriteBoolean("draco", Draco);
            w.WriteNumber("crossfade", CrossfadeSeconds);
            w.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }
}

/// A reply/event sent page -> host.
public sealed class PetGltfReply
{
    public PetGltfReply(int id, bool ok, string? @event, string? name, string? error)
    {
        Id = id;
        Ok = ok;
        Event = @event;
        Name = name;
        Error = error;
    }

    /// Correlation id; 0 marks an unsolicited event (ready / clipEnded).
    public int Id { get; }

    /// True when a correlated command succeeded.
    public bool Ok { get; }

    /// Event name for unsolicited events: "ready" | "clipEnded".
    public string? Event { get; }

    /// Clip name carried by a "clipEnded" event.
    public string? Name { get; }

    /// Error message for a failed command.
    public string? Error { get; }

    public const string EventReady = "ready";
    public const string EventClipEnded = "clipEnded";

    /// Parse a reply JSON string. Returns null when the payload is not a JSON
    /// object (defensive against a garbled bridge message).
    public static PetGltfReply? TryParse(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            var id = root.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.Number
                && idEl.TryGetInt32(out var idv) ? idv : 0;
            var ok = root.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
            string? evt = root.TryGetProperty("event", out var evEl) && evEl.ValueKind == JsonValueKind.String
                ? evEl.GetString() : null;
            string? name = root.TryGetProperty("name", out var nEl) && nEl.ValueKind == JsonValueKind.String
                ? nEl.GetString() : null;
            string? error = root.TryGetProperty("error", out var erEl) && erEl.ValueKind == JsonValueKind.String
                ? erEl.GetString() : null;
            return new PetGltfReply(id, ok, evt, name, error);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
