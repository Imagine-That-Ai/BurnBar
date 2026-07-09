using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.UiAutomationHarness.Core;

namespace OpenBurnBar.UiAutomationHarness;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
    };

    public static async Task<int> Main(string[] args)
    {
        HarnessOptions options;
        try
        {
            options = HarnessOptions.Parse(args);
        }
        catch (HelpRequestedException)
        {
            Console.WriteLine(HarnessOptions.Usage);
            return 0;
        }

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine("OpenBurnBar.UiAutomationHarness must run inside a Windows 10 2004+ or Windows 11 desktop session.");
            return 2;
        }

        string repoRoot = Path.GetFullPath(options.RepoRoot);
        string output = Path.GetFullPath(options.OutputDirectory);
        Directory.CreateDirectory(output);
        string appExe = AppExeResolver.Resolve(repoRoot, options.AppExe);
        IReadOnlyList<UiHarnessRoute> manifest = DefaultRouteCatalog.Select(options.RouteKeys);
        File.WriteAllText(Path.Combine(output, "route-manifest.json"), JsonSerializer.Serialize(manifest, JsonOptions));

        var notes = new List<string>
        {
            "Runs in a throwaway OPENBURNBAR_AUTOMATION_PROFILE_ROOT per route; no production user profile is touched.",
            "Route captures use the app route-smoke RenderTargetBitmap path; the semantic main-window probe also emits an external window screenshot.",
            "Input route evidence is classifier proof, not synthetic secure input dispatch; non-bypassable actions remain ViGEm/driver-gated.",
        };

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cts.Cancel();
        };

        var routes = new List<RouteSmokeEvidence>();
        var runner = new RouteSmokeRunner(appExe, output, options.TimeoutMilliseconds);
        foreach (UiHarnessRoute route in manifest)
        {
            Console.WriteLine($"[route] {route.Key}");
            routes.Add(await runner.RunAsync(route, cts.Token).ConfigureAwait(false));
        }

        SemanticProbeEvidence? semanticProbe = null;
        if (options.SkipSemanticProbe)
        {
            notes.Add("Semantic main-window probe skipped by --skip-semantic-probe.");
        }
        else
        {
            Console.WriteLine("[semantic] main window");
            semanticProbe = await new SemanticProbeRunner(appExe, output, options.TimeoutMilliseconds)
                .RunAsync(cts.Token)
                .ConfigureAwait(false);
        }

        IReadOnlyList<InputRouteEvidence> inputRoutes = InputRouteProbe.Capture();
        var summary = new UiHarnessRunSummary(
            GeneratedAtUtc: DateTimeOffset.UtcNow.ToString("O"),
            RepoRoot: repoRoot,
            AppExe: appExe,
            OutputDirectory: output,
            Manifest: manifest,
            Routes: routes,
            SemanticProbe: semanticProbe,
            InputRoutes: inputRoutes,
            Notes: notes);

        var redactor = new ArtifactRedactor(repoRoot, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        string summaryPath = Path.Combine(output, "summary.json");
        await File.WriteAllTextAsync(summaryPath, redactor.Redact(JsonSerializer.Serialize(summary, JsonOptions)), cts.Token).ConfigureAwait(false);
        JUnitReportWriter.Write(Path.Combine(output, "junit.xml"), summary, redactor);
        HtmlReportWriter.Write(Path.Combine(output, "index.html"), summary, redactor);

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            verdict = summary.Verdict.ToString(),
            outputDirectory = output,
            summaryPath,
            routeCount = routes.Count,
            failedRoutes = routes.FindAll(route => route.Verdict == HarnessVerdict.Fail).ConvertAll(route => route.RouteKey),
            semanticProbe = semanticProbe?.Verdict.ToString(),
        }, JsonOptions));

        return summary.Verdict == HarnessVerdict.Pass ? 0 : 1;
    }
}
