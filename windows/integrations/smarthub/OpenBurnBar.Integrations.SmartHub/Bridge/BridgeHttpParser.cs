using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// HTTP/1.1 request parsing for the bridge.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   respond(to:on:) request-line + pathOnly split, headerValue(in:name:), and
//   bodyData(from:). The Swift server reads up to 16 KiB in one recv and parses
//   the first line + headers + body from that buffer; we mirror that exactly.

public enum BridgeParseError
{
    None,

    /// Request line had fewer than two space-separated tokens (Swift -> 400).
    BadRequest,

    /// Request bytes were not valid UTF-8 (Swift -> 404).
    NotUtf8,
}

/// A parsed bridge HTTP request.
public sealed class BridgeRequest
{
    public string Method { get; }

    /// Full request target including any query string (e.g. "/state.json?bridgeToken=…").
    public string RawPath { get; }

    /// Request target with the query stripped (used for routing).
    public string PathOnly { get; }

    public IReadOnlyDictionary<string, string> Headers { get; }

    public byte[]? Body { get; }

    public BridgeRequest(string method, string rawPath, string pathOnly, IReadOnlyDictionary<string, string> headers, byte[]? body)
    {
        Method = method;
        RawPath = rawPath;
        PathOnly = pathOnly;
        Headers = headers;
        Body = body;
    }

    /// Case-insensitive header lookup. Parity: Swift `headerValue(in:name:)`.
    public string? Header(string name)
    {
        foreach (var kvp in Headers)
        {
            if (string.Equals(kvp.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                return kvp.Value;
            }
        }
        return null;
    }
}

public sealed class BridgeParseResult
{
    public BridgeRequest? Request { get; }
    public BridgeParseError Error { get; }

    private BridgeParseResult(BridgeRequest? request, BridgeParseError error)
    {
        Request = request;
        Error = error;
    }

    public static BridgeParseResult Ok(BridgeRequest request) => new(request, BridgeParseError.None);
    public static BridgeParseResult Fail(BridgeParseError error) => new(null, error);
}

public static class BridgeHttpParser
{
    private static readonly byte[] Boundary = { 0x0D, 0x0A, 0x0D, 0x0A };

    public static BridgeParseResult Parse(byte[] data)
    {
        string request;
        try
        {
            request = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return BridgeParseResult.Fail(BridgeParseError.NotUtf8);
        }

        var firstLine = FirstLine(request);
        var parts = firstLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            return BridgeParseResult.Fail(BridgeParseError.BadRequest);
        }

        var method = parts[0];
        var path = parts[1];
        var pathOnly = SplitFirst(path, '?');

        var headers = ParseHeaders(request);
        var body = BodyData(data);

        return BridgeParseResult.Ok(new BridgeRequest(method, path, pathOnly, headers, body));
    }

    private static string FirstLine(string request)
    {
        var idx = request.IndexOf("\r\n", StringComparison.Ordinal);
        return idx < 0 ? request : request.Substring(0, idx);
    }

    private static string SplitFirst(string value, char separator)
    {
        var idx = value.IndexOf(separator);
        return idx < 0 ? value : value.Substring(0, idx);
    }

    /// Parity: Swift `headerValue`-style parse — case-insensitive keys, value
    /// trimmed, split on the first colon; stop at the blank line.
    private static Dictionary<string, string> ParseHeaders(string request)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var lines = request.Split("\r\n");
        for (var i = 1; i < lines.Length; i++)
        {
            var line = lines[i];
            if (line.Length == 0)
            {
                break;
            }
            var colon = line.IndexOf(':');
            if (colon < 0)
            {
                continue;
            }
            var name = line.Substring(0, colon).Trim();
            var value = line.Substring(colon + 1).Trim();
            if (name.Length > 0 && !headers.ContainsKey(name))
            {
                headers[name] = value;
            }
        }
        return headers;
    }

    /// Parity: Swift `bodyData(from:)` — bytes after the first \r\n\r\n, or null.
    public static byte[]? BodyData(byte[] request)
    {
        if (request.Length < Boundary.Length)
        {
            return null;
        }
        for (var i = 0; i <= request.Length - Boundary.Length; i++)
        {
            if (Matches(request, i))
            {
                var bodyStart = i + Boundary.Length;
                if (bodyStart < request.Length)
                {
                    var body = new byte[request.Length - bodyStart];
                    Array.Copy(request, bodyStart, body, 0, body.Length);
                    return body;
                }
                return null;
            }
        }
        return null;
    }

    private static bool Matches(byte[] data, int offset)
    {
        for (var j = 0; j < Boundary.Length; j++)
        {
            if (data[offset + j] != Boundary[j])
            {
                return false;
            }
        }
        return true;
    }
}
