using System;

namespace OpenBurnBar.Integrations.HomeAssistant;

// Free-form HA URL normalization.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantConfig.swift
//   enum HomeAssistantURLNormalizer.normalize(_:).
//
// Rules:
//   - No scheme -> assume http:// for *.local hosts, https:// otherwise.
//   - Append :8123 only for http schemes that omit an explicit port.
//   - Strip any path/query/fragment (keep the origin only).

public static class HomeAssistantUrlNormalizer
{
    public const int DefaultHttpPort = 8123;

    /// Returns a canonical origin URL string, or null when the input has no
    /// usable host.
    public static string? Normalize(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        string withScheme;
        if (trimmed.Contains("://", StringComparison.Ordinal))
        {
            withScheme = trimmed;
        }
        else if (trimmed.EndsWith(".local", StringComparison.Ordinal) ||
                 trimmed.Contains(".local:", StringComparison.Ordinal))
        {
            withScheme = "http://" + trimmed;
        }
        else
        {
            withScheme = "https://" + trimmed;
        }

        if (!Uri.TryCreate(withScheme, UriKind.Absolute, out var uri))
        {
            return null;
        }

        var host = uri.Host;
        if (string.IsNullOrEmpty(host))
        {
            return null;
        }

        var scheme = uri.Scheme.ToLowerInvariant();
        var hasExplicitPort = HasExplicitPort(withScheme);

        int? port;
        if (hasExplicitPort)
        {
            port = uri.Port;
        }
        else if (scheme == "http")
        {
            port = DefaultHttpPort;
        }
        else
        {
            port = null;
        }

        // IPv6 literals must stay bracketed in the authority.
        var authorityHost = host.Contains(':', StringComparison.Ordinal) ? $"[{host}]" : host;
        return port.HasValue
            ? $"{scheme}://{authorityHost}:{port.Value}"
            : $"{scheme}://{authorityHost}";
    }

    /// True when the authority of `withScheme` carries an explicit ":port"
    /// (parity with Swift URLComponents.port being non-nil only when present).
    private static bool HasExplicitPort(string withScheme)
    {
        var schemeSplit = withScheme.IndexOf("://", StringComparison.Ordinal);
        if (schemeSplit < 0)
        {
            return false;
        }
        var afterScheme = withScheme.Substring(schemeSplit + 3);

        // Authority ends at the first path/query/fragment delimiter.
        var end = afterScheme.Length;
        foreach (var delimiter in new[] { '/', '?', '#' })
        {
            var index = afterScheme.IndexOf(delimiter);
            if (index >= 0 && index < end)
            {
                end = index;
            }
        }
        var authority = afterScheme.Substring(0, end);

        // Strip userinfo.
        var at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            authority = authority.Substring(at + 1);
        }

        if (authority.StartsWith("[", StringComparison.Ordinal))
        {
            // IPv6 literal: explicit port is a ":digits" run after the closing ']'.
            var close = authority.IndexOf(']');
            if (close < 0)
            {
                return false;
            }
            var rest = authority.Substring(close + 1);
            return rest.StartsWith(":", StringComparison.Ordinal) && rest.Length > 1;
        }

        var colon = authority.IndexOf(':');
        return colon >= 0 && colon < authority.Length - 1;
    }
}
