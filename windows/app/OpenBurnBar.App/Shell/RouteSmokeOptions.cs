using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.App.Shell;

internal sealed class RouteSmokeOptions
{
    private RouteSmokeOptions(string routeKey, string outputDirectory, int timeoutMilliseconds)
    {
        RouteKey = routeKey;
        OutputDirectory = outputDirectory;
        TimeoutMilliseconds = timeoutMilliseconds;
    }

    public string RouteKey { get; }
    public string OutputDirectory { get; }
    public int TimeoutMilliseconds { get; }

    public static RouteSmokeOptions? Parse(string? arguments)
    {
        IReadOnlyList<string> parts = Split(arguments);
        if (parts.Count == 0)
        {
            return null;
        }

        string? route = null;
        string? output = null;
        int timeout = 8000;
        for (var i = 0; i < parts.Count; i++)
        {
            string token = parts[i];
            if (string.Equals(token, "--route-smoke", StringComparison.OrdinalIgnoreCase))
            {
                route = i + 1 < parts.Count ? parts[++i] : null;
            }
            else if (string.Equals(token, "--route-smoke-out", StringComparison.OrdinalIgnoreCase))
            {
                output = i + 1 < parts.Count ? parts[++i] : null;
            }
            else if (string.Equals(token, "--route-smoke-timeout-ms", StringComparison.OrdinalIgnoreCase)
                && i + 1 < parts.Count
                && int.TryParse(parts[++i], out int parsed)
                && parsed > 0)
            {
                timeout = parsed;
            }
        }

        if (string.IsNullOrWhiteSpace(route))
        {
            return null;
        }

        output = string.IsNullOrWhiteSpace(output)
            ? Path.Combine(Path.GetTempPath(), "openburnbar-route-smoke")
            : output;
        return new RouteSmokeOptions(route.Trim(), output, timeout);
    }

    private static IReadOnlyList<string> Split(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments))
        {
            return Array.Empty<string>();
        }

        var parts = new List<string>();
        var current = new System.Text.StringBuilder();
        var quoted = false;
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
            if (current.Length == 0)
            {
                return;
            }

            parts.Add(current.ToString());
            current.Clear();
        }
    }
}
