using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// Bridge access control.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   isAuthorizedBridgeRequest / constantTimeEquals / queryValue / makeBridgeAccessToken /
//   securedBridgeURL / redactedBridgeURL / securedPath / securedQueryItems.
//
// Every state-bearing bridge route requires the per-session bridge token, passed
// EITHER as a `bridgeToken` query parameter OR as an `Authorization: Bearer`
// header. The comparison is constant-time so a compromised-LAN attacker cannot
// time-oracle the token.

public static class BridgeAccessControl
{
    public const string BridgeAccessTokenQueryName = "bridgeToken";

    /// Parity: Swift `makeBridgeAccessToken()` — 32 CSPRNG bytes, lowercase hex.
    public static string MakeBridgeAccessToken()
    {
        var bytes = new byte[32];
        RandomNumberGenerator.Fill(bytes);
        var sb = new StringBuilder(64);
        foreach (var b in bytes)
        {
            sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    /// True when the request presents the bridge token via query OR bearer header.
    /// Parity: Swift `isAuthorizedBridgeRequest(rawPath:authorizationHeader:)`.
    public static bool IsAuthorized(string rawPath, string? authorizationHeader, string bridgeAccessToken)
    {
        if (string.IsNullOrEmpty(bridgeAccessToken))
        {
            return false;
        }
        if (ConstantTimeEquals(QueryValue(rawPath, BridgeAccessTokenQueryName), bridgeAccessToken))
        {
            return true;
        }
        var header = (authorizationHeader ?? string.Empty).Trim();
        return ConstantTimeEquals(header, $"Bearer {bridgeAccessToken}");
    }

    /// Parity: Swift `constantTimeEquals(_:_:)`.
    public static bool ConstantTimeEquals(string? lhs, string rhs)
    {
        if (lhs is null)
        {
            return false;
        }
        var lhsBytes = Encoding.UTF8.GetBytes(lhs);
        var rhsBytes = Encoding.UTF8.GetBytes(rhs);
        var diff = lhsBytes.Length ^ rhsBytes.Length;
        var max = Math.Max(lhsBytes.Length, rhsBytes.Length);
        for (var i = 0; i < max; i++)
        {
            var l = i < lhsBytes.Length ? lhsBytes[i] : 0;
            var r = i < rhsBytes.Length ? rhsBytes[i] : 0;
            diff |= l ^ r;
        }
        return diff == 0;
    }

    /// Parity: Swift `queryValue(in:key:)` — first matching `key=value` pair,
    /// percent-decoded, or null.
    public static string? QueryValue(string path, string key)
    {
        var q = path.IndexOf('?');
        if (q < 0)
        {
            return null;
        }
        var query = path.Substring(q + 1);
        foreach (var pair in query.Split('&'))
        {
            var kv = pair.Split('=', 2);
            if (kv.Length != 2)
            {
                continue;
            }
            if (kv[0] == key)
            {
                return Uri.UnescapeDataString(kv[1]);
            }
        }
        return null;
    }

    /// Returns `url` with exactly one bridgeToken query param (replacing any
    /// existing). Parity: Swift `securedBridgeURL(_:)`.
    public static string SecuredBridgeUrl(string url, string bridgeAccessToken)
    {
        var (basePart, query, fragment) = SplitUrl(url);
        var items = FilterOut(ParseQuery(query), BridgeAccessTokenQueryName);
        items.Add(new KeyValuePair<string, string>(BridgeAccessTokenQueryName, bridgeAccessToken));
        return Reassemble(basePart, items, fragment);
    }

    /// Returns `url` with the bridgeToken query param removed (for logs).
    /// Parity: Swift `redactedBridgeURL(_:)`.
    public static string RedactedBridgeUrl(string url)
    {
        var (basePart, query, fragment) = SplitUrl(url);
        var items = FilterOut(ParseQuery(query), BridgeAccessTokenQueryName);
        return Reassemble(basePart, items, fragment);
    }

    /// Path variant used for the /render.html redirect Location.
    /// Parity: Swift `securedPath(_:)`.
    public static string SecuredPath(string path, string bridgeAccessToken)
    {
        var (basePart, query, fragment) = SplitUrl(path);
        var items = FilterOut(ParseQuery(query), BridgeAccessTokenQueryName);
        items.Add(new KeyValuePair<string, string>(BridgeAccessTokenQueryName, bridgeAccessToken));
        return Reassemble(basePart, items, fragment);
    }

    private static List<KeyValuePair<string, string>> FilterOut(
        List<KeyValuePair<string, string>> items,
        string name)
    {
        var result = new List<KeyValuePair<string, string>>(items.Count);
        foreach (var item in items)
        {
            if (item.Key != name)
            {
                result.Add(item);
            }
        }
        return result;
    }

    private static (string BasePart, string Query, string Fragment) SplitUrl(string url)
    {
        var fragment = string.Empty;
        var hash = url.IndexOf('#');
        if (hash >= 0)
        {
            fragment = url.Substring(hash + 1);
            url = url.Substring(0, hash);
        }
        var query = string.Empty;
        var q = url.IndexOf('?');
        if (q >= 0)
        {
            query = url.Substring(q + 1);
            url = url.Substring(0, q);
        }
        return (url, query, fragment);
    }

    private static List<KeyValuePair<string, string>> ParseQuery(string query)
    {
        var items = new List<KeyValuePair<string, string>>();
        if (query.Length == 0)
        {
            return items;
        }
        foreach (var pair in query.Split('&'))
        {
            if (pair.Length == 0)
            {
                continue;
            }
            var kv = pair.Split('=', 2);
            var key = Uri.UnescapeDataString(kv[0]);
            var value = kv.Length == 2 ? Uri.UnescapeDataString(kv[1]) : string.Empty;
            items.Add(new KeyValuePair<string, string>(key, value));
        }
        return items;
    }

    private static string Reassemble(string basePart, List<KeyValuePair<string, string>> items, string fragment)
    {
        var sb = new StringBuilder(basePart);
        if (items.Count > 0)
        {
            sb.Append('?');
            for (var i = 0; i < items.Count; i++)
            {
                if (i > 0)
                {
                    sb.Append('&');
                }
                sb.Append(Uri.EscapeDataString(items[i].Key));
                sb.Append('=');
                sb.Append(Uri.EscapeDataString(items[i].Value));
            }
        }
        if (fragment.Length > 0)
        {
            sb.Append('#');
            sb.Append(fragment);
        }
        return sb.ToString();
    }
}
