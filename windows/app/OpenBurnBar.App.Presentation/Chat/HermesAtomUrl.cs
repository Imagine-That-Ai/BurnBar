using System;
using System.Collections.Generic;
using System.Globalization;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Hermes Atom URL Codec
//
// C# peer of `OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomURL.swift`.
//
// Canonical `burnbar://` URL encoding for `HermesAtom`. The same vocabulary is
// documented to Hermes via the system prompt builder so the model emits matching
// markdown links the client can decode:
//
//   burnbar://burn?window=today&amount=2.34
//   burnbar://session?id=abc-123
//   burnbar://provider?token=anthropic
//   burnbar://model?id=claude-sonnet-4.7
//   burnbar://window?value=7d
//   burnbar://tool?name=ReadFile
//   burnbar://project?id=BurnBar
//   burnbar://tokens?value=12400&scope=today
//   burnbar://quota?provider=anthropic&percent=78
//   burnbar://runtime?profile=hermes

public static class HermesAtomUrl
{
    /// Canonical scheme used for in-app navigation links emitted by Hermes.
    public const string Scheme = "burnbar";

    /// Encode a <see cref="HermesAtom"/> to its canonical `burnbar://` URL string.
    /// Mirrors the Swift `URLComponents` builder (host = kind, query = payload).
    public static string Encode(HermesAtom atom)
    {
        switch (atom)
        {
            case HermesAtom.Cost c:
                return Build("burn", ("window", c.Window.ToRawValue()),
                    ("amount", c.Amount.ToString("R", CultureInfo.InvariantCulture)));
            case HermesAtom.Session s:
                return Build("session", ("id", s.Id));
            case HermesAtom.ProviderRef p:
                return Build("provider", ("token", p.Token));
            case HermesAtom.Model m:
                return Build("model", ("id", m.Id));
            case HermesAtom.WindowRef w:
                return Build("window", ("value", w.Value.ToRawValue()));
            case HermesAtom.Tool t:
                return Build("tool", ("name", t.Name));
            case HermesAtom.Project pr:
                return Build("project", ("id", pr.Id));
            case HermesAtom.Tokens tk:
                return Build("tokens", ("value", tk.Value.ToString(CultureInfo.InvariantCulture)),
                    ("scope", tk.Scope.ToRawValue()));
            case HermesAtom.Quota q:
                return Build("quota", ("provider", q.Provider),
                    ("percent", q.Percent.ToString(CultureInfo.InvariantCulture)));
            case HermesAtom.Runtime r:
                return Build("runtime", ("profile", r.Profile));
            default:
                return $"{Scheme}://unknown";
        }
    }

    /// Decode a URL string back to a <see cref="HermesAtom"/>. Returns
    /// <c>null</c> for any string that is not a recognized `burnbar://` atom —
    /// callers fall back to rendering the link as plain text. Byte-for-byte port
    /// of Swift `HermesAtomURL.decode`.
    public static HermesAtom? Decode(string? urlString)
    {
        if (string.IsNullOrEmpty(urlString))
        {
            return null;
        }
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var uri))
        {
            return null;
        }
        if (!string.Equals(uri.Scheme, Scheme, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        // Swift reads the URL "host" as the atom kind. For `scheme://host?query`
        // the .NET Uri exposes it as Host; guard against forms that route the
        // kind into the path (e.g. `burnbar:///burn`).
        var host = uri.Host;
        if (string.IsNullOrEmpty(host))
        {
            return null;
        }
        host = host.ToLowerInvariant();

        var parms = UniqueQueryParams(uri.Query);
        if (parms is null)
        {
            return null;
        }
        return Decode(host, parms);
    }

    private static HermesAtom? Decode(string host, IReadOnlyDictionary<string, string> parms)
    {
        switch (host)
        {
            case "burn":
            {
                var window = (parms.TryGetValue("window", out var wRaw)
                    ? HermesAtomWindowRaw.FromRawValue(wRaw) : null) ?? HermesAtomWindow.Today;
                var amount = parms.TryGetValue("amount", out var aRaw)
                    && double.TryParse(aRaw, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                    ? parsed : 0;
                return new HermesAtom.Cost(amount, window);
            }
            case "session":
                return NonEmpty(parms, "id") is { } id ? new HermesAtom.Session(id) : null;
            case "provider":
                return NonEmpty(parms, "token") is { } token ? new HermesAtom.ProviderRef(token) : null;
            case "model":
                return NonEmpty(parms, "id") is { } mid ? new HermesAtom.Model(mid) : null;
            case "window":
            {
                var value = parms.TryGetValue("value", out var vRaw)
                    ? HermesAtomWindowRaw.FromRawValue(vRaw) : null;
                return value is { } v ? new HermesAtom.WindowRef(v) : null;
            }
            case "tool":
                return NonEmpty(parms, "name") is { } name ? new HermesAtom.Tool(name) : null;
            case "project":
                return NonEmpty(parms, "id") is { } pid ? new HermesAtom.Project(pid) : null;
            case "tokens":
            {
                if (!parms.TryGetValue("value", out var raw)
                    || !int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
                {
                    return null;
                }
                var scope = (parms.TryGetValue("scope", out var sRaw)
                    ? HermesAtomTokenScopeRaw.FromRawValue(sRaw) : null) ?? HermesAtomTokenScope.Unspecified;
                return new HermesAtom.Tokens(value, scope);
            }
            case "quota":
            {
                var provider = NonEmpty(parms, "provider");
                if (provider is null
                    || !parms.TryGetValue("percent", out var pctRaw)
                    || !int.TryParse(pctRaw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var percent))
                {
                    return null;
                }
                return new HermesAtom.Quota(provider, percent);
            }
            case "runtime":
                return NonEmpty(parms, "profile") is { } profile ? new HermesAtom.Runtime(profile) : null;
            default:
                return null;
        }
    }

    // Reject duplicate query keys (matches the Swift `uniqueQueryParams` guard:
    // a repeated key returns nil for the whole URL). Keys are lower-cased.
    private static Dictionary<string, string>? UniqueQueryParams(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var trimmed = query.StartsWith("?", StringComparison.Ordinal) ? query.Substring(1) : query;
        if (trimmed.Length == 0)
        {
            return result;
        }
        foreach (var pair in trimmed.Split('&'))
        {
            if (pair.Length == 0)
            {
                continue;
            }
            var eq = pair.IndexOf('=');
            if (eq < 0)
            {
                continue; // no value — Swift skips items whose value is nil.
            }
            var name = Uri.UnescapeDataString(pair.Substring(0, eq)).ToLowerInvariant();
            var value = Uri.UnescapeDataString(pair.Substring(eq + 1));
            if (result.ContainsKey(name))
            {
                return null;
            }
            result[name] = value;
        }
        return result;
    }

    private static string? NonEmpty(IReadOnlyDictionary<string, string> parms, string key) =>
        parms.TryGetValue(key, out var value) && value.Length > 0 ? value : null;

    private static string Build(string host, params (string Name, string Value)[] query)
    {
        var builder = new System.Text.StringBuilder();
        builder.Append(Scheme).Append("://").Append(host);
        for (var i = 0; i < query.Length; i++)
        {
            builder.Append(i == 0 ? '?' : '&');
            builder.Append(Uri.EscapeDataString(query[i].Name));
            builder.Append('=');
            builder.Append(Uri.EscapeDataString(query[i].Value));
        }
        return builder.ToString();
    }
}
