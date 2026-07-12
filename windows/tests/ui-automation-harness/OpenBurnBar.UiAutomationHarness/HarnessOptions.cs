using System;
using System.Collections.Generic;
using System.IO;

namespace OpenBurnBar.UiAutomationHarness;

internal sealed class HarnessOptions
{
    public string RepoRoot { get; private init; } = Directory.GetCurrentDirectory();
    public string? AppExe { get; private init; }
    public string OutputDirectory { get; private init; } = Path.Combine(
        Directory.GetCurrentDirectory(),
        ".artifacts",
        "windows-ui-automation",
        DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssZ"));
    public IReadOnlyList<string>? RouteKeys { get; private init; }
    public int TimeoutMilliseconds { get; private init; } = 12_000;
    public bool SkipSemanticProbe { get; private init; }
    public string CertificationProfile { get; private init; } = "baseline";

    public static HarnessOptions Parse(string[] args)
    {
        var options = new HarnessOptions();
        var routes = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            string token = args[i];
            if (Is(token, "--repo-root") && TryValue(args, ref i, out string? repoRoot))
            {
                options = WithRepoRoot(options, repoRoot);
            }
            else if (Is(token, "--app-exe") && TryValue(args, ref i, out string? appExe))
            {
                options = WithAppExe(options, appExe);
            }
            else if (Is(token, "--output") && TryValue(args, ref i, out string? output))
            {
                options = WithOutput(options, output);
            }
            else if (Is(token, "--routes") && TryValue(args, ref i, out string? routeList))
            {
                foreach (string route in routeList.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    routes.Add(route);
                }
            }
            else if (Is(token, "--route") && TryValue(args, ref i, out string? route))
            {
                routes.Add(route);
            }
            else if (Is(token, "--timeout-ms") && TryValue(args, ref i, out string? timeout) && int.TryParse(timeout, out int parsed) && parsed > 0)
            {
                options = WithTimeout(options, parsed);
            }
            else if (Is(token, "--certification-profile") && TryValue(args, ref i, out string? profile))
            {
                options = WithCertificationProfile(options, profile);
            }
            else if (Is(token, "--skip-semantic-probe"))
            {
                options = WithSkipSemanticProbe(options);
            }
            else if (Is(token, "--help") || Is(token, "-h"))
            {
                throw new HelpRequestedException();
            }
        }

        return routes.Count == 0 ? options : WithRoutes(options, routes);
    }

    private static HarnessOptions WithRepoRoot(HarnessOptions options, string value) => new()
    {
        RepoRoot = Path.GetFullPath(value),
        AppExe = options.AppExe,
        OutputDirectory = options.OutputDirectory,
        RouteKeys = options.RouteKeys,
        TimeoutMilliseconds = options.TimeoutMilliseconds,
        SkipSemanticProbe = options.SkipSemanticProbe,
        CertificationProfile = options.CertificationProfile,
    };

    private static HarnessOptions WithAppExe(HarnessOptions options, string value) => new()
    {
        RepoRoot = options.RepoRoot,
        AppExe = Path.GetFullPath(value),
        OutputDirectory = options.OutputDirectory,
        RouteKeys = options.RouteKeys,
        TimeoutMilliseconds = options.TimeoutMilliseconds,
        SkipSemanticProbe = options.SkipSemanticProbe,
        CertificationProfile = options.CertificationProfile,
    };

    private static HarnessOptions WithOutput(HarnessOptions options, string value) => new()
    {
        RepoRoot = options.RepoRoot,
        AppExe = options.AppExe,
        OutputDirectory = Path.GetFullPath(value),
        RouteKeys = options.RouteKeys,
        TimeoutMilliseconds = options.TimeoutMilliseconds,
        SkipSemanticProbe = options.SkipSemanticProbe,
        CertificationProfile = options.CertificationProfile,
    };

    private static HarnessOptions WithRoutes(HarnessOptions options, IReadOnlyList<string> value) => new()
    {
        RepoRoot = options.RepoRoot,
        AppExe = options.AppExe,
        OutputDirectory = options.OutputDirectory,
        RouteKeys = value,
        TimeoutMilliseconds = options.TimeoutMilliseconds,
        SkipSemanticProbe = options.SkipSemanticProbe,
        CertificationProfile = options.CertificationProfile,
    };

    private static HarnessOptions WithTimeout(HarnessOptions options, int value) => new()
    {
        RepoRoot = options.RepoRoot,
        AppExe = options.AppExe,
        OutputDirectory = options.OutputDirectory,
        RouteKeys = options.RouteKeys,
        TimeoutMilliseconds = value,
        SkipSemanticProbe = options.SkipSemanticProbe,
        CertificationProfile = options.CertificationProfile,
    };

    private static HarnessOptions WithCertificationProfile(HarnessOptions options, string value) => new()
    {
        RepoRoot = options.RepoRoot,
        AppExe = options.AppExe,
        OutputDirectory = options.OutputDirectory,
        RouteKeys = options.RouteKeys,
        TimeoutMilliseconds = options.TimeoutMilliseconds,
        SkipSemanticProbe = options.SkipSemanticProbe,
        CertificationProfile = string.IsNullOrWhiteSpace(value) ? "baseline" : value.Trim(),
    };

    private static HarnessOptions WithSkipSemanticProbe(HarnessOptions options) => new()
    {
        RepoRoot = options.RepoRoot,
        AppExe = options.AppExe,
        OutputDirectory = options.OutputDirectory,
        RouteKeys = options.RouteKeys,
        TimeoutMilliseconds = options.TimeoutMilliseconds,
        SkipSemanticProbe = true,
        CertificationProfile = options.CertificationProfile,
    };

    public static string Usage =>
        """
        OpenBurnBar.UiAutomationHarness

        Required runtime: Windows 11 desktop session with OpenBurnBar.App already built.

        Options:
          --repo-root <dir>           Repository root. Defaults to current directory.
          --app-exe <path>            OpenBurnBar.App.exe. Defaults to newest build under windows/app/OpenBurnBar.App/bin.
          --output <dir>              Artifact directory. Defaults to .artifacts/windows-ui-automation/<timestamp>.
          --routes <a,b,c>            Comma-separated route keys. Defaults to all supported routes.
          --route <key>               Add one route key; may be repeated.
          --timeout-ms <number>       Per-route process timeout. Defaults to 12000.
          --certification-profile <p> Scenario profile: baseline, accessibility, or all. Defaults to baseline.
          --skip-semantic-probe       Skip persistent main-window UIA/capture probe.
        """;

    private static bool Is(string actual, string expected) => string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);

    private static bool TryValue(string[] args, ref int index, out string value)
    {
        if (index + 1 >= args.Length)
        {
            value = string.Empty;
            return false;
        }

        value = args[++index];
        return true;
    }
}

internal sealed class HelpRequestedException : Exception
{
}
