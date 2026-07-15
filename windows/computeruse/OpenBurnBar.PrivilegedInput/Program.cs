using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Loop;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.ComputerUse.Windows;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.PrivilegedInput;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            return 2;
        }

        if (args.Length == 1
            && string.Equals(args[0], "--verify-self-publisher", StringComparison.Ordinal))
        {
            string? executable = Environment.ProcessPath;
            return executable is not null
                && PeerImageValidator.HasPublisherSubject(
                    executable,
                    PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject)
                ? 0
                : 3;
        }

        if (args.Length != 0)
        {
            return 2;
        }

        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };

        try
        {
            await RunAsync(cancellation.Token).ConfigureAwait(false);
            return 0;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"privileged-input fatal: {error.GetType().Name}");
            return 1;
        }
    }

    private static async Task RunAsync(CancellationToken cancellationToken)
    {
        string localRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar");
        var killFlag = new FileKillSwitchFlag(Path.Combine(localRoot, "privileged-input-kill.flag"));
        var executor = new PrivilegedInputExecutionService(
            new UiaInspector(),
            new SendInputInputSynthesizer(() => killFlag.IsActive),
            killFlag,
            new FilePrivilegedInputReceiptStore(Path.Combine(
                localRoot,
                "privileged-input-receipts.json")));
        var watchdog = new PrivilegedInputWatchdogClient(TrustedModuleRoots());
        NamedPipePeerAuthListener listener = CreateListener();

        while (!cancellationToken.IsCancellationRequested)
        {
            await using NamedPipeServerStream pipe = listener.CreateHardenedServerPipe();
            await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
            PeerAuthResult auth = await listener
                .AuthenticateConnectedPeerAsync(pipe, cancellationToken)
                .ConfigureAwait(false);
            if (!auth.Accepted)
            {
                continue;
            }

            byte[] payload = await ReadMessageAsync(pipe, cancellationToken).ConfigureAwait(false);
            PrivilegedInputCommand command = PrivilegedInputCommand.Parse(payload);
            PrivilegedInputResponse response;
            if (command.Kind == PrivilegedInputCommandKind.Health)
            {
                response = await WatchdogHealthAsync(watchdog, cancellationToken).ConfigureAwait(false);
            }
            else if (command.Kind == PrivilegedInputCommandKind.Dispatch)
            {
                PrivilegedInputResponse watchdogHealth = await WatchdogHealthAsync(watchdog, cancellationToken)
                    .ConfigureAwait(false);
                response = watchdogHealth.Ok ? executor.Execute(command) : watchdogHealth;
            }
            else
            {
                response = new PrivilegedInputResponse(false, command.Error ?? "invalid_command");
            }

            byte[] encoded = response.Encode();
            await pipe.WriteAsync(encoded, cancellationToken).ConfigureAwait(false);
            await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private static NamedPipePeerAuthListener CreateListener()
    {
        string sid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("Current Windows SID unavailable.");
        byte[] publicKey = ExportPublicKey(PrivilegedInputBrokerEndpoint.SharedKeyName);
        var policy = new PeerAuthPolicy(
            sid,
            new PeerImageValidator(
                TrustedModuleRoots(),
                PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject,
                new[] { "OpenBurnBar.App.exe" }),
            () => new CngNonceSigner(CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
                PrivilegedInputBrokerEndpoint.SharedKeyName)),
            () => new CngNonceVerifier(publicKey));
        return new NamedPipePeerAuthListener(PrivilegedInputBrokerEndpoint.CurrentPipeName(), policy);
    }

    private static async Task<PrivilegedInputResponse> WatchdogHealthAsync(
        PrivilegedInputWatchdogClient watchdog,
        CancellationToken cancellationToken)
    {
        try
        {
            WatchdogResponse response = await watchdog.HealthAsync(500, cancellationToken)
                .ConfigureAwait(false);
            if (!response.Ok)
            {
                return new PrivilegedInputResponse(false, "watchdog_unavailable");
            }
            return response.Detail == "active"
                ? new PrivilegedInputResponse(false, "kill_switch")
                : new PrivilegedInputResponse(true, "ready");
        }
        catch (Exception error) when (error is IOException or InvalidOperationException
            or OperationCanceledException or TimeoutException or CryptographicException)
        {
            return new PrivilegedInputResponse(false, "watchdog_unavailable");
        }
    }

    private static byte[] ExportPublicKey(string keyName)
    {
        using CngKey key = CngNonceKeyProvisioning.OpenOrCreatePersistedKey(keyName);
        using var signer = new CngNonceSigner(key);
        return signer.ExportPublicKey();
    }

    private static string[] TrustedModuleRoots()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string installRoot = Directory.GetParent(
            AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar))?.FullName
            ?? AppContext.BaseDirectory;
        return string.IsNullOrWhiteSpace(windows)
            ? new[] { installRoot }
            : new[] { installRoot, windows };
    }

    private static async Task<byte[]> ReadMessageAsync(
        NamedPipeServerStream pipe,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[PrivilegedInputCommand.MaximumPayloadBytes];
        int count = await pipe.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
        if (count == 0 || !pipe.IsMessageComplete)
        {
            throw new InvalidDataException("Privileged-input request is empty or exceeds the frame limit.");
        }
        return buffer.AsSpan(0, count).ToArray();
    }
}
