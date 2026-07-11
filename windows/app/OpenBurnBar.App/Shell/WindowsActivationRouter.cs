using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace OpenBurnBar.App.Shell;

internal enum WindowsActivationKind
{
    Launch,
    Protocol,
    File,
    Toast,
    Unknown,
}

internal sealed record WindowsActivationRequest(
    WindowsActivationKind Kind,
    string Source,
    string? Raw,
    IReadOnlyList<string> Files,
    Uri? Uri);

internal sealed record WindowsActivationRoute(
    string RouteKey,
    bool OpensMainWindow,
    string Reason,
    string? Payload = null);

internal static class WindowsActivationRouter
{
    private static readonly IReadOnlyDictionary<string, string> RouteAliases =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["analysis"] = "elderWand",
            ["analysis-models"] = "elderWand",
            ["budget"] = "budget",
            ["chat"] = "chat",
            ["data"] = "dataControlCenter",
            ["data-control"] = "dataControlCenter",
            ["data-control-center"] = "dataControlCenter",
            ["database"] = "database",
            ["dashboard"] = "dashboard",
            ["home"] = "dashboard",
            ["insights"] = "insights",
            ["memory"] = "memory",
            ["mission"] = "missionControl",
            ["mission-control"] = "missionControl",
            ["missions"] = "missionControl",
            ["onboarding"] = "onboarding",
            ["projects"] = "projects",
            ["quota"] = "quota",
            ["session-logs"] = "sessionLogs",
            ["sessions"] = "sessionLogs",
            ["settings"] = "settings",
            ["switcher"] = "switcher",
            ["updates"] = "settings",
        };

    public static WindowsActivationRequest FromLaunchArguments(string? arguments) =>
        new(WindowsActivationKind.Launch, "launch", arguments, Array.Empty<string>(), TryFirstProtocolUri(arguments));

    public static WindowsActivationRequest FromProtocolUri(string? uri)
    {
        Uri? parsed = Uri.TryCreate(uri, UriKind.Absolute, out Uri? value) ? value : null;
        return new WindowsActivationRequest(WindowsActivationKind.Protocol, "protocol", uri, Array.Empty<string>(), parsed);
    }

    public static WindowsActivationRequest FromFiles(IEnumerable<string?> files)
    {
        string[] paths = files
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => path!.Trim())
            .ToArray();
        return new WindowsActivationRequest(WindowsActivationKind.File, "file", string.Join(Environment.NewLine, paths), paths, null);
    }

    public static WindowsActivationRequest FromToastArguments(string? arguments) =>
        new(WindowsActivationKind.Toast, "toast", arguments, Array.Empty<string>(), TryFirstProtocolUri(arguments));

    public static WindowsActivationRequest FromAppLifecycleArguments(string kind, object? data)
    {
        string kindText = kind.Trim();
        if (kindText.Contains("Protocol", StringComparison.OrdinalIgnoreCase))
        {
            return FromProtocolUri(ReadProperty(data, "Uri") ?? ReadProperty(data, "ProtocolUri"));
        }

        if (kindText.Contains("File", StringComparison.OrdinalIgnoreCase))
        {
            return FromFiles(ReadFilePaths(data));
        }

        if (kindText.Contains("Toast", StringComparison.OrdinalIgnoreCase))
        {
            return FromToastArguments(ReadProperty(data, "Argument") ?? ReadProperty(data, "Arguments"));
        }

        if (kindText.Contains("Launch", StringComparison.OrdinalIgnoreCase))
        {
            return FromLaunchArguments(ReadProperty(data, "Arguments"));
        }

        return new WindowsActivationRequest(
            WindowsActivationKind.Unknown,
            kindText.Length == 0 ? "unknown" : kindText,
            ReadProperty(data, "Arguments") ?? data?.ToString(),
            Array.Empty<string>(),
            null);
    }

    public static WindowsActivationRoute? Resolve(WindowsActivationRequest request)
    {
        string? route = request.Kind switch
        {
            WindowsActivationKind.Protocol => RouteFromUri(request.Uri),
            WindowsActivationKind.File => RouteFromFiles(request.Files),
            WindowsActivationKind.Toast => RouteFromToast(request.Raw),
            WindowsActivationKind.Launch => RouteFromLaunch(request.Raw) ?? RouteFromUri(request.Uri),
            _ => RouteFromLaunch(request.Raw) ?? RouteFromUri(request.Uri),
        };

        if (route is null)
        {
            return request.Kind == WindowsActivationKind.Launch
                ? null
                : new WindowsActivationRoute(NavCatalog.Default.Key, OpensMainWindow: true, request.Kind.ToString());
        }

        string payload = string.Equals(route, "settings", StringComparison.Ordinal)
            && (ContainsToken(request.Raw, "updates") || request.Uri?.AbsolutePath.Contains("updates", StringComparison.OrdinalIgnoreCase) == true)
                ? "updates"
                : string.Empty;

        return new WindowsActivationRoute(
            route,
            OpensMainWindow: request.Kind != WindowsActivationKind.Launch || !string.IsNullOrWhiteSpace(request.Raw),
            request.Kind.ToString(),
            string.IsNullOrWhiteSpace(payload) ? null : payload);
    }

    private static string? RouteFromLaunch(string? arguments)
    {
        IReadOnlyList<string> tokens = Split(arguments);
        for (int i = 0; i < tokens.Count; i++)
        {
            string token = tokens[i];
            if (IsRouteFlag(token) && i + 1 < tokens.Count)
            {
                return NormalizeRoute(tokens[++i]);
            }

            if (token.StartsWith("openburnbar://", StringComparison.OrdinalIgnoreCase))
            {
                return RouteFromUri(Uri.TryCreate(token, UriKind.Absolute, out Uri? uri) ? uri : null);
            }

            if (IsSupportedFile(token))
            {
                return RouteFromFiles(new[] { token });
            }
        }

        return null;
    }

    private static string? RouteFromToast(string? arguments)
    {
        Uri? uri = TryFirstProtocolUri(arguments);
        if (uri is not null)
        {
            return RouteFromUri(uri);
        }

        foreach (KeyValuePair<string, string> pair in ParsePairs(arguments))
        {
            if (pair.Key is "route" or "open" or "destination" or "action")
            {
                if (pair.Value.Contains("update", StringComparison.OrdinalIgnoreCase))
                {
                    return "settings";
                }

                return NormalizeRoute(pair.Value);
            }
        }

        return null;
    }

    private static string? RouteFromUri(Uri? uri)
    {
        if (uri is null)
        {
            return null;
        }

        foreach (KeyValuePair<string, string> pair in ParsePairs(uri.Query))
        {
            if (pair.Key is "route" or "open" or "destination")
            {
                return NormalizeRoute(pair.Value);
            }
        }

        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(uri.Host))
        {
            candidates.Add(uri.Host);
        }

        candidates.AddRange(uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries));
        foreach (string candidate in candidates)
        {
            string? route = NormalizeRoute(candidate);
            if (route is not null)
            {
                return route;
            }
        }

        return null;
    }

    private static string? RouteFromFiles(IReadOnlyList<string> files)
    {
        if (files.Count == 0)
        {
            return null;
        }

        string extension = Path.GetExtension(files[0]);
        if (string.Equals(extension, ".burnbarchat", StringComparison.OrdinalIgnoreCase))
        {
            return "chat";
        }

        if (string.Equals(extension, ".burnbarpane", StringComparison.OrdinalIgnoreCase))
        {
            return "dashboard";
        }

        return "chat";
    }

    private static string? NormalizeRoute(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        string key = Uri.UnescapeDataString(raw.Trim().Trim('/', '\\')).Replace("_", "-", StringComparison.Ordinal);
        if (NavCatalog.Find(key) is not null)
        {
            return key;
        }

        return RouteAliases.TryGetValue(key, out string? route) ? route : null;
    }

    private static bool IsRouteFlag(string token) =>
        token.Equals("--openburnbar-route", StringComparison.OrdinalIgnoreCase)
        || token.Equals("--route", StringComparison.OrdinalIgnoreCase)
        || token.Equals("--open", StringComparison.OrdinalIgnoreCase)
        || token.Equals("/route", StringComparison.OrdinalIgnoreCase);

    private static bool IsSupportedFile(string token)
    {
        string extension = Path.GetExtension(token);
        return string.Equals(extension, ".burnbarchat", StringComparison.OrdinalIgnoreCase)
            || string.Equals(extension, ".burnbarpane", StringComparison.OrdinalIgnoreCase);
    }

    private static bool ContainsToken(string? text, string token) =>
        !string.IsNullOrWhiteSpace(text)
        && text.Split(new[] { '&', ';', '?', '/', ' ', '=' }, StringSplitOptions.RemoveEmptyEntries)
            .Any(part => string.Equals(part, token, StringComparison.OrdinalIgnoreCase));

    private static IReadOnlyList<string> Split(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
        {
            return Array.Empty<string>();
        }

        var parts = new List<string>();
        var current = new System.Text.StringBuilder();
        bool quoted = false;
        foreach (char c in arguments)
        {
            if (c == '"')
            {
                quoted = !quoted;
                continue;
            }

            if (char.IsWhiteSpace(c) && !quoted)
            {
                Flush();
                continue;
            }

            current.Append(c);
        }

        Flush();
        return parts;

        void Flush()
        {
            if (current.Length == 0) return;
            parts.Add(current.ToString());
            current.Clear();
        }
    }

    private static IEnumerable<KeyValuePair<string, string>> ParsePairs(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            yield break;
        }

        string trimmed = text.Trim().TrimStart('?');
        foreach (string part in trimmed.Split(new[] { '&', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string[] pair = part.Split('=', 2);
            if (pair.Length != 2) continue;
            string key = Uri.UnescapeDataString(pair[0]).Trim().ToLowerInvariant();
            string value = Uri.UnescapeDataString(pair[1]).Trim();
            if (key.Length > 0 && value.Length > 0)
            {
                yield return new KeyValuePair<string, string>(key, value);
            }
        }
    }

    private static Uri? TryFirstProtocolUri(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        foreach (string token in Split(text))
        {
            if (token.StartsWith("openburnbar://", StringComparison.OrdinalIgnoreCase)
                && Uri.TryCreate(token, UriKind.Absolute, out Uri? uri))
            {
                return uri;
            }
        }

        return null;
    }

    private static string? ReadProperty(object? instance, string name)
    {
        if (instance is null) return null;
        object? value = instance.GetType().GetProperty(name)?.GetValue(instance);
        return value switch
        {
            null => null,
            Uri uri => uri.ToString(),
            _ => value.ToString(),
        };
    }

    private static IEnumerable<string> ReadFilePaths(object? data)
    {
        object? files = data?.GetType().GetProperty("Files")?.GetValue(data);
        if (files is not IEnumerable enumerable)
        {
            yield break;
        }

        foreach (object? item in enumerable)
        {
            string? path = ReadProperty(item, "Path") ?? ReadProperty(item, "Name");
            if (!string.IsNullOrWhiteSpace(path))
            {
                yield return path;
            }
        }
    }
}
