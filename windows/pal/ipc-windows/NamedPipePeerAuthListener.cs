// Hardened named-pipe server + peer-auth gate — the R16 orchestrator.
//
// This is the Windows analog of the macOS AF_UNIX + codesign/audit-token peer
// gate. It creates the pipe with an explicit SDDL DACL and FIRST_PIPE_INSTANCE,
// then, on each connection, runs the full peer-auth gate before any RPC byte is
// exchanged:
//
//   1. SDDL DACL           -> CreateHardenedServerPipe (owner-only DACL)
//   2. FIRST_PIPE_INSTANCE -> CreateHardenedServerPipe (anti-squat)
//   3. peer PID + SID       -> PeerIdentityResolver (ImpersonateNamedPipeClient)
//   4. image + modules      -> PeerImageValidator (WinVerifyTrust + module scan)
//   5. signed-nonce mutual  -> RunMutualHandshake (portable state machine + CNG)
//   6. release-hardened      -> #if !RELEASE_HARDENED dev bypass, compiled OUT
//
// Scaffold for VAL-P0-CONPTY-018 (compiles on macOS). The live end-to-end gate
// against a real connecting process is VAL-P0-CONPTY-019 — see the runbook.

using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
using OpenBurnBar.Pal.Ipc;
using OpenBurnBar.Pal.Ipc.Windows.Interop;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>Why a peer connection was rejected (or that it was accepted).</summary>
public enum PeerAuthOutcome
{
    Accepted,
    RejectedBySid,
    RejectedByImage,
    RejectedByHandshake,
    RejectedByError,
}

/// <summary>The result of gating one connection.</summary>
public sealed class PeerAuthResult
{
    public PeerAuthResult(PeerAuthOutcome outcome, PeerIdentity? identity, string detail)
    {
        Outcome = outcome;
        Identity = identity;
        Detail = detail;
    }

    public PeerAuthOutcome Outcome { get; }
    public PeerIdentity? Identity { get; }
    public string Detail { get; }
    public bool Accepted => Outcome == PeerAuthOutcome.Accepted;
}

/// <summary>
/// Policy inputs for the peer-auth gate — the pieces that a deployment provides.
/// </summary>
public sealed class PeerAuthPolicy
{
    public PeerAuthPolicy(
        string expectedClientSid,
        PeerImageValidator imageValidator,
        Func<INonceSigner> selfSignerFactory,
        Func<INonceVerifier> peerVerifierFactory)
    {
        ExpectedClientSid = expectedClientSid;
        ImageValidator = imageValidator;
        SelfSignerFactory = selfSignerFactory;
        PeerVerifierFactory = peerVerifierFactory;
    }

    /// <summary>The SID the connecting user MUST match (e.g. the interactive user).</summary>
    public string ExpectedClientSid { get; }

    /// <summary>Validates the peer's image + loaded modules.</summary>
    public PeerImageValidator ImageValidator { get; }

    /// <summary>Produces this side's transcript signer (CNG in production).</summary>
    public Func<INonceSigner> SelfSignerFactory { get; }

    /// <summary>Produces the verifier for the peer's pinned key.</summary>
    public Func<INonceVerifier> PeerVerifierFactory { get; }
}

/// <summary>
/// Creates hardened server pipes and runs the peer-auth gate on each connection.
/// </summary>
public sealed class NamedPipePeerAuthListener
{
    private readonly string _pipeName;
    private readonly PeerAuthPolicy _policy;

    public NamedPipePeerAuthListener(string pipeName, PeerAuthPolicy policy)
    {
        _pipeName = pipeName ?? throw new ArgumentNullException(nameof(pipeName));
        _policy = policy ?? throw new ArgumentNullException(nameof(policy));
    }

    /// <summary>
    /// Creates the first (and, via FIRST_PIPE_INSTANCE, provably-first) pipe
    /// instance with an explicit SDDL DACL. Owner-only by default: SYSTEM +
    /// the creating user get full access; nobody else is on the ACL.
    /// </summary>
    /// <param name="sddl">The security descriptor in SDDL. Defaults to
    /// <c>D:P(A;;GA;;;SY)(A;;GA;;;OW)</c> — a protected DACL (no inheritance)
    /// granting GENERIC_ALL to SYSTEM and the object owner only.</param>
    public NamedPipeServerStream CreateHardenedServerPipe(string? sddl = null)
    {
        sddl ??= "D:P(A;;GA;;;SY)(A;;GA;;;OW)";

        if (!NativeMethods.ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl, NativeConstants.SDDL_REVISION_1, out IntPtr pSd, out _))
        {
            throw new InvalidOperationException(
                $"Bad SDDL '{sddl}' (Win32={Marshal.GetLastWin32Error()}).");
        }

