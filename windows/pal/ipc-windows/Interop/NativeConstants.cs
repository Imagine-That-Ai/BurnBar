// Win32 constants / flags used by the ConPTY + named-pipe peer-auth harness.
// Scaffold for VAL-P0-CONPTY-018; live execution is VAL-P0-CONPTY-019.

using System;

namespace OpenBurnBar.Pal.Ipc.Windows.Interop;

internal static class NativeConstants
{
    // ── Named pipe creation (CreateNamedPipeW) ─────────────────────────────────
    // R16 control: FIRST_PIPE_INSTANCE — the server fails to create the pipe if
    // another process already owns an instance of the name, defeating a squatter
    // that raced us to the name.
    internal const uint PIPE_ACCESS_DUPLEX = 0x00000003;
    internal const uint FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
    internal const uint FILE_FLAG_OVERLAPPED = 0x40000000;

    internal const uint PIPE_TYPE_MESSAGE = 0x00000004;
    internal const uint PIPE_READMODE_MESSAGE = 0x00000002;
    internal const uint PIPE_REJECT_REMOTE_CLIENTS = 0x00000008;
    internal const uint PIPE_WAIT = 0x00000000;

    internal const uint PIPE_UNLIMITED_INSTANCES = 255;

    internal const uint SDDL_REVISION_1 = 1;

    // ── Process / job objects ──────────────────────────────────────────────────
    internal const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    internal const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    internal const uint CREATE_SUSPENDED = 0x00000004;

    // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE (0x00020016) — attaches the ConPTY to
    // the child at CreateProcess time.
    internal static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;

    // SetInformationJobObject class for extended limit info.
    internal const int JobObjectExtendedLimitInformation = 9;

    // R16/kill control: children of a killed parent die with the job.
    internal const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

    // ── Token / impersonation ──────────────────────────────────────────────────
    internal const uint TOKEN_QUERY = 0x0008;
    internal const int TokenUser = 1; // TOKEN_INFORMATION_CLASS.TokenUser

    // ── WinVerifyTrust ─────────────────────────────────────────────────────────
    // WINTRUST_ACTION_GENERIC_VERIFY_V2
    internal static readonly Guid WINTRUST_ACTION_GENERIC_VERIFY_V2 =
        new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    internal const uint WTD_UI_NONE = 2;
    internal const uint WTD_REVOKE_NONE = 0;
    internal const uint WTD_CHOICE_FILE = 1;
    internal const uint WTD_STATEACTION_VERIFY = 1;
    internal const uint WTD_STATEACTION_CLOSE = 2;

    // WinVerifyTrust returns 0 (S_OK) for a valid, trusted Authenticode signature.
    internal const int TRUST_S_OK = 0;

    // ── Generic ────────────────────────────────────────────────────────────────
    internal const uint INFINITE = 0xFFFFFFFF;
    internal static readonly IntPtr INVALID_HANDLE_VALUE = new(-1);
    internal const int ERROR_PIPE_CONNECTED = 535;
}
