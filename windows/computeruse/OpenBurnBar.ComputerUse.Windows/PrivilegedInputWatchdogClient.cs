using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>Authenticated client for the independent kill-switch watchdog.</summary>
public sealed class PrivilegedInputWatchdogClient
{
    private readonly string[] _trustedModuleRoots;

    public PrivilegedInputWatchdogClient(params string[] trustedModuleRoots)
    {
        _trustedModuleRoots = trustedModuleRoots is { Length: > 0 }
            ? trustedModuleRoots
            : throw new ArgumentException("At least one trusted module root is required.", nameof(trustedModuleRoots));
    }

    public Task<WatchdogResponse> HealthAsync(
        int timeoutMilliseconds = 1_000,
        CancellationToken cancellationToken = default) =>
        SendAsync("health", null, timeoutMilliseconds, cancellationToken);

    public Task<WatchdogResponse> ActivateAsync(
        string reason,
        int timeoutMilliseconds = 1_000,
        CancellationToken cancellationToken = default) =>
        SendAsync("activate", reason, timeoutMilliseconds, cancellationToken);

    public Task<WatchdogResponse> ClearAsync(
        int timeoutMilliseconds = 1_000,
        CancellationToken cancellationToken = default) =>
        SendAsync("clear", null, timeoutMilliseconds, cancellationToken);

    private async Task<WatchdogResponse> SendAsync(
        string action,
        string? reason,
        int timeoutMilliseconds,
        CancellationToken cancellationToken)
    {
        byte[] publicKey = ExportPublicKey();
        var connector = new NamedPipePeerAuthConnector(
            PrivilegedInputWatchdogEndpoint.CurrentPipeName(),
            () => new CngNonceSigner(CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
                PrivilegedInputWatchdogEndpoint.SharedKeyName)),
            () => new CngNonceVerifier(publicKey),
            new PeerImageValidator(
                _trustedModuleRoots,
                PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject,
                new[] { "OpenBurnBar.ComputerUse.Watchdog.exe" }));
        await using NamedPipeClientStream pipe = await connector
            .ConnectAndAuthenticateAsync(timeoutMilliseconds, cancellationToken)
            .ConfigureAwait(false);
        byte[] request = WatchdogCommand.Encode(action, reason);
        await pipe.WriteAsync(request, cancellationToken).ConfigureAwait(false);
        await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
        var response = new byte[512];
        int count = await pipe.ReadAsync(response, cancellationToken).ConfigureAwait(false);
        if (count == 0 || !pipe.IsMessageComplete)
        {
            throw new InvalidDataException("The watchdog response is empty or oversized.");
        }
        WatchdogResponse parsed = WatchdogResponse.Parse(response.AsSpan(0, count));
        if (parsed.Detail == "invalid_response")
        {
            throw new InvalidDataException("The watchdog response is invalid.");
        }
        return parsed;
    }

    private static byte[] ExportPublicKey()
    {
        using CngKey key = CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
            PrivilegedInputWatchdogEndpoint.SharedKeyName);
        using var signer = new CngNonceSigner(key);
        return signer.ExportPublicKey();
    }
}
