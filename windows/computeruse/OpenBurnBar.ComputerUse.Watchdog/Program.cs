using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.ComputerUse.Watchdog;

internal static class Program
{
    private const int MaximumCommandBytes = 4 * 1024;

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
            Console.Error.WriteLine($"watchdog fatal: {error.GetType().Name}");
            return 1;
        }
    }

    private static async Task RunAsync(CancellationToken cancellationToken)
    {
        string localRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenBurnBar");
        string flagPath = Path.Combine(localRoot, "privileged-input-kill.flag");
        string sid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("Current Windows SID unavailable.");
        byte[] publicKey = ExportSharedPublicKey();
        var policy = new PeerAuthPolicy(
            sid,
            new PeerImageValidator(
                TrustedModuleRoots(),
                PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject),
            () => new CngNonceSigner(CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
                PrivilegedInputWatchdogEndpoint.SharedKeyName)),
            () => new CngNonceVerifier(publicKey));
        var listener = new NamedPipePeerAuthListener(
            PrivilegedInputWatchdogEndpoint.CurrentPipeName(),
            policy);
        var server = new WatchdogServer(new FileKillSwitchFlag(flagPath));

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

            byte[] request = await ReadMessageAsync(pipe, cancellationToken).ConfigureAwait(false);
            byte[] response = server.Handle(request);
            await pipe.WriteAsync(response, cancellationToken).ConfigureAwait(false);
            await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private static byte[] ExportSharedPublicKey()
    {
        using CngKey key = CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
            PrivilegedInputWatchdogEndpoint.SharedKeyName);
        using var signer = new CngNonceSigner(key);
        return signer.ExportPublicKey();
    }

    private static string[] TrustedModuleRoots()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        return string.IsNullOrWhiteSpace(windows)
            ? new[] { AppContext.BaseDirectory }
            : new[] { AppContext.BaseDirectory, windows };
    }

    private static async Task<byte[]> ReadMessageAsync(
        NamedPipeServerStream pipe,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[MaximumCommandBytes];
        int count = await pipe.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
        if (count == 0 || !pipe.IsMessageComplete)
        {
            throw new InvalidDataException("Watchdog command is empty or exceeds the frame limit.");
        }

        return buffer.AsSpan(0, count).ToArray();
    }
}
