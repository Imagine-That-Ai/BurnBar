using System;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenBurnBar.Pretext;

// MARK: - Bridge protocol
//
// The wire protocol is IDENTICAL to the WKWebView bridge on the Swift side
// (`PretextEngine.swift` + the WKWebView `index.html`):
//
//   host -> page:  window.__pretextDispatch(JSON.stringify({ id, method, params }))
//                  delivered via ExecuteScriptAsync (was WKWebView.evaluateJavaScript)
//
//   page -> host:  { id, ok, value }              on success
//                  { id, ok:false, error }        on failure
//                  { id: 0, ok:true, value:{ready} } readiness heartbeat
//                  delivered via WebMessageReceived (was messageHandlers.pretext)
//
// This class is the pure, side-effect-free half: it builds the dispatch script
// (with the EXACT same character escaping as the Swift `call(_:params:)`) and
// parses replies. It is fully unit-tested on macOS with no browser.

/// A parsed bridge reply.
public readonly record struct PretextReply(int Id, bool IsReady, bool Ok, JsonNode? Value, string? Error);

/// Pure protocol codec shared by the engine and the tests.
public static class PretextBridge
{
    /// The reply channel name (WebView2: <c>window.chrome.webview</c>). Kept as a
    /// constant so the shell HTML and any host wiring stay in sync.
    public const string ReplyChannel = "chrome.webview";

    /// Compact JSON serializer options — matches `JSONSerialization` (no pretty
    /// print, minimal escaping; the transport escaping is applied separately).
    private static readonly JsonSerializerOptions CompactJson = new()
    {
        WriteIndented = false,
    };

    /// Build the request envelope `{ id, method, params }` as a JSON object.
    public static JsonObject BuildRequest(int id, string method, JsonObject? @params)
    {
        return new JsonObject
        {
            ["id"] = id,
            ["method"] = method,
            ["params"] = @params ?? new JsonObject(),
        };
    }

    /// Serialize a request envelope to the compact JSON string that is passed to
    /// `window.__pretextDispatch`.
    public static string SerializeRequest(JsonObject request) =>
        request.ToJsonString(CompactJson);

    /// Escape a JSON string for safe embedding inside a double-quoted JS string
    /// literal. This reproduces, character-for-character and IN THE SAME ORDER, the
    /// escaping in `PretextEngine.swift`'s `call(_:params:)`:
    ///
    ///   backslash -> \\   (FIRST, so later-inserted backslashes are not doubled)
    ///   "         -> \"
    ///   \n        -> \\n
    ///   \r        -> \\r
    ///   \t        -> \\t
    ///   U+2028    -> U+2028   (JS line separator — illegal raw in a JS string)
    ///   U+2029    -> U+2029   (JS paragraph separator — illegal raw in a JS string)
    public static string EscapeForJsStringLiteral(string json)
    {
        var sb = new StringBuilder(json.Length + 16);
        foreach (var c in json)
        {
            switch (c)
            {
                case '\\':
                    sb.Append("\\\\");
                    break;
                case '"':
                    sb.Append("\\\"");
                    break;
                case '\n':
                    sb.Append("\\n");
                    break;
                case '\r':
                    sb.Append("\\r");
                    break;
                case '\t':
                    sb.Append("\\t");
                    break;
                case '\u2028':
                    sb.Append("\\u2028");
                    break;
                case '\u2029':
                    sb.Append("\\u2029");
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// Build the full `window.__pretextDispatch("...")` script for a request,
    /// mirroring the Swift string:
    ///   "window.__pretextDispatch &amp;&amp; window.__pretextDispatch(\"\(escaped)\");"
    public static string BuildDispatchScript(JsonObject request)
    {
        var json = SerializeRequest(request);
        var escaped = EscapeForJsStringLiteral(json);
        return "window.__pretextDispatch && window.__pretextDispatch(\"" + escaped + "\");";
    }

    /// Convenience: build the dispatch script directly from id/method/params.
    public static string BuildDispatchScript(int id, string method, JsonObject? @params) =>
        BuildDispatchScript(BuildRequest(id, method, @params));

    /// Parse a reply the page posted back. Mirrors `handleBridgeMessage(_:)`:
    ///   * a missing / non-numeric `id` yields <c>Id == -1</c> (ignored by the engine);
    ///   * <c>id == 0</c> is the readiness heartbeat (<see cref="PretextReply.IsReady"/>);
    ///   * otherwise `ok` decides success vs. `error`.
    public static PretextReply ParseReply(string json)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            return new PretextReply(-1, IsReady: false, Ok: false, Value: null, Error: null);
        }

        if (root is not JsonObject obj || obj["id"] is not JsonValue idValue ||
            !idValue.TryGetValue(out int id))
        {
            return new PretextReply(-1, IsReady: false, Ok: false, Value: null, Error: null);
        }

        if (id == 0)
        {
            return new PretextReply(0, IsReady: true, Ok: true, Value: obj["value"], Error: null);
        }

        var ok = obj["ok"] is JsonValue okValue && okValue.TryGetValue(out bool b) && b;
        if (ok)
        {
            return new PretextReply(id, IsReady: false, Ok: true, Value: obj["value"], Error: null);
        }

        var error = obj["error"] is JsonValue errValue && errValue.TryGetValue(out string? s) ? s : "unknown";
        return new PretextReply(id, IsReady: false, Ok: false, Value: null, Error: error);
    }
}

// MARK: - JSON reader helpers
//
// Mirror the `guard let ... as? NSNumber ... else { throw .invalidResponse }`
// discipline on the Swift side: every field read is checked, and a malformed or
// missing field throws `PretextException.InvalidResponse`.

internal static class JsonNodeExtensions
{
    public static JsonObject AsObjectOrThrow(this JsonNode? node) =>
        node as JsonObject ?? throw PretextException.InvalidResponse();

    public static double RequireDouble(this JsonObject obj, string key)
    {
        if (obj[key] is JsonValue v && v.TryGetValue(out double d))
        {
            return d;
        }
        // JSON integers may not coerce to double via TryGetValue<double> on every
        // runtime; fall back through the raw numeric representation.
        if (obj[key] is JsonValue v2 && v2.TryGetValue(out long l))
        {
            return l;
        }
        throw PretextException.InvalidResponse();
    }

    public static int RequireInt(this JsonObject obj, string key)
    {
        if (obj[key] is JsonValue v && v.TryGetValue(out int i))
        {
            return i;
        }
        if (obj[key] is JsonValue v2 && v2.TryGetValue(out double d))
        {
            return (int)d;
        }
        throw PretextException.InvalidResponse();
    }

    public static double OptionalDouble(this JsonObject obj, string key, double fallback)
    {
        if (obj[key] is JsonValue v && v.TryGetValue(out double d))
        {
            return d;
        }
        if (obj[key] is JsonValue v2 && v2.TryGetValue(out long l))
        {
            return l;
        }
        return fallback;
    }

    public static string RequireString(this JsonObject obj, string key)
    {
        if (obj[key] is JsonValue v && v.TryGetValue(out string? s) && s is not null)
        {
            return s;
        }
        throw PretextException.InvalidResponse();
    }

    public static JsonArray RequireArray(this JsonObject obj, string key) =>
        obj[key] as JsonArray ?? throw PretextException.InvalidResponse();
}
