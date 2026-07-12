using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.App.Shell;

internal sealed class RouteSmokeOptions
{
    private RouteSmokeOptions(string routeKey, string outputDirectory, int timeoutMilliseconds, int holdMilliseconds)
    {
        RouteKey = routeKey;
        OutputDirectory = outputDirectory;
        TimeoutMilliseconds = timeoutMilliseconds;
        HoldMilliseconds = holdMilliseconds;
    }

    public string RouteKey { get; }
    public string OutputDirectory { get; }
    public int TimeoutMilliseconds { get; }
    public int HoldMilliseconds { get; }

    public static RouteSmokeOptions? Parse(string? arguments)
    {
        IReadOnlyList<string> parts = CommandLineParts.Split(arguments);
        if (parts.Count == 0)
        {
            return null;
        }

        string? route = null;
        string? output = null;
        int timeout = 8000;
        int hold = 0;
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
            else if (string.Equals(token, "--route-smoke-hold-ms", StringComparison.OrdinalIgnoreCase)
                && i + 1 < parts.Count
                && int.TryParse(parts[++i], out int parsedHold)
                && parsedHold > 0)
            {
                hold = Math.Min(parsedHold, 60_000);
            }
        }

        if (string.IsNullOrWhiteSpace(route))
        {
            return null;
        }

        output = string.IsNullOrWhiteSpace(output)
            ? Path.Combine(Path.GetTempPath(), "openburnbar-route-smoke")
            : output;
        return new RouteSmokeOptions(route.Trim(), output, timeout, hold);
    }

}
