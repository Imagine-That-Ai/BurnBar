using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.App.Shell;

internal sealed class RouteSmokeOptions
{
    private RouteSmokeOptions(
        string routeKey,
        string outputDirectory,
        int timeoutMilliseconds,
        int holdMilliseconds,
        int? windowWidth,
        int? windowHeight)
    {
        RouteKey = routeKey;
        OutputDirectory = outputDirectory;
        TimeoutMilliseconds = timeoutMilliseconds;
        HoldMilliseconds = holdMilliseconds;
        WindowWidth = windowWidth;
        WindowHeight = windowHeight;
    }

    public string RouteKey { get; }
    public string OutputDirectory { get; }
    public int TimeoutMilliseconds { get; }
    public int HoldMilliseconds { get; }
    public int? WindowWidth { get; }
    public int? WindowHeight { get; }

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
        int? windowWidth = null;
        int? windowHeight = null;
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
            else if (string.Equals(token, "--route-smoke-window-width", StringComparison.OrdinalIgnoreCase)
                && i + 1 < parts.Count
                && int.TryParse(parts[++i], out int parsedWidth)
                && parsedWidth > 0)
            {
                windowWidth = Math.Clamp(parsedWidth, 480, 3840);
            }
            else if (string.Equals(token, "--route-smoke-window-height", StringComparison.OrdinalIgnoreCase)
                && i + 1 < parts.Count
                && int.TryParse(parts[++i], out int parsedHeight)
                && parsedHeight > 0)
            {
                windowHeight = Math.Clamp(parsedHeight, 480, 2160);
            }
        }

        if (string.IsNullOrWhiteSpace(route))
        {
            return null;
        }

        output = string.IsNullOrWhiteSpace(output)
            ? Path.Combine(Path.GetTempPath(), "openburnbar-route-smoke")
            : output;
        return new RouteSmokeOptions(route.Trim(), output, timeout, hold, windowWidth, windowHeight);
    }

}
