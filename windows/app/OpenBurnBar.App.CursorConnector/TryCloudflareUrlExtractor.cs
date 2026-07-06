using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.CursorConnector;

// ── try-cloudflare URL extractor ─────────────────────────────────────────────
//
// Faithful Windows peer of CursorConnectorManager.extractTryCloudflareURL +
// isCanonicalTryCloudflareHost + the tryCloudflareURLDelimiters set. This scans
// cloudflared's stdout for the ephemeral quick-tunnel URL and accepts ONLY a
// canonical `https://<label>.trycloudflare.com` with no userinfo, no explicit
// port, no query/fragment, and an empty or "/" path — the same hardening the Mac
// applies so a hostile log line can't smuggle a look-alike endpoint into the
// user's Cursor settings. The host must be plain ASCII (letters/digits/hyphen per
// label), which subsumes Swift's `host == percentEncodedHost` guard.

/// <summary>Extracts the canonical try-cloudflare quick-tunnel URL from log text.</summary>
public static class TryCloudflareUrlExtractor
{
    // Swift CharacterSet.tryCloudflareURLDelimiters (whitespace handled by the split).
    private static readonly char[] Delimiters = "<>()[]{}\"'`,;".ToCharArray();

    /// <summary>Swift <c>extractTryCloudflareURL(from:)</c>.</summary>
    public static string? Extract(string text)
    {
        if (text is null)
        {
            throw new ArgumentNullException(nameof(text));
        }

        foreach (var token in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = TrimDelimiters(token);
            if (TryCanonicalHost(candidate, out var host))
            {
                return "https://" + host;
            }
        }

        return null;
    }

    private static string TrimDelimiters(string token)
    {
        // Swift trims the delimiter set (and whitespace) from BOTH ends.
        var trimmed = token.Trim();
        return trimmed.Trim(Delimiters);
    }

    private static bool TryCanonicalHost(string candidate, out string host)
    {
        host = string.Empty;

        var schemeSeparator = candidate.IndexOf("://", StringComparison.Ordinal);
        if (schemeSeparator <= 0)
        {
            return false;
        }

        var scheme = candidate.Substring(0, schemeSeparator);
        if (!scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var rest = candidate.Substring(schemeSeparator + 3);
        if (rest.Length == 0 || rest.IndexOf('@') >= 0)
        {
            // Empty authority or an embedded userinfo ("user@host") — reject.
            return false;
        }

        // Authority runs to the first path/query/fragment delimiter.
        var authorityEnd = rest.IndexOfAny(new[] { '/', '?', '#' });
        var authority = authorityEnd < 0 ? rest : rest.Substring(0, authorityEnd);
        var remainder = authorityEnd < 0 ? string.Empty : rest.Substring(authorityEnd);

        if (authority.IndexOf(':') >= 0)
        {
            // An explicit port (Swift requires components.port == nil).
            return false;
        }

        // Swift requires path empty-or-"/", query == nil, fragment == nil.
        if (remainder.Length != 0 && remainder != "/")
        {
            return false;
        }

        var lowercased = authority.ToLowerInvariant();
        if (!IsCanonicalTryCloudflareHost(lowercased))
        {
            return false;
        }

        host = lowercased;
        return true;
    }

    /// <summary>Swift <c>isCanonicalTryCloudflareHost(_:)</c>.</summary>
    public static bool IsCanonicalTryCloudflareHost(string host)
    {
        var labels = host.Split('.');
        if (labels.Length != 3
            || labels[1] != "trycloudflare"
            || labels[2] != "com")
        {
            return false;
        }

        var tunnelLabel = labels[0];
        if (tunnelLabel.Length < 1 || tunnelLabel.Length > 63)
        {
            return false;
        }

        if (!IsAsciiLetterOrNumber(tunnelLabel[0]) || !IsAsciiLetterOrNumber(tunnelLabel[tunnelLabel.Length - 1]))
        {
            return false;
        }

        foreach (var character in tunnelLabel)
        {
            if (!IsAsciiLetterOrNumber(character) && character != '-')
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsAsciiLetterOrNumber(char scalar) =>
        (scalar >= 'a' && scalar <= 'z') || (scalar >= '0' && scalar <= '9');
}