        try
        {
            var sa = new SECURITY_ATTRIBUTES
            {
                nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
                lpSecurityDescriptor = pSd,
                bInheritHandle = 0,
            };

            uint openMode =
                NativeConstants.PIPE_ACCESS_DUPLEX |
                NativeConstants.FILE_FLAG_FIRST_PIPE_INSTANCE |   // R16: anti-squat
                NativeConstants.FILE_FLAG_OVERLAPPED;

            uint pipeMode =
                NativeConstants.PIPE_TYPE_MESSAGE |
                NativeConstants.PIPE_READMODE_MESSAGE |
                NativeConstants.PIPE_REJECT_REMOTE_CLIENTS |      // local only
                NativeConstants.PIPE_WAIT;

            SafePipeHandle handle = NativeMethods.CreateNamedPipeW(
                $@"\\.\pipe\{_pipeName}",
                openMode,
                pipeMode,
                nMaxInstances: 1, // one instance: the daemon owns the only server end
                nOutBufferSize: 64 * 1024,
                nInBufferSize: 64 * 1024,
                nDefaultTimeOut: 0,
                ref sa);

            if (handle.IsInvalid)
            {
                throw new InvalidOperationException(
                    $"CreateNamedPipe failed (Win32={Marshal.GetLastWin32Error()}). " +
                    "A non-first instance error here means a squatter already owns the name.");
            }

            return new NamedPipeServerStream(PipeDirection.InOut, isAsync: true, isConnected: false, handle);
        }
        finally
        {
            NativeMethods.LocalFree(pSd);
        }
    }

    /// <summary>
    /// Runs the full peer-auth gate over an already-connected server pipe: SID,
    /// then image + modules, then the signed-nonce mutual handshake. Returns the
    /// first failing stage or <see cref="PeerAuthOutcome.Accepted"/>.
    /// </summary>
    public async Task<PeerAuthResult> AuthenticateConnectedPeerAsync(
        NamedPipeServerStream connectedPipe, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connectedPipe);

        try
        {
            // Stage 3 — kernel-attested PID + SID.
            PeerIdentity identity = PeerIdentityResolver.Resolve(connectedPipe.SafePipeHandle);
            if (!string.Equals(identity.UserSid, _policy.ExpectedClientSid, StringComparison.OrdinalIgnoreCase))
            {
                if (DeveloperBypassEngaged())
                {
                    return new PeerAuthResult(PeerAuthOutcome.Accepted, identity, "dev-bypass: SID mismatch ignored");
                }

                return new PeerAuthResult(
                    PeerAuthOutcome.RejectedBySid, identity,
                    $"client SID {identity.UserSid} != expected {_policy.ExpectedClientSid}");
            }

            // Stage 4 — image + loaded-module validation.
            PeerImageVerdict image = _policy.ImageValidator.Validate(identity.ProcessId);
            if (!image.Trusted)
            {
                return new PeerAuthResult(
                    PeerAuthOutcome.RejectedByImage, identity,
                    $"untrusted module(s): {string.Join(", ", image.UntrustedModules)}");
            }

            // Stage 5 — signed-nonce mutual handshake over the pipe.
            bool handshakeOk = await RunMutualHandshakeAsync(connectedPipe, cancellationToken)
                .ConfigureAwait(false);
            return handshakeOk
                ? new PeerAuthResult(PeerAuthOutcome.Accepted, identity, "authenticated")
                : new PeerAuthResult(PeerAuthOutcome.RejectedByHandshake, identity, "handshake failed");
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or OperationCanceledException)
        {
            return new PeerAuthResult(PeerAuthOutcome.RejectedByError, identity: null, ex.Message);
        }
    }

    /// <summary>
    /// Drives the mutual handshake: this side (Responder) challenges the peer and
    /// answers the peer's challenge, using the portable state machine with the
    /// policy's CNG-backed credentials. Wire framing is delegated to
    /// <see cref="HandshakeWire"/>.
    /// </summary>
    private async Task<bool> RunMutualHandshakeAsync(
        PipeStream pipe, CancellationToken cancellationToken)
    {
        INonceSigner signer = _policy.SelfSignerFactory();
        INonceVerifier peerVerifier = _policy.PeerVerifierFactory();
        try
        {
            var endpoint = new MutualHandshakeEndpoint(HandshakeRole.Responder, signer, peerVerifier);

            // Direction A: we challenge the peer.
            NonceChallenge ourChallenge = endpoint.Verifier.IssueChallenge();
            await HandshakeWire.WriteChallengeAsync(pipe, ourChallenge, cancellationToken).ConfigureAwait(false);
            SignedNonceResponse peerAnswer =
                await HandshakeWire.ReadResponseAsync(pipe, cancellationToken).ConfigureAwait(false);
            if (endpoint.Verifier.Verify(peerAnswer) != HandshakeVerdict.Accepted)
            {
                return false;
            }

            // Direction B: the peer challenges us; we answer.
            NonceChallenge peerChallenge =
                await HandshakeWire.ReadChallengeAsync(pipe, cancellationToken).ConfigureAwait(false);
            SignedNonceResponse ourAnswer = endpoint.Responder.Respond(peerChallenge);
            await HandshakeWire.WriteResponseAsync(pipe, ourAnswer, cancellationToken).ConfigureAwait(false);

            return true;
        }
        finally
        {
            (signer as IDisposable)?.Dispose();
            (peerVerifier as IDisposable)?.Dispose();
        }
    }

    /// <summary>
    /// The developer bypass, compiled OUT of hardened/release builds (R16:
    /// "compile out disable-env in release"). In a RELEASE_HARDENED build this is
    /// a constant <c>false</c> the JIT folds away, so the disable path cannot
    /// exist in a shipped binary even if the env var is set.
    /// </summary>
    private static bool DeveloperBypassEngaged()
    {
#if RELEASE_HARDENED
        return false;
#else
        return Environment.GetEnvironmentVariable("OPENBURNBAR_PIPE_AUTH_DISABLE") == "1";
#endif
    }
}
