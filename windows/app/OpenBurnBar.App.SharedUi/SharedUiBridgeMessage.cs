using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.App.SharedUi;

// MARK: - Bridge wire protocol
//
// The wire protocol is EXACTLY the one spoken by the WebView2 shim that the
// Windows-mode Vite build aliases in for `@tauri-apps/api/*`
// (apps/linux-desktop/src/shim/tauriWebviewShim.ts):
//
//   renderer -> host (chrome.webview.postMessage, arrives here as JSON text):
//     { kind: 'invoke', id, command, args }   (Channel args -> { __channel: id })
//     { kind: 'listen', event }
//
//   host -> renderer (window.__obbShimDispatch(...)):
//     { kind: 'invoke-result', id, ok:true, value }
//     { kind: 'invoke-result', id, ok:false, error }   (error is a plain string)
//     { kind: 'channel', channelId, chunk }
//     { kind: 'event', event, payload }
//
// This class is the pure, side-effect-free codec half; SharedUiDispatcher is
// the routing half. Both are fully unit-tested on macOS with no browser.

/// A parsed message posted by the renderer.
public abstract record SharedUiInboundMessage
{
    private SharedUiInboundMessage() { }

    /// <summary>An invoke request. <paramref name="Args"/> is never null (missing args decode to an empty object).</summary>
    public sealed record Invoke(int Id, string Command, JsonObject Args) : SharedUiInboundMessage;

    /// <summary>An event-listen registration. The shim resolves listen() immediately; no reply is expected.</summary>
    public sealed record Listen(string Event) : SharedUiInboundMessage;
}

public static class SharedUiBridgeMessage
{
    /// The renderer-side dispatch global (mirrors the shim's `window.__obbShimDispatch`).
    public const string DispatchGlobal = "__obbShimDispatch";

    /// Parse one inbound message. Returns null for anything that is not a
    /// well-formed invoke/listen envelope — the shim never sends those, and the
    /// host must never throw on hostile/accidental renderer input.
    public static SharedUiInboundMessage? TryParse(string json)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            return null;
        }

        if (root is not JsonObject obj || obj["kind"] is not JsonValue kindValue ||
            !kindValue.TryGetValue(out string? kind))
        {
            return null;
        }

        switch (kind)
        {
            case "invoke":
            {
                if (obj["id"] is not JsonValue idValue || !idValue.TryGetValue(out int id) || id <= 0)
                {
                    return null;
                }

                if (obj["command"] is not JsonValue commandValue ||
                    !commandValue.TryGetValue(out string? command) || string.IsNullOrWhiteSpace(command))
                {
                    return null;
                }

                // Args are optional; a non-object args payload is treated as empty
                // (handlers re-validate every field they read anyway).
                var args = obj["args"] as JsonObject ?? new JsonObject();
                return new SharedUiInboundMessage.Invoke(id, command, args);
            }
            case "listen":
            {
                if (obj["event"] is not JsonValue eventValue ||
                    !eventValue.TryGetValue(out string? eventName) || string.IsNullOrWhiteSpace(eventName))
                {
                    return null;
                }

                return new SharedUiInboundMessage.Listen(eventName);
            }
            default:
                return null;
        }
    }

    /// <summary>The successful invoke reply. <paramref name="value"/> may be null (JSON null).</summary>
    public static JsonObject InvokeResult(int id, JsonNode? value) =>
        new()
        {
            ["kind"] = "invoke-result",
            ["id"] = id,
            ["ok"] = true,
            ["value"] = value,
        };

    /// <summary>The failed invoke reply. The error string becomes the renderer's Error.message.</summary>
    public static JsonObject InvokeError(int id, string error) =>
        new()
        {
            ["kind"] = "invoke-result",
            ["id"] = id,
            ["ok"] = false,
            ["error"] = error,
        };

    /// <summary>One streaming chunk for a Channel argument (gateway_chat_stream).</summary>
    public static JsonObject ChannelChunk(int channelId, string chunk) =>
        new()
        {
            ["kind"] = "channel",
            ["channelId"] = channelId,
            ["chunk"] = chunk,
        };

    /// <summary>An event broadcast to registered listeners.</summary>
    public static JsonObject Event(string eventName, JsonNode? payload) =>
        new()
        {
            ["kind"] = "event",
            ["event"] = eventName,
            ["payload"] = payload,
        };

    /// <summary>Extract the Channel id from an invoke args value shaped as { __channel: n }.</summary>
    public static bool TryReadChannelId(JsonObject args, string key, out int channelId)
    {
        channelId = 0;
        return args[key] is JsonObject channel
               && channel["__channel"] is JsonValue idValue
               && idValue.TryGetValue(out int id)
               && id > 0
               && (channelId = id) > 0;
    }
}
