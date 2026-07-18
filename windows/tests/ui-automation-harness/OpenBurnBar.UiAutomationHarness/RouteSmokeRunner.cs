using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.UiAutomationHarness.Core;

namespace OpenBurnBar.UiAutomationHarness;

internal sealed class RouteSmokeRunner
{
    private readonly string _appExe;
    private readonly string _outputDirectory;
    private readonly int _timeoutMilliseconds;

    public RouteSmokeRunner(string appExe, string outputDirectory, int timeoutMilliseconds)
    {
        _appExe = appExe;
        _outputDirectory = outputDirectory;
        _timeoutMilliseconds = timeoutMilliseconds;
    }

    public async Task<RouteSmokeEvidence> RunAsync(
        UiHarnessRoute route,
        UiCertificationScenario scenario,
        CancellationToken cancellationToken)
    {
        string routeOut = Path.Combine(_outputDirectory, "routes", scenario.Key, route.Key);
        string profileRoot = Path.Combine(_outputDirectory, "profiles", $"{scenario.Key}-{route.Key}");
        string launchOut = Path.Combine(_outputDirectory, "launches", scenario.Key, route.Key);
        Directory.CreateDirectory(routeOut);
        Directory.CreateDirectory(profileRoot);
        Directory.CreateDirectory(launchOut);

        using var process = new Process();
        process.StartInfo = CreateStartInfo(route, scenario, routeOut, profileRoot, launchOut);
        var stopwatch = Stopwatch.StartNew();
        if (!process.Start())
        {
            return Failed(route.Key, scenario, exitCode: 127, timedOut: false, "Failed to start OpenBurnBar.App.exe.", stopwatch.Elapsed);
        }

        bool timedOut = false;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_timeoutMilliseconds + 5_000);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            timedOut = true;
            TryKill(process);
        }
        finally
        {
            TryKill(process);
        }

        stopwatch.Stop();
        string resultPath = Path.Combine(routeOut, $"{route.Key}-result.json");
        if (timedOut)
        {
            return new RouteSmokeEvidence(
                scenario.Key,
                scenario.Title,
                route.Key,
                HarnessVerdict.Fail,
                124,
                TimedOut: true,
                NearUniform: true,
                ScreenshotPath: null,
                ResultPath: File.Exists(resultPath) ? resultPath : null,
                Width: 0,
                Height: 0,
                LumaStdDev: 0,
                ElapsedMs: stopwatch.Elapsed.TotalMilliseconds,
                Message: $"Timed out after {_timeoutMilliseconds + 5_000}ms.",
                scenario.AppearanceMode,
                scenario.ReduceTransparency,
                scenario.DpiScalePercent,
                ExpectedAutomationId: route.ExpectedAutomationId,
                ExpectedAutomationIdFound: false);
        }

        if (!File.Exists(resultPath))
        {
            return Failed(
                route.Key,
                scenario,
                process.ExitCode,
                timedOut: false,
                $"Route smoke result JSON was not written: {resultPath}",
                stopwatch.Elapsed);
        }

        try
        {
            return ParseResult(route.Key, scenario, process.ExitCode, resultPath, stopwatch.Elapsed);
        }
        catch (JsonException ex)
        {
            return Failed(route.Key, scenario, process.ExitCode, timedOut: false, $"Route smoke result JSON was invalid: {ex.Message}", stopwatch.Elapsed);
        }
        catch (IOException ex)
        {
            return Failed(route.Key, scenario, process.ExitCode, timedOut: false, $"Route smoke result JSON could not be read: {ex.Message}", stopwatch.Elapsed);
        }
        catch (UnauthorizedAccessException ex)
        {
            return Failed(route.Key, scenario, process.ExitCode, timedOut: false, $"Route smoke result JSON could not be accessed: {ex.Message}", stopwatch.Elapsed);
        }
    }

    private ProcessStartInfo CreateStartInfo(
        UiHarnessRoute route,
        UiCertificationScenario scenario,
        string routeOut,
        string profileRoot,
        string launchOut)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = _appExe,
            WorkingDirectory = Path.GetDirectoryName(_appExe) ?? Environment.CurrentDirectory,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Normal,
        };
        ProcessEnvironmentSanitizer.RemoveOpenBurnBarEnvironment(startInfo);
        startInfo.Environment["DOTNET_ROLL_FORWARD"] = Environment.GetEnvironmentVariable("DOTNET_ROLL_FORWARD") ?? "Major";
        startInfo.Environment["OPENBURNBAR_SAMPLE_MODE"] = "1";
        startInfo.Environment["OPENBURNBAR_DISABLE_QUOTA_ACQUISITION"] = "1";
        // The dashboard backdrop is an airspace-free CanvasImageSource in the XAML
        // tree, so route smoke intentionally runs with native rendering enabled.
        // This would have caught the WebView2/CanvasControl cover-up in v1.0.37.
        startInfo.Environment["OPENBURNBAR_AUTOMATION_PROFILE_ROOT"] = profileRoot;
        startInfo.ArgumentList.Add("--route-smoke");
        startInfo.ArgumentList.Add(route.Key);
        startInfo.ArgumentList.Add("--route-smoke-out");
        startInfo.ArgumentList.Add(routeOut);
        startInfo.ArgumentList.Add("--route-smoke-timeout-ms");
        startInfo.ArgumentList.Add(_timeoutMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture));
        startInfo.ArgumentList.Add("--automation-profile");
        startInfo.ArgumentList.Add(profileRoot);
        startInfo.ArgumentList.Add("--automation-out");
        startInfo.ArgumentList.Add(launchOut);
        if (!string.IsNullOrWhiteSpace(scenario.AppearanceMode))
        {
            startInfo.ArgumentList.Add("--automation-appearance");
            startInfo.ArgumentList.Add(scenario.AppearanceMode);
        }

        if (scenario.ReduceTransparency is bool reduceTransparency)
        {
            startInfo.ArgumentList.Add("--automation-reduce-transparency");
            startInfo.ArgumentList.Add(reduceTransparency ? "true" : "false");
        }

        if (scenario.WindowWidth is int windowWidth)
        {
            startInfo.ArgumentList.Add("--route-smoke-window-width");
            startInfo.ArgumentList.Add(windowWidth.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }

        if (scenario.WindowHeight is int windowHeight)
        {
            startInfo.ArgumentList.Add("--route-smoke-window-height");
            startInfo.ArgumentList.Add(windowHeight.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }

        return startInfo;
    }

    private static RouteSmokeEvidence ParseResult(
        string routeKey,
        UiCertificationScenario scenario,
        int processExitCode,
        string resultPath,
        TimeSpan elapsed)
    {
        using JsonDocument json = JsonDocument.Parse(File.ReadAllText(resultPath));
        JsonElement root = json.RootElement;
        bool nearUniform = ReadBool(root, "NearUniform", defaultValue: true);
        int reportedExitCode = ReadInt(root, "ExitCode", defaultValue: 1);
        string? screenshotPath = ReadString(root, "ScreenshotPath");
        string? message = ReadString(root, "Message");
        string expectedAutomationId = ReadString(root, "ExpectedAutomationId") ?? UiHarnessRouteDefaults.ExpectedAutomationId(routeKey);
        bool expectedAutomationIdFound = ReadBool(root, "ExpectedAutomationIdFound", defaultValue: false);
        double width = ReadDouble(root, "Width");
        double height = ReadDouble(root, "Height");
        double lumaStdDev = ReadDouble(root, "LumaStdDev");
        double elapsedMs = ReadDouble(root, "ElapsedMs");
        int actualDpiScalePercent = ReadInt(root, "ActualDpiScalePercent", defaultValue: 0);
        bool dpiScaleMatches = scenario.DpiScalePercent is null ||
            (actualDpiScalePercent > 0 && Math.Abs(actualDpiScalePercent - scenario.DpiScalePercent.Value) <= 1);
        int effectiveExitCode = processExitCode == 0 ? reportedExitCode : processExitCode;
        var verdict = effectiveExitCode == 0 && !nearUniform && expectedAutomationIdFound && dpiScaleMatches
            ? HarnessVerdict.Pass
            : HarnessVerdict.Fail;
        if (processExitCode != 0)
        {
            message = AppendMessage(message, $"OpenBurnBar process exited abnormally with code {processExitCode}.");
        }
        if (!expectedAutomationIdFound)
        {
            message = AppendMessage(message, $"Expected automation id was not found: {expectedAutomationId}");
        }
        if (!dpiScaleMatches)
        {
            message = AppendMessage(message, $"Expected {scenario.DpiScalePercent}% DPI but measured {actualDpiScalePercent}%.");
        }

        return new RouteSmokeEvidence(
            scenario.Key,
            scenario.Title,
            routeKey,
            verdict,
            effectiveExitCode,
            TimedOut: false,
            nearUniform,
            screenshotPath,
            resultPath,
            width,
            height,
            lumaStdDev,
            elapsedMs <= 0 ? elapsed.TotalMilliseconds : elapsedMs,
            message,
            scenario.AppearanceMode,
            scenario.ReduceTransparency,
            scenario.DpiScalePercent,
            expectedAutomationId,
            expectedAutomationIdFound)
        {
            ActualDpiScalePercent = actualDpiScalePercent > 0 ? actualDpiScalePercent : null,
            DpiScaleMatches = dpiScaleMatches,
        };
    }

    private static RouteSmokeEvidence Failed(
        string routeKey,
        UiCertificationScenario scenario,
        int exitCode,
        bool timedOut,
        string message,
        TimeSpan elapsed) =>
        new(
            scenario.Key,
            scenario.Title,
            routeKey,
            HarnessVerdict.Fail,
            exitCode,
            timedOut,
            NearUniform: true,
            ScreenshotPath: null,
            ResultPath: null,
            Width: 0,
            Height: 0,
            LumaStdDev: 0,
            ElapsedMs: elapsed.TotalMilliseconds,
            Message: message,
            scenario.AppearanceMode,
            scenario.ReduceTransparency,
            scenario.DpiScalePercent,
            ExpectedAutomationId: UiHarnessRouteDefaults.ExpectedAutomationId(routeKey),
            ExpectedAutomationIdFound: false);

    private static string? ReadString(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool ReadBool(JsonElement root, string property, bool defaultValue) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : defaultValue;

    private static double ReadDouble(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.TryGetDouble(out double parsed) ? parsed : 0;

    private static int ReadInt(JsonElement root, string property, int defaultValue) =>
        root.TryGetProperty(property, out JsonElement value) && value.TryGetInt32(out int parsed) ? parsed : defaultValue;

    private static string AppendMessage(string? current, string addition) =>
        string.IsNullOrWhiteSpace(current) ? addition : $"{current} {addition}";

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
    }
}
