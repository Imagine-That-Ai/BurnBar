using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Loop;
using OpenBurnBar.Pal.Ipc.Windows;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>Authenticated client for the isolated first-party input broker.</summary>
public sealed class PrivilegedInputBrokerClient : IPrivilegedInputDispatcher
{
    private readonly string[] _trustedModuleRoots;

    public PrivilegedInputBrokerClient(params string[] trustedModuleRoots)
    {
        _trustedModuleRoots = trustedModuleRoots is { Length: > 0 }
            ? trustedModuleRoots
            : throw new ArgumentException("At least one trusted module root is required.", nameof(trustedModuleRoots));
    }

    public async Task<PrivilegedInputResponse> HealthAsync(
        int timeoutMilliseconds = 1_000,
        CancellationToken cancellationToken = default) =>
        await SendAsync(
            PrivilegedInputCommand.EncodeHealth(),
            timeoutMilliseconds,
            cancellationToken).ConfigureAwait(false);

    public async Task<PrivilegedInputResponse> DispatchAsync(
        string sessionId,
        string approvalId,
        string actionId,
        MacInputAction action,
        int timeoutMilliseconds = 5_000,
        CancellationToken cancellationToken = default) =>
        await SendAsync(
            PrivilegedInputCommand.EncodeDispatch(sessionId, approvalId, actionId, action),
            timeoutMilliseconds,
            cancellationToken).ConfigureAwait(false);

    private async Task<PrivilegedInputResponse> SendAsync(
        byte[] request,
        int timeoutMilliseconds,
        CancellationToken cancellationToken)
    {
        byte[] publicKey = ExportPublicKey();
        var connector = new NamedPipePeerAuthConnector(
            PrivilegedInputBrokerEndpoint.CurrentPipeName(),
            () => new CngNonceSigner(CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
                PrivilegedInputBrokerEndpoint.SharedKeyName)),
            () => new CngNonceVerifier(publicKey),
            new PeerImageValidator(
                _trustedModuleRoots,
                PrivilegedInputWatchdogEndpoint.ExpectedPublisherSubject,
                new[] { "OpenBurnBar.PrivilegedInput.exe" }));
        await using NamedPipeClientStream pipe = await connector
            .ConnectAndAuthenticateAsync(timeoutMilliseconds, cancellationToken)
            .ConfigureAwait(false);
        await pipe.WriteAsync(request, cancellationToken).ConfigureAwait(false);
        await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);

        var response = new byte[512];
        int count = await pipe.ReadAsync(response, cancellationToken).ConfigureAwait(false);
        if (count == 0 || !pipe.IsMessageComplete)
        {
            throw new InvalidDataException("The privileged-input broker response is empty or oversized.");
        }
        return PrivilegedInputResponse.Parse(response.AsSpan(0, count));
    }

    private static byte[] ExportPublicKey()
    {
        using CngKey key = CngNonceKeyProvisioning.OpenOrCreatePersistedKey(
            PrivilegedInputBrokerEndpoint.SharedKeyName);
        using var signer = new CngNonceSigner(key);
        return signer.ExportPublicKey();
    }
}
