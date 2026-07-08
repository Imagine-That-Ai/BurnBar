using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// Bridge HTTP response value type + wire serializer.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   sendRedirect / sendHTML / sendSVG / sendJSON / jsonHeader / sendStatus /
//   statusText. The router produces a BridgeResponse; the Net adapter serializes
//   it to bytes and writes it to the socket, so the exact HTTP/1.1 head is
//   authored + asserted here rather than inside the listener.

public sealed class BridgeResponse
{
    public int StatusCode { get; }
    public string ReasonPhrase { get; }

    /// Content-Type header value, or null for a bodiless response (redirect / 204).
    public string? ContentType { get; }

    public byte[] Body { get; }

    /// Extra response headers in emission order (e.g. Location, Cache-Control).
    public IReadOnlyList<KeyValuePair<string, string>> ExtraHeaders { get; }

    private BridgeResponse(int statusCode, string reasonPhrase, string? contentType, byte[] body, IReadOnlyList<KeyValuePair<string, string>> extraHeaders)
    {
        StatusCode = statusCode;
        ReasonPhrase = reasonPhrase;
        ContentType = contentType;
        Body = body;
        ExtraHeaders = extraHeaders;
    }

    public static BridgeResponse Redirect(string location) => new(
        302,
        StatusText(302),
        contentType: null,
        body: Array.Empty<byte>(),
        extraHeaders: new[] { new KeyValuePair<string, string>("Location", location) });

    public static BridgeResponse Html(string html) => new(
        200,
        StatusText(200),
        "text/html; charset=utf-8",
        Encoding.UTF8.GetBytes(html),
        new[] { new KeyValuePair<string, string>("Cache-Control", "no-store") });

    public static BridgeResponse Svg(string svg) => new(
        200,
        StatusText(200),
        "image/svg+xml; charset=utf-8",
        Encoding.UTF8.GetBytes(svg),
        new[] { new KeyValuePair<string, string>("Cache-Control", "no-store") });

    public static BridgeResponse Json(string json) => new(
        200,
        StatusText(200),
        "application/json; charset=utf-8",
        Encoding.UTF8.GetBytes(json),
        new[] { new KeyValuePair<string, string>("Cache-Control", "no-store") });

    /// Parity: Swift `sendStatus(_:)` — small JSON status body + reason phrase.
    /// 204 carries no body (Swift emits a bare 204 head).
    public static BridgeResponse Status(int code)
    {
        if (code == 204)
        {
            return new BridgeResponse(204, StatusText(204), contentType: null, body: Array.Empty<byte>(), extraHeaders: Array.Empty<KeyValuePair<string, string>>());
        }
        var body = Encoding.UTF8.GetBytes($"{{\"status\":{code}}}");
        return new BridgeResponse(code, StatusText(code), "application/json", body, Array.Empty<KeyValuePair<string, string>>());
    }

    /// Serializes to an HTTP/1.1 response with `Connection: close`, matching the
    /// Swift head byte-for-byte (status line, headers, blank line, body).
    public byte[] Serialize()
    {
        var head = new StringBuilder();
        head.Append("HTTP/1.1 ").Append(StatusCode).Append(' ').Append(ReasonPhrase).Append("\r\n");
        if (ContentType is not null)
        {
            head.Append("Content-Type: ").Append(ContentType).Append("\r\n");
        }
        foreach (var header in ExtraHeaders)
        {
            head.Append(header.Key).Append(": ").Append(header.Value).Append("\r\n");
        }
        head.Append("Content-Length: ").Append(Body.Length).Append("\r\n");
        head.Append("Connection: close\r\n\r\n");

        var headBytes = Encoding.UTF8.GetBytes(head.ToString());
        var result = new byte[headBytes.Length + Body.Length];
        Array.Copy(headBytes, 0, result, 0, headBytes.Length);
        Array.Copy(Body, 0, result, headBytes.Length, Body.Length);
        return result;
    }

    /// Parity: Swift `statusText(_:)`.
    public static string StatusText(int code) => code switch
    {
        200 => "OK",
        204 => "No Content",
        302 => "Found",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        500 => "Internal Server Error",
        _ => "Unknown",
    };
}
