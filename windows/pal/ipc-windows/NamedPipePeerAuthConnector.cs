// Client half of the named-pipe peer-auth handshake (the app side).
//
// Connects to the daemon's hardened pipe and runs the mirror of the listener's
// mutual handshake: answer the daemon's challenge, then challenge the daemon and
// verify its answer. This is the app's proof that it is talking to the genuine
// daemon (pinned daemon key) and the daemon's proof that it is talking to the
// genuine app (pinned app key) — mutual, per R16.
//
// Scaffold for VAL-P0-CONPTY-018 (compiles on macOS). The live connect +
// handshake against a running daemon is VAL-P0-CONPTY-019.

using System;
using System.IO.Pipes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Pal.Ipc;
using OpenBurnBar.Pal.Ipc.Windows.Interop;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>
/// Opens the daemon pipe and completes the client side of the mutual handshake.
/// </summary>
public sealed class NamedPipePeerAuthConnector
{
    private readonly string _pipeName;
    private readonly Func<INonceSigner> _selfSignerFactory;
    private readonly Func<INonceVerifier> _peerVerifierFactory;
    private readonly PeerImageValidator? _serverImageValidator;

    /// <param name="pipeName">The daemon pipe name (without the <c>\\.\pipe\</c> prefix).</param>
    /// <param name="selfSignerFactory">This side's transcript signer (CNG in production).</param>
    /// <param name="peerVerifierFactory">Verifier for the daemon's pinned key.</param>
    public NamedPipePeerAuthConnector(
        string pipeName,
        Func<INonceSigner> selfSignerFactory,
        Func<INonceVerifier> peerVerifierFactory,
        PeerImageValidator? serverImageValidator = null)
    {
        _pipeName = pipeName ?? throw new ArgumentNullException(nameof(pipeName));
        _selfSignerFactory = selfSignerFactory ?? throw new ArgumentNullException(nameof(selfSignerFactory));
        _peerVerifierFactory = peerVerifierFactory ?? throw new ArgumentNullException(nameof(peerVerifierFactory));
        _serverImageValidator = serverImageValidator;
    }

    /// <summary>
    /// Connects, runs the mutual handshake as the Initiator, and returns the
    /// still-open, now-authenticated pipe on success. Disposes the pipe and
    /// throws on any handshake failure.
    /// </summary>
    public async Task<NamedPipeClientStream> ConnectAndAuthenticateAsync(
        int connectTimeoutMs = 5_000, CancellationToken cancellationToken = default)
    {
        var pipe = new NamedPipeClientStream(
            serverName: ".",
            _pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous,
            System.Security.Principal.TokenImpersonationLevel.Anonymous);

        try
        {
            await pipe.ConnectAsync(connectTimeoutMs, cancellationToken).ConfigureAwait(false);
            pipe.ReadMode = PipeTransmissionMode.Message;

            if (_serverImageValidator is not null)
            {
                if (!NativeMethods.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out uint serverPid))
                {
                    throw new InvalidOperationException("Cannot resolve the watchdog pipe server identity.");
                }
                PeerImageVerdict image = _serverImageValidator.Validate(serverPid);
                if (!image.Trusted)
                {
                    throw new InvalidOperationException("The watchdog pipe server image is not first-party trusted.");
                }
            }

            if (!await RunMutualHandshakeAsync(pipe, cancellationToken).ConfigureAwait(false))
            {
                throw new InvalidOperationException("Daemon handshake failed; refusing the connection.");
            }

            return pipe;
        }
        catch
        {
            await pipe.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async Task<bool> RunMutualHandshakeAsync(PipeStream pipe, CancellationToken ct)
    {
        INonceSigner signer = _selfSignerFactory();
        INonceVerifier peerVerifier = _peerVerifierFactory();
        try
        {
            var endpoint = new MutualHandshakeEndpoint(HandshakeRole.Initiator, signer, peerVerifier);

            // Mirror the listener: the daemon challenges first (direction A), we answer;
            // then we challenge (direction B) and verify the daemon's answer.
            NonceChallenge daemonChallenge = await HandshakeWire.ReadChallengeAsync(pipe, ct).ConfigureAwait(false);
            SignedNonceResponse ourAnswer = endpoint.Responder.Respond(daemonChallenge);
            await HandshakeWire.WriteResponseAsync(pipe, ourAnswer, ct).ConfigureAwait(false);

            NonceChallenge ourChallenge = endpoint.Verifier.IssueChallenge();
            await HandshakeWire.WriteChallengeAsync(pipe, ourChallenge, ct).ConfigureAwait(false);
            SignedNonceResponse daemonAnswer = await HandshakeWire.ReadResponseAsync(pipe, ct).ConfigureAwait(false);

            return endpoint.Verifier.Verify(daemonAnswer) == HandshakeVerdict.Accepted;
        }
        finally
        {
            (signer as IDisposable)?.Dispose();
            (peerVerifier as IDisposable)?.Dispose();
        }
    }
}
