// IDaemonApprovalChannel over the landed named-pipe peer-auth harness.
//
// This CONSUMES OpenBurnBar.Pal.Ipc's mutual signed-nonce handshake rather than
// reimplementing it: the app raises an approval request to the privileged
// daemon across a NamedPipeClientStream, both ends prove possession of their
// pinned Ed25519/CNG key over a domain-separated transcript, and only an
// Accepted handshake is allowed to carry the approval request + decision.
//
// Wire (length-prefixed frames): my-challenge -> peer-challenge -> my-response
// (to peer) -> peer-response (to me, graded) -> approval-request-json ->
// decision-json.
//
// Windows-only at runtime (named pipes + CNG creds). Roslyn-compiles on the
// macOS authoring host; the live daemon round-trip is a Windows dev-host task.

using System;
using System.Buffers.Binary;
using System.IO;
using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using OpenBurnBar.Pal.Ipc;

namespace OpenBurnBar.ComputerUse.Windows;

/// <summary>Daemon-approval channel over a peer-authenticated named pipe.</summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class NamedPipeDaemonApprovalChannel : IDaemonApprovalChannel
{
    private readonly string _pipeName;
    private readonly INonceSigner _selfSigner;
    private readonly INonceVerifier _peerVerifier;

    public NamedPipeDaemonApprovalChannel(string pipeName, INonceSigner selfSigner, INonceVerifier peerVerifier)
    {
        _pipeName = pipeName ?? throw new ArgumentNullException(nameof(pipeName));
        _selfSigner = selfSigner ?? throw new ArgumentNullException(nameof(selfSigner));
        _peerVerifier = peerVerifier ?? throw new ArgumentNullException(nameof(peerVerifier));
    }

    public async Task<ApprovalDecision> RequestApprovalAsync(
        ComputerUseAction action,
        string sessionId,
        CancellationToken cancellationToken = default)
    {
        using var pipe = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(cancellationToken).ConfigureAwait(false);

        var endpoint = new MutualHandshakeEndpoint(HandshakeRole.Initiator, _selfSigner, _peerVerifier);

        // 1. Issue my challenge; the peer must answer it.
        var myChallenge = endpoint.Verifier.IssueChallenge();
        await WriteFrameAsync(pipe, HandshakeCodec.EncodeChallenge(myChallenge), cancellationToken).ConfigureAwait(false);

        // 2. Read + answer the peer's challenge.
        var peerChallenge = HandshakeCodec.DecodeChallenge(
            await ReadFrameAsync(pipe, cancellationToken).ConfigureAwait(false));
        var myResponse = endpoint.Responder.Respond(peerChallenge);
        await WriteFrameAsync(pipe, HandshakeCodec.EncodeResponse(myResponse), cancellationToken).ConfigureAwait(false);

        // 3. Grade the peer's answer to MY challenge — only Accepted proceeds.
        var peerResponse = HandshakeCodec.DecodeResponse(
            await ReadFrameAsync(pipe, cancellationToken).ConfigureAwait(false));
        if (endpoint.Verifier.Verify(peerResponse) != HandshakeVerdict.Accepted)
        {
            return new ApprovalDecision(approved: false, approvalId: string.Empty);
        }

        // 4. Send the approval request + read the operator's decision.
        var requestJson = JsonSerializer.SerializeToUtf8Bytes(new ApprovalRequestPayload
        {
            SessionId = sessionId,
            ActionKind = action.AuditKind,
            Summary = action.ExecutableSummary(),
        });
        await WriteFrameAsync(pipe, requestJson, cancellationToken).ConfigureAwait(false);

        var decisionBytes = await ReadFrameAsync(pipe, cancellationToken).ConfigureAwait(false);
        var decision = JsonSerializer.Deserialize<ApprovalDecisionPayload>(decisionBytes)
            ?? new ApprovalDecisionPayload();
        return new ApprovalDecision(decision.Approved, decision.ApprovalId ?? string.Empty);
    }

    private static async Task WriteFrameAsync(Stream stream, byte[] payload, CancellationToken cancellationToken)
    {
        var header = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(header, payload.Length);
        await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<byte[]> ReadFrameAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[4];
        await ReadExactAsync(stream, header, cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length is < 0 or > (1 << 20))
        {
            throw new InvalidDataException($"Frame length out of range: {length}.");
        }

        var payload = new byte[length];
        await ReadExactAsync(stream, payload, cancellationToken).ConfigureAwait(false);
        return payload;
    }

    private static async Task ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EndOfStreamException("Pipe closed mid-frame.");
            }

            offset += read;
        }
    }

    private sealed class ApprovalRequestPayload
    {
        public string SessionId { get; set; } = string.Empty;

        public string ActionKind { get; set; } = string.Empty;

        public string Summary { get; set; } = string.Empty;
    }

    private sealed class ApprovalDecisionPayload
    {
        public bool Approved { get; set; }

        public string? ApprovalId { get; set; }
    }
}

