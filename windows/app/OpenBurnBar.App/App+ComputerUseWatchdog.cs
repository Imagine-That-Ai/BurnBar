using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.ComputerUse.Windows;

namespace OpenBurnBar.App;

public partial class App
{
    private PrivilegedInputWatchdogClient? _computerUseWatchdogClient;

    private void StartComputerUseWatchdog()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }
        var client = new PrivilegedInputWatchdogClient(WatchdogTrustedModuleRoots());
        _computerUseWatchdogClient = client;
        _ = Task.Run(() => EnsureComputerUseWatchdogAsync(client));
    }

    private static async Task EnsureComputerUseWatchdogAsync(PrivilegedInputWatchdogClient client)
    {
        string executable = Path.Combine(
            AppContext.BaseDirectory,
            "ComputerUseWatchdog",
            "OpenBurnBar.ComputerUse.Watchdog.exe");
        if (!File.Exists(executable))
        {
            AppDiagnostics.LogEvent("computer-use.watchdog-unavailable", "packaged executable missing");
            return;
        }

        try
        {
            if (await ProbeWatchdogAsync(client, 250).ConfigureAwait(false))
            {
                AppDiagnostics.LogEvent("computer-use.watchdog-ready", "existing");
                return;
            }

            ProcessStartInfo startInfo = ChildProcessLaunchPolicy.CreateStartInfo(
                ChildProcessProfile.Watchdog,
                executable,
                workingDirectory: AppContext.BaseDirectory,
                redirectStandardInput: false,
                redirectStandardOutput: false,
                redirectStandardError: false,
                createNoWindow: true);
            _ = ChildProcessLaunchPolicy.Start(startInfo, ChildProcessProfile.Watchdog);

            for (int attempt = 0; attempt < 20; attempt++)
            {
                if (await ProbeWatchdogAsync(client, 500).ConfigureAwait(false))
                {
                    AppDiagnostics.LogEvent("computer-use.watchdog-ready", "started");
                    return;
                }
                await Task.Delay(100).ConfigureAwait(false);
            }

            AppDiagnostics.LogEvent("computer-use.watchdog-unavailable", "authenticated health check failed");
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("computer-use.watchdog-start", error);
        }
    }

    internal async Task ActivateComputerUsePanicAsync(string reason, ComputerUsePanicSource source)
    {
        bool halted = false;
        try
        {
            ActivateDurableKillFlag(reason);
            halted = true;
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("computer-use.kill-flag-activate", error);
        }

        try
        {
            PrivilegedInputWatchdogClient client = _computerUseWatchdogClient
                ?? throw new InvalidOperationException("The Computer Use watchdog is unavailable.");
            WatchdogResponse response = await client.ActivateAsync(reason).ConfigureAwait(false);
            if (!response.Ok)
            {
                throw new InvalidOperationException("The Computer Use watchdog rejected the halt request.");
            }
            halted = true;
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("computer-use.watchdog-activate", error);
        }
        try
        {
            if (_privilegedInputRunExecutor is not null)
            {
                await _privilegedInputRunExecutor.RecordPanicAsync(source).ConfigureAwait(false);
            }
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("computer-use.panic-audit", error);
        }
        AppDiagnostics.LogEvent("computer-use.panic", source.ToWire());
        if (!halted)
        {
            throw new InvalidOperationException("Every Computer Use halt path failed closed.");
        }
    }

    private async void OnComputerUsePanic(ComputerUsePanicSource source)
    {
        try
        {
            await ActivateComputerUsePanicAsync(source.ToWire(), source);
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("computer-use.panic", error);
        }
    }

    internal async Task ClearComputerUsePanicAsync()
    {
        if (!_computerUseSafetyMonitorReady)
        {
            throw new InvalidOperationException("The Computer Use safety monitor is unavailable.");
        }
        PrivilegedInputWatchdogClient client = _computerUseWatchdogClient
            ?? throw new InvalidOperationException("The Computer Use watchdog is unavailable.");
        WatchdogResponse response = await client.ClearAsync().ConfigureAwait(false);
        if (!response.Ok)
        {
            throw new InvalidOperationException("The Computer Use watchdog rejected the clear request.");
        }
        try
        {
            PrivilegedInputBrokerClient broker = _privilegedInputClient
                ?? throw new InvalidOperationException("The privileged-input broker is unavailable.");
            PrivilegedInputResponse brokerHealth = await broker.HealthAsync().ConfigureAwait(false);
            if (!brokerHealth.Ok)
            {
                throw new InvalidOperationException("The privileged-input broker is not ready.");
            }
            AppDiagnostics.LogEvent("computer-use.panic-cleared", "user_start");
        }
        catch (Exception error)
        {
            try
            {
                WatchdogResponse rearmed = await client.ActivateAsync("start_failed").ConfigureAwait(false);
                if (!rearmed.Ok) ActivateDurableKillFlag("start_failed");
            }
            catch (Exception rearmError)
            {
                ActivateDurableKillFlag("start_failed");
                AppDiagnostics.LogException("computer-use.watchdog-rearm", rearmError);
            }
            throw new InvalidOperationException("Computer Use could not start safely.", error);
        }
    }

    private static void ActivateDurableKillFlag(string reason)
    {
        string localRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar");
        new FileKillSwitchFlag(Path.Combine(localRoot, "privileged-input-kill.flag"))
            .Activate(reason);
    }

    private static async Task<bool> ProbeWatchdogAsync(
        PrivilegedInputWatchdogClient client,
        int timeoutMs)
    {
        try
        {
            WatchdogResponse response = await client.HealthAsync(timeoutMs).ConfigureAwait(false);
            return response.Ok;
        }
        catch (Exception error) when (error is IOException or InvalidOperationException
            or OperationCanceledException or TimeoutException)
        {
            return false;
        }
    }

    private static string[] WatchdogTrustedModuleRoots()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        return string.IsNullOrWhiteSpace(windows)
            ? new[] { AppContext.BaseDirectory }
            : new[] { AppContext.BaseDirectory, windows };
    }
}
