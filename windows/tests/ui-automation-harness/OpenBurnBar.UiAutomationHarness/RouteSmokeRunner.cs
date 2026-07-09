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

    public async Task<RouteSmokeEvidence> RunAsync(UiHarnessRoute route, CancellationToken cancellationToken)
    {
        string routeOut = Path.Combine(_outputDirectory, "routes", route.Key);
        string profileRoot = Path.Combine(_outputDirectory, "profiles", route.Key);
        string launchOut = Path.Combine(_outputDirectory, "launches", route.Key);
        Directory.CreateDirectory(routeOut);
        Directory.CreateDirectory(profileRoot);
        Directory.CreateDirectory(launchOut);

        using var process = new Process();
        process.StartInfo = CreateStartInfo(route, routeOut, profileRoot, launchOut);
        var stopwatch = Stopwatch.StartNew();
        if (!process.Start())
        {
            return Failed(route.Key, exitCode: 127, timedOut: false, "Failed to start OpenBurnBar.App.exe.", stopwatch.Elapsed);
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
                ExpectedAutomationId: route.ExpectedAutomationId,
                ExpectedAutomationIdFound: false);
        }

        if (!File.Exists(resultPath))
        {
            return Failed(
                route.Key,
                process.ExitCode,
                timedOut: false,
                $"Route smoke result JSON was not written: {resultPath}",
                stopwatch.Elapsed);
        }

        return ParseResult(route.Key, process.ExitCode, resultPath, stopwatch.Elapsed);
    }

    private ProcessStartInfo CreateStartInfo(UiHarnessRoute route, string routeOut, string profileRoot, string launchOut)
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
        return startInfo;
    }

    private static RouteSmokeEvidence ParseResult(string routeKey, int processExitCode, string resultPath, TimeSpan elapsed)
    {
        using JsonDocument json = JsonDocument.Parse(File.ReadAllText(resultPath));
        JsonElement root = json.RootElement;
        bool nearUniform = ReadBool(root, "NearUniform", defaultValue: true);
        string? screenshotPath = ReadString(root, "ScreenshotPath");
        string? message = ReadString(root, "Message");
        string expectedAutomationId = ReadString(root, "ExpectedAutomationId") ?? UiHarnessRouteDefaults.ExpectedAutomationId(routeKey);
        bool expectedAutomationIdFound = ReadBool(root, "ExpectedAutomationIdFound", defaultValue: false);
        double width = ReadDouble(root, "Width");
        double height = ReadDouble(root, "Height");
        double lumaStdDev = ReadDouble(root, "LumaStdDev");
        double elapsedMs = ReadDouble(root, "ElapsedMs");
        var verdict = processExitCode == 0 && !nearUniform && expectedAutomationIdFound ? HarnessVerdict.Pass : HarnessVerdict.Fail;
        if (!expectedAutomationIdFound)
        {
            message = AppendMessage(message, $"Expected automation id was not found: {expectedAutomationId}");
        }

        return new RouteSmokeEvidence(
            routeKey,
            verdict,
            processExitCode,
            TimedOut: false,
            nearUniform,
            screenshotPath,
            resultPath,
            width,
            height,
            lumaStdDev,
            elapsedMs <= 0 ? elapsed.TotalMilliseconds : elapsedMs,
            message,
            expectedAutomationId,
            expectedAutomationIdFound);
    }

    private static RouteSmokeEvidence Failed(string routeKey, int exitCode, bool timedOut, string message, TimeSpan elapsed) =>
        new(
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
            ExpectedAutomationId: UiHarnessRouteDefaults.ExpectedAutomationId(routeKey),
            ExpectedAutomationIdFound: false);

    private static string? ReadString(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool ReadBool(JsonElement root, string property, bool defaultValue) =>
        root.TryGetProperty(property, out JsonElement value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : defaultValue;

    private static double ReadDouble(JsonElement root, string property) =>
        root.TryGetProperty(property, out JsonElement value) && value.TryGetDouble(out double parsed) ? parsed : 0;

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