/// <summary>
/// Binds the transport's handshake verdict to the portable watchdog authenticator:
/// only an <see cref="HandshakeVerdict.Accepted"/> peer may command the watchdog.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class NamedPipeWatchdogPeerAuthenticator : IWatchdogPeerAuthenticator
{
    public bool IsAuthorized(object peer) => peer is HandshakeVerdict verdict && verdict == HandshakeVerdict.Accepted;
}

/// <summary>Compact length-agnostic codec for the handshake value types over a frame.</summary>
internal static class HandshakeCodec
{
    public static byte[] EncodeChallenge(NonceChallenge challenge)
    {
        var payload = new byte[1 + 8 + 8 + 4 + challenge.Nonce.Length];
        payload[0] = (byte)challenge.ChallengerRole;
        BinaryPrimitives.WriteInt64BigEndian(payload.AsSpan(1, 8), challenge.IssuedAtUnixMs);
        BinaryPrimitives.WriteInt64BigEndian(payload.AsSpan(9, 8), challenge.TtlMs);
        BinaryPrimitives.WriteInt32BigEndian(payload.AsSpan(17, 4), challenge.Nonce.Length);
        challenge.Nonce.CopyTo(payload.AsSpan(21));
        return payload;
    }

    public static NonceChallenge DecodeChallenge(byte[] payload)
    {
        var role = (HandshakeRole)payload[0];
        var issuedAt = BinaryPrimitives.ReadInt64BigEndian(payload.AsSpan(1, 8));
        var ttl = BinaryPrimitives.ReadInt64BigEndian(payload.AsSpan(9, 8));
        var nonceLen = BinaryPrimitives.ReadInt32BigEndian(payload.AsSpan(17, 4));
        var nonce = payload.AsSpan(21, nonceLen).ToArray();
        return new NonceChallenge(nonce, issuedAt, ttl, role);
    }

    public static byte[] EncodeResponse(SignedNonceResponse response)
    {
        var payload = new byte[4 + response.Nonce.Length + 4 + response.Signature.Length];
        BinaryPrimitives.WriteInt32BigEndian(payload.AsSpan(0, 4), response.Nonce.Length);
        response.Nonce.CopyTo(payload.AsSpan(4));
        var sigOffset = 4 + response.Nonce.Length;
        BinaryPrimitives.WriteInt32BigEndian(payload.AsSpan(sigOffset, 4), response.Signature.Length);
        response.Signature.CopyTo(payload.AsSpan(sigOffset + 4));
        return payload;
    }

    public static SignedNonceResponse DecodeResponse(byte[] payload)
    {
        var nonceLen = BinaryPrimitives.ReadInt32BigEndian(payload.AsSpan(0, 4));
        var nonce = payload.AsSpan(4, nonceLen).ToArray();
        var sigOffset = 4 + nonceLen;
        var sigLen = BinaryPrimitives.ReadInt32BigEndian(payload.AsSpan(sigOffset, 4));
        var signature = payload.AsSpan(sigOffset + 4, sigLen).ToArray();
        return new SignedNonceResponse(nonce, signature);
    }
}
