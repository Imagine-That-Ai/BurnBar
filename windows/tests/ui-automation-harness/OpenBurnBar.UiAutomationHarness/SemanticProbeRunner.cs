using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Windows;
using OpenBurnBar.UiAutomationHarness.Core;

namespace OpenBurnBar.UiAutomationHarness;

[SupportedOSPlatform("windows10.0.19041.0")]
internal sealed class SemanticProbeRunner
{
    private readonly string _appExe;
    private readonly string _outputDirectory;
    private readonly int _timeoutMilliseconds;

    public SemanticProbeRunner(string appExe, string outputDirectory, int timeoutMilliseconds)
    {
        _appExe = appExe;
        _outputDirectory = outputDirectory;
        _timeoutMilliseconds = timeoutMilliseconds;
    }

    public async Task<SemanticProbeEvidence> RunAsync(CancellationToken cancellationToken)
    {
        string profileRoot = Path.Combine(_outputDirectory, "profiles", "semantic-main-window");
        string launchOut = Path.Combine(_outputDirectory, "launches", "semantic-main-window");
        Directory.CreateDirectory(profileRoot);
        Directory.CreateDirectory(launchOut);

        using var process = new Process();
        process.StartInfo = CreateStartInfo(profileRoot, launchOut);
        if (!process.Start())
        {
            return Fail("Failed to start OpenBurnBar.App.exe for semantic probe.");
        }

        try
        {
            IntPtr hwnd = await WaitForMainWindowAsync(process, cancellationToken).ConfigureAwait(false);
            ShowWindow(hwnd, 9);
            SetForegroundWindow(hwnd);
            await Task.Delay(650, cancellationToken).ConfigureAwait(false);

            string screenshotPath = Path.Combine(_outputDirectory, "semantic", "main-window.png");
            WindowBitmapCapture.Capture(hwnd, screenshotPath);

            UiElementInfo info = new UiaInspector().InspectWindow(hwnd);
            bool expectedProcess = string.Equals(info.ProcessImageName, "OpenBurnBar.App.exe", StringComparison.OrdinalIgnoreCase)
                || string.Equals(info.ProcessImageName, "OpenBurnBar.App", StringComparison.OrdinalIgnoreCase);
            bool denied = info.IsPasswordField || info.IsSecureDesktop || info.IsCredentialPrompt;
            var verdict = expectedProcess && !denied ? HarnessVerdict.Pass : HarnessVerdict.Fail;
            string? message = verdict == HarnessVerdict.Pass
                ? "OpenBurnBar main window is inspectable and not classified as a deny region."
                : $"Unexpected OpenBurnBar window probe result. process={info.ProcessImageName ?? "<null>"} denied={denied}";
            return new SemanticProbeEvidence(
                verdict,
                info.ProcessImageName,
                info.WindowTitle,
                info.IsPasswordField,
                info.IsSecureDesktop,
                info.IsCredentialPrompt,
                screenshotPath,
                message);
        }
        catch (Exception ex) when (ex is InvalidOperationException or TimeoutException or Win32Exception or COMException)
        {
            return Fail(ex.Message);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return Fail($"OpenBurnBar.App did not expose a main window within {_timeoutMilliseconds}ms.");
        }
        finally
        {
            TryKill(process);
        }
    }

    private ProcessStartInfo CreateStartInfo(string profileRoot, string launchOut)
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
        startInfo.ArgumentList.Add("--automation-main-window");
        startInfo.ArgumentList.Add("--automation-profile");
        startInfo.ArgumentList.Add(profileRoot);
        startInfo.ArgumentList.Add("--automation-out");
        startInfo.ArgumentList.Add(launchOut);
        return startInfo;
    }

    private async Task<IntPtr> WaitForMainWindowAsync(Process process, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeoutMilliseconds);
        while (!timeout.IsCancellationRequested)
        {
            process.Refresh();
            if (process.HasExited)
            {
                throw new InvalidOperationException($"OpenBurnBar.App exited before creating a main window. Exit code: {process.ExitCode}");
            }

            if (process.MainWindowHandle != IntPtr.Zero)
            {
                return process.MainWindowHandle;
            }

            await Task.Delay(250, timeout.Token).ConfigureAwait(false);
        }

        throw new TimeoutException($"OpenBurnBar.App did not expose a main window within {_timeoutMilliseconds}ms.");
    }

    private static SemanticProbeEvidence Fail(string message) =>
        new(
            HarnessVerdict.Fail,
            ProcessImageName: null,
            WindowTitle: null,
            IsPasswordField: false,
            IsSecureDesktop: false,
            IsCredentialPrompt: false,
            ScreenshotPath: null,
            Message: message);

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
        catch (Win32Exception)
        {
        }
    }

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);
}
