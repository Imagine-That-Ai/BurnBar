using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json.Nodes;
using OpenBurnBar.Pretext;

namespace OpenBurnBar.Pretext.Tests;

/// A parsed request the fake host recovered from a dispatch script.
public readonly record struct FakeRequest(int Id, string Method, JsonObject Params);

/// The dispatcher's answer for one request.
public readonly record struct FakeReply(bool Ok, JsonNode? Value, string? Error)
{
    public static FakeReply Success(JsonNode? value) => new(true, value, null);
    public static FakeReply Failure(string error) => new(false, null, error);
}

/// In-memory <see cref="IPretextWebHost"/> that stands in for a real WebView2.
///
/// It reverses the engine's <c>window.__pretextDispatch("...")</c> script back into
/// a request (which VALIDATES the escaping round-trip end-to-end), hands it to a
/// caller-supplied dispatcher, then raises the reply on <see cref="WebMessageReceived"/>
/// — exactly the transport the real WebView2 host performs. No browser required.
public sealed class FakePretextWebHost : IPretextWebHost
{
    private readonly Func<FakeRequest, FakeReply> _dispatch;

    /// How many scripts the engine executed (used to prove the handle cache elides
    /// duplicate prepares).
    public int ExecuteScriptCount { get; private set; }

    /// Every method the engine dispatched, in order.
    public List<string> ObservedMethods { get; } = new();

    /// When false, <see cref="StartAsync"/> does NOT post the readiness heartbeat,
    /// so tests can assert calls block until ready.
    public bool RaiseReadyOnStart { get; init; } = true;

    /// When set, <see cref="ExecuteScriptAsync"/> throws (simulating a WebView2 eval
    /// failure) so the engine's error path is exercised.
    public Exception? ExecuteScriptThrows { get; set; }

    public event Action<string>? WebMessageReceived;

    public FakePretextWebHost(Func<FakeRequest, FakeReply> dispatch)
    {
        _dispatch = dispatch ?? throw new ArgumentNullException(nameof(dispatch));
    }

    /// Manually post the readiness heartbeat (for the deferred-ready test).
    public void PostReady()
    {
        WebMessageReceived?.Invoke("{\"id\":0,\"ok\":true,\"value\":{\"ready\":true}}");
    }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (RaiseReadyOnStart)
        {
            PostReady();
        }
        return Task.CompletedTask;
    }

    public Task<string?> ExecuteScriptAsync(string script, CancellationToken cancellationToken = default)
    {
        ExecuteScriptCount++;
        if (ExecuteScriptThrows is { } ex)
        {
            throw ex;
        }

        var request = ParseDispatchScript(script);
        ObservedMethods.Add(request.Method);
        var reply = _dispatch(request);

        var replyObject = new JsonObject { ["id"] = request.Id };
        if (reply.Ok)
        {
            replyObject["ok"] = true;
            replyObject["value"] = reply.Value ?? new JsonObject();
        }
        else
        {
            replyObject["ok"] = false;
            replyObject["error"] = reply.Error ?? "unknown";
        }

        // Deliver asynchronously, like a real WebView2 WebMessageReceived event.
        WebMessageReceived?.Invoke(replyObject.ToJsonString());
        return Task.FromResult<string?>(null);
    }

    // MARK: - Dispatch-script reversal (the exact inverse of PretextBridge)

    private const string Prefix = "window.__pretextDispatch && window.__pretextDispatch(\"";
    private const string Suffix = "\");";

    /// Recover the request from the engine's dispatch script. This is the inverse of
    /// <see cref="PretextBridge.BuildDispatchScript(JsonObject)"/>: strip the wrapper,
    /// un-escape the JS string literal, then JSON.parse. If the engine's escaping is
    /// wrong, this throws — so the round-trip itself is a test.
    public static FakeRequest ParseDispatchScript(string script)
    {
        if (!script.StartsWith(Prefix, StringComparison.Ordinal) ||
            !script.EndsWith(Suffix, StringComparison.Ordinal))
        {
            throw new FormatException($"Unexpected dispatch script shape: {script}");
        }

        var inner = script.Substring(Prefix.Length, script.Length - Prefix.Length - Suffix.Length);
        var json = UnescapeJsStringLiteral(inner);
        var node = JsonNode.Parse(json) as JsonObject
            ?? throw new FormatException("Dispatch payload was not a JSON object.");

        var id = (int)node["id"]!.GetValue<double>();
        var method = node["method"]!.GetValue<string>();
        var @params = node["params"] as JsonObject ?? new JsonObject();
        return new FakeRequest(id, method, @params);
    }

    /// Reverse the character escaping applied by
    /// <see cref="PretextBridge.EscapeForJsStringLiteral"/>.
    private static string UnescapeJsStringLiteral(string escaped)
    {
        var sb = new StringBuilder(escaped.Length);
        for (var i = 0; i < escaped.Length; i++)
        {
            var c = escaped[i];
            if (c != '\\')
            {
                sb.Append(c);
                continue;
            }
            i++;
            if (i >= escaped.Length)
            {
                throw new FormatException("Dangling escape in dispatch string.");
            }
            var e = escaped[i];
            switch (e)
            {
                case 'n': sb.Append('\n'); break;
                case 'r': sb.Append('\r'); break;
                case 't': sb.Append('\t'); break;
                case '"': sb.Append('"'); break;
                case '\\': sb.Append('\\'); break;
                case 'u':
                    if (i + 4 >= escaped.Length)
                    {
                        throw new FormatException("Truncated \\u escape.");
                    }
                    var hex = escaped.Substring(i + 1, 4);
                    sb.Append((char)int.Parse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                    i += 4;
                    break;
                default:
                    throw new FormatException($"Unknown escape '\\{e}'.");
            }
        }
        return sb.ToString();
    }
}
