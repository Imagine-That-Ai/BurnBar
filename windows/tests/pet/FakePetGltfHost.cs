using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Pet.Gltf;

namespace OpenBurnBar.App.Pet.Tests;

/// In-memory stand-in for the three.js WebView2 page. Lets the PetGltfSceneController
/// protocol be exercised on the macOS authoring host without a browser — the same
/// pattern the Pretext engine proves with FakePretextWebHost.
internal sealed class FakePetGltfHost : IPetGltfHost
{
    private readonly List<ReceivedCommand> _commands = new();

    /// Whether StartAsync posts the ready heartbeat automatically.
    public bool AutoReady { get; set; } = true;

    /// When set, the next matching command id fails with this error instead of acking.
    public string? FailNextError { get; set; }

    /// Clip names for which a clipEnded event is emitted right after the ack.
    public HashSet<string> EmitClipEndedFor { get; } = new(StringComparer.Ordinal);

    public IReadOnlyList<ReceivedCommand> Commands => _commands;

    public event Action<string>? MessageReceived;

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (AutoReady)
        {
            Emit(Reply(0, evt: "ready"));
        }
        return Task.CompletedTask;
    }

    public Task PostMessageAsync(string json, CancellationToken cancellationToken = default)
    {
        var cmd = ParseCommand(json);
        _commands.Add(cmd);

        if (FailNextError is { } err)
        {
            FailNextError = null;
            Emit(Reply(cmd.Id, ok: false, error: err));
            return Task.CompletedTask;
        }

        Emit(Reply(cmd.Id, ok: true));

        if (cmd.Cmd == PetGltfCommand.CmdClip && cmd.Name is not null && EmitClipEndedFor.Contains(cmd.Name))
        {
            Emit(Reply(0, evt: "clipEnded", name: cmd.Name));
        }
        return Task.CompletedTask;
    }

    /// Emit an arbitrary reply/event to the controller.
    public void Emit(string replyJson) => MessageReceived?.Invoke(replyJson);

    private static ReceivedCommand ParseCommand(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var id = root.TryGetProperty("id", out var i) && i.TryGetInt32(out var iv) ? iv : 0;
        var cmd = root.TryGetProperty("cmd", out var c) ? c.GetString() ?? string.Empty : string.Empty;
        var name = root.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
        var url = root.TryGetProperty("url", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null;
        var loop = root.TryGetProperty("loop", out var l) && l.ValueKind == JsonValueKind.True;
        return new ReceivedCommand(id, cmd, name, url, loop);
    }

    private static string Reply(int id, bool ok = false, string? evt = null, string? name = null, string? error = null)
    {
        using var stream = new System.IO.MemoryStream();
        using (var w = new Utf8JsonWriter(stream))
        {
            w.WriteStartObject();
            w.WriteNumber("id", id);
            if (ok)
            {
                w.WriteBoolean("ok", true);
            }
            if (evt is not null)
            {
                w.WriteString("event", evt);
            }
            if (name is not null)
            {
                w.WriteString("name", name);
            }
            if (error is not null)
            {
                w.WriteString("error", error);
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    internal sealed record ReceivedCommand(int Id, string Cmd, string? Name, string? Url, bool Loop);
}
