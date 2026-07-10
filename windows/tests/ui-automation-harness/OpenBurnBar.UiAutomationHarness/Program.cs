using System;
using System.Collections.Generic;
using System.Linq;
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
        IReadOnlyList<UiCertificationScenario> scenarios;
        try
        {
            scenarios = CertificationScenarioCatalog.Select(options.CertificationProfile);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }

        File.WriteAllText(Path.Combine(output, "route-manifest.json"), JsonSerializer.Serialize(manifest, JsonOptions));
        File.WriteAllText(Path.Combine(output, "certification-scenarios.json"), JsonSerializer.Serialize(scenarios, JsonOptions));

        var notes = new List<string>
        {
            "Runs in a throwaway OPENBURNBAR_AUTOMATION_PROFILE_ROOT per route; no production user profile is touched.",
            "Route captures use the app route-smoke RenderTargetBitmap path; the semantic main-window probe also emits an external window screenshot.",
            "Input route evidence is classifier proof, not synthetic secure input dispatch; non-bypassable actions remain ViGEm/driver-gated.",
            $"Certification profile: {options.CertificationProfile}.",
        };

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cts.Cancel();
        };

        var routes = new List<RouteSmokeEvidence>();
        var runner = new RouteSmokeRunner(appExe, output, options.TimeoutMilliseconds);
        bool cancellationRequested = false;
        foreach (UiCertificationScenario scenario in scenarios)
        {
            IReadOnlyList<UiHarnessRoute> scenarioRoutes = SelectScenarioRoutes(manifest, scenario);
            if (scenarioRoutes.Count == 0)
            {
                notes.Add($"Scenario {scenario.Key} has no selected routes; it contributed manifest evidence only.");
                continue;
            }

            foreach (UiHarnessRoute route in scenarioRoutes)
            {
                Console.WriteLine($"[route] {scenario.Key}/{route.Key}");
                try
                {
                    routes.Add(await runner.RunAsync(route, scenario, cts.Token).ConfigureAwait(false));
                }
                catch (OperationCanceledException) when (cts.IsCancellationRequested)
                {
                    cancellationRequested = true;
                    notes.Add("Run cancelled by operator request; partial evidence was written.");
                    routes.Add(CancelledRoute(route, scenario));
                    break;
                }
            }

            if (cancellationRequested)
            {
                break;
            }
        }

        SemanticProbeEvidence? semanticProbe = null;
        if (cancellationRequested)
        {
            semanticProbe = CancelledSemanticProbe("Semantic main-window probe was not run because cancellation was requested.");
        }
        else if (options.SkipSemanticProbe)
        {
            notes.Add("Semantic main-window probe skipped by --skip-semantic-probe.");
        }
        else
        {
            Console.WriteLine("[semantic] main window");
            try
            {
                semanticProbe = await new SemanticProbeRunner(appExe, output, options.TimeoutMilliseconds)
                    .RunAsync(cts.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested)
            {
                cancellationRequested = true;
                notes.Add("Run cancelled by operator request; partial evidence was written.");
                semanticProbe = CancelledSemanticProbe("Semantic main-window probe was cancelled by operator request.");
            }
        }

        IReadOnlyList<InputRouteEvidence> inputRoutes = cancellationRequested
            ? Array.Empty<InputRouteEvidence>()
            : InputRouteProbe.Capture();
        var summary = new UiHarnessRunSummary(
            GeneratedAtUtc: DateTimeOffset.UtcNow.ToString("O"),
            RepoRoot: repoRoot,
            AppExe: appExe,
            OutputDirectory: output,
            CertificationProfile: options.CertificationProfile,
            Scenarios: scenarios,
            Manifest: manifest,
            Routes: routes,
            SemanticProbe: semanticProbe,
            InputRoutes: inputRoutes,
            Notes: notes);

        var redactor = new ArtifactRedactor(repoRoot, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        string summaryPath = Path.Combine(output, "summary.json");
        await File.WriteAllTextAsync(summaryPath, redactor.Redact(JsonSerializer.Serialize(summary, JsonOptions)), CancellationToken.None).ConfigureAwait(false);
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

    private static IReadOnlyList<UiHarnessRoute> SelectScenarioRoutes(
        IReadOnlyList<UiHarnessRoute> selectedManifest,
        UiCertificationScenario scenario)
    {
        if (scenario.RouteKeys.Count == 0)
        {
            return selectedManifest;
        }

        var selected = selectedManifest.ToDictionary(route => route.Key, StringComparer.OrdinalIgnoreCase);
        var routes = new List<UiHarnessRoute>();
        foreach (string key in scenario.RouteKeys)
        {
            if (selected.TryGetValue(key, out UiHarnessRoute? route))
            {
                routes.Add(route);
            }
        }

        return routes;
    }

    private static RouteSmokeEvidence CancelledRoute(UiHarnessRoute route, UiCertificationScenario scenario) =>
        new(
            scenario.Key,
            scenario.Title,
            route.Key,
            HarnessVerdict.Fail,
            ExitCode: 130,
            TimedOut: false,
            NearUniform: true,
            ScreenshotPath: null,
            ResultPath: null,
            Width: 0,
            Height: 0,
            LumaStdDev: 0,
            ElapsedMs: 0,
            Message: "Route smoke probe was cancelled by operator request.",
            scenario.AppearanceMode,
            scenario.ReduceTransparency,
            scenario.DpiScalePercent,
            ExpectedAutomationId: route.ExpectedAutomationId,
            ExpectedAutomationIdFound: false);

    private static SemanticProbeEvidence CancelledSemanticProbe(string message) =>
        new(
            HarnessVerdict.Fail,
            ProcessImageName: null,
            WindowTitle: null,
            IsPasswordField: false,
            IsSecureDesktop: false,
            IsCredentialPrompt: false,
            ScreenshotPath: null,
            Message: message);
}
