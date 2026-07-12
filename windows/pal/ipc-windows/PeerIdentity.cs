// Resolve the authenticated identity of a connected named-pipe peer.
//
// R16 control: "Handle-validate the peer (or ImpersonateNamedPipeClient + SID)".
// A bare client PID is spoofable via PID reuse / TOCTOU, so this resolves BOTH
// the client PID (GetNamedPipeClientProcessId) and the client token's user SID
// (ImpersonateNamedPipeClient -> OpenThreadToken -> GetTokenInformation) from the
// kernel, which cannot be forged by the connecting process.
//
// Scaffold for VAL-P0-CONPTY-018; live proof against a real connecting process is
// VAL-P0-CONPTY-019.

using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using OpenBurnBar.Pal.Ipc.Windows.Interop;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>The kernel-attested identity of a connected pipe client.</summary>
public sealed class PeerIdentity
{
    public PeerIdentity(uint processId, string userSid)
    {
        ProcessId = processId;
        UserSid = userSid;
    }

    /// <summary>The connecting process id, from <c>GetNamedPipeClientProcessId</c>.</summary>
    public uint ProcessId { get; }

    /// <summary>The connecting token's user SID in SDDL string form (e.g. <c>S-1-5-...</c>).</summary>
    public string UserSid { get; }
}

/// <summary>
/// Resolves a <see cref="PeerIdentity"/> from a connected server pipe handle.
/// </summary>
public static class PeerIdentityResolver
{
    /// <summary>
    /// Reads the client PID and impersonates the client just long enough to read
    /// its user SID. Always reverts the impersonation before returning.
    /// </summary>
    /// <exception cref="InvalidOperationException">If any Win32 step fails.</exception>
    public static PeerIdentity Resolve(SafePipeHandle connectedServerPipe)
    {
        ArgumentNullException.ThrowIfNull(connectedServerPipe);

        if (!NativeMethods.GetNamedPipeClientProcessId(connectedServerPipe, out uint pid))
        {
            throw new InvalidOperationException(
                $"GetNamedPipeClientProcessId failed (Win32={Marshal.GetLastWin32Error()}).");
        }

        string sid = ResolveClientSid(connectedServerPipe);
        return new PeerIdentity(pid, sid);
    }

    private static string ResolveClientSid(SafePipeHandle pipe)
    {
        // Impersonation changes the current THREAD token; guard it so a throw can
        // never leak the client's context past this method.
        if (!NativeMethods.ImpersonateNamedPipeClient(pipe))
        {
            throw new InvalidOperationException(
                $"ImpersonateNamedPipeClient failed (Win32={Marshal.GetLastWin32Error()}).");
        }

        IntPtr token = IntPtr.Zero;
        IntPtr tokenUserBuffer = IntPtr.Zero;
        IntPtr sidString = IntPtr.Zero;
        try
        {
            if (!NativeMethods.OpenThreadToken(
                    NativeMethods.GetCurrentThread(), NativeConstants.TOKEN_QUERY, OpenAsSelf: true, out token))
            {
                throw new InvalidOperationException(
                    $"OpenThreadToken failed (Win32={Marshal.GetLastWin32Error()}).");
            }

            // Two-call pattern: size, then fetch.
            NativeMethods.GetTokenInformation(
                token, NativeConstants.TokenUser, IntPtr.Zero, 0, out int needed);
            if (needed <= 0)
            {
                throw new InvalidOperationException(
                    $"GetTokenInformation(size) failed (Win32={Marshal.GetLastWin32Error()}).");
            }

            tokenUserBuffer = Marshal.AllocHGlobal(needed);
            if (!NativeMethods.GetTokenInformation(
                    token, NativeConstants.TokenUser, tokenUserBuffer, needed, out _))
            {
                throw new InvalidOperationException(
                    $"GetTokenInformation(TokenUser) failed (Win32={Marshal.GetLastWin32Error()}).");
            }

            var tokenUser = Marshal.PtrToStructure<TOKEN_USER>(tokenUserBuffer);
            if (!NativeMethods.ConvertSidToStringSidW(tokenUser.User.Sid, out sidString))
            {
                throw new InvalidOperationException(
                    $"ConvertSidToStringSid failed (Win32={Marshal.GetLastWin32Error()}).");
            }

            return Marshal.PtrToStringUni(sidString)
                ?? throw new InvalidOperationException("ConvertSidToStringSid returned null.");
        }
        finally
        {
            if (sidString != IntPtr.Zero)
            {
                NativeMethods.LocalFree(sidString);
            }

            if (tokenUserBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(tokenUserBuffer);
            }

            if (token != IntPtr.Zero)
            {
                NativeMethods.CloseHandle(token);
            }

            // Restore our own security context no matter what happened above.
            NativeMethods.RevertToSelf();
        }
    }
}
