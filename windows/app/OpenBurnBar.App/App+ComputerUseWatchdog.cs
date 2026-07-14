using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.App;

public partial class App
{
    private void StartComputerUseWatchdog() => _ = Task.Run(EnsureComputerUseWatchdogAsync);

    private static async Task EnsureComputerUseWatchdogAsync()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string executable = Path.Combine(AppContext.BaseDirectory, "OpenBurnBar.ComputerUse.Watchdog.exe");
        if (!File.Exists(executable))
        {
            AppDiagnostics.LogEvent("computer-use.watchdog-unavailable", "packaged executable missing");
            return;
        }

        try
        {
            byte[] publicKey = ExportWatchdogPublicKey();
            if (await ProbeWatchdogAsync(publicKey, 250).ConfigureAwait(false))
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
                if (await ProbeWatchdogAsync(publicKey, 500).ConfigureAwait(false))
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

    private static async Task<bool> ProbeWatchdogAsync(byte[] publicKey, int timeoutMs)
    {
        try
        {
            var connector = new NamedPipePeerAuthConnector(
                PrivilegedInputWatchdogEndpoint.CurrentPipeName(),
                () => new CngNonceSigner(CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
                    PrivilegedInputWatchdogEndpoint.SharedKeyName)),
                () => new CngNonceVerifier(publicKey),
                new PeerImageValidator(
                    WatchdogTrustedModuleRoots(),
                    PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject));
            await using NamedPipeClientStream pipe = await connector
                .ConnectAndAuthenticateAsync(timeoutMs)
                .ConfigureAwait(false);
            byte[] request = WatchdogCommand.Encode("health");
            await pipe.WriteAsync(request).ConfigureAwait(false);
            await pipe.FlushAsync().ConfigureAwait(false);
            var response = new byte[256];
            int count = await pipe.ReadAsync(response).ConfigureAwait(false);
            return count > 0
                && System.Text.Encoding.UTF8.GetString(response, 0, count)
                    .Contains("\"ok\":true", StringComparison.Ordinal);
        }
        catch (Exception error) when (error is IOException or InvalidOperationException
            or OperationCanceledException or TimeoutException)
        {
            return false;
        }
    }

    private static byte[] ExportWatchdogPublicKey()
    {
        using CngKey key = CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
            PrivilegedInputWatchdogEndpoint.SharedKeyName);
        using var signer = new CngNonceSigner(key);
        return signer.ExportPublicKey();
    }

    private static string[] WatchdogTrustedModuleRoots()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        return string.IsNullOrWhiteSpace(windows)
            ? new[] { AppContext.BaseDirectory }
            : new[] { AppContext.BaseDirectory, windows };
    }
}
