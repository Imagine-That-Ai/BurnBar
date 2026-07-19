using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using OpenBurnBar.App.PrivilegedInput;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.ComputerUse.Core.Loop;
using OpenBurnBar.ComputerUse.Windows;

namespace OpenBurnBar.App;

public partial class App
{
    private PrivilegedInputBrokerClient? _privilegedInputClient;
    private PrivilegedInputRunToolExecutor? _privilegedInputRunExecutor;

    private void StartPrivilegedInputBroker()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }
        var client = new PrivilegedInputBrokerClient(ComputerUseTrustedModuleRoots());
        _privilegedInputClient = client;
        _ = Task.Run(() => EnsurePrivilegedInputBrokerAsync(client));
    }

    private async Task EnsurePrivilegedInputBrokerAsync(PrivilegedInputBrokerClient client)
    {
        string executable = Path.Combine(
            AppContext.BaseDirectory,
            "PrivilegedInput",
            "OpenBurnBar.PrivilegedInput.exe");
        if (!File.Exists(executable))
        {
            AppDiagnostics.LogEvent("computer-use.input-unavailable", "packaged executable missing");
            return;
        }

        try
        {
            if (await ProbePrivilegedInputAsync(client).ConfigureAwait(false))
            {
                AppDiagnostics.LogEvent("computer-use.input-ready", "existing");
                return;
            }

            ProcessStartInfo startInfo = ChildProcessLaunchPolicy.CreateStartInfo(
                ChildProcessProfile.PrivilegedInput,
                executable,
                workingDirectory: AppContext.BaseDirectory,
                redirectStandardInput: false,
                redirectStandardOutput: false,
                redirectStandardError: false,
                createNoWindow: true);
            _ = ChildProcessLaunchPolicy.Start(startInfo, ChildProcessProfile.PrivilegedInput);

            for (int attempt = 0; attempt < 30; attempt++)
            {
                if (await ProbePrivilegedInputAsync(client).ConfigureAwait(false))
                {
                    AppDiagnostics.LogEvent("computer-use.input-ready", "started");
                    return;
                }
                await Task.Delay(100).ConfigureAwait(false);
            }

            AppDiagnostics.LogEvent("computer-use.input-unavailable", "authenticated health check failed");
        }
        catch (Exception error)
        {
            AppDiagnostics.LogException("computer-use.input-start", error);
        }
    }

    private PrivilegedInputRunToolExecutor? CreatePrivilegedInputRunToolExecutor()
    {
        if (_privilegedInputClient is null || !_computerUseSafetyMonitorReady)
        {
            return null;
        }
        string localData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar");
        string auditRoot = Environment.GetEnvironmentVariable("OPENBURNBAR_COMPUTER_USE_AUDIT_ROOT")
            ?? Path.Combine(localData, "computer-use-audit");
        string account = Environment.UserDomainName + "\\" + Environment.UserName;
        string userHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(account)))
            .ToLowerInvariant();
        string version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";
        return new PrivilegedInputRunToolExecutor(
            _privilegedInputClient,
            auditRoot,
            "windows-local-" + userHash,
            version);
    }

    private static async Task<bool> ProbePrivilegedInputAsync(PrivilegedInputBrokerClient client)
    {
        try
        {
            PrivilegedInputResponse response = await client.HealthAsync(500).ConfigureAwait(false);
            // A kill-switch denial proves the authenticated broker is alive;
            // it is deliberately not ready to dispatch until the user clears
            // the local panic and a fresh remote lease is present.
            return response.Ok || string.Equals(response.Detail, "kill_switch", StringComparison.Ordinal);
        }
        catch (Exception error) when (error is IOException or InvalidOperationException
            or OperationCanceledException or TimeoutException)
        {
            return false;
        }
    }

    private static string[] ComputerUseTrustedModuleRoots()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        return string.IsNullOrWhiteSpace(windows)
            ? new[] { AppContext.BaseDirectory }
            : new[] { AppContext.BaseDirectory, windows };
    }
}
