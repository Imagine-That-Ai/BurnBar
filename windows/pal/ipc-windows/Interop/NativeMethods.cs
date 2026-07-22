// Win32 P/Invoke surface for the ConPTY + named-pipe peer-auth harness.
// Scaffold for VAL-P0-CONPTY-018; live execution is VAL-P0-CONPTY-019.
//
// Declarations only — every method is `internal` (CA1401) and pinned to the
// System32 search path (mitigates DLL planting, R19) so nothing here is a
// visible API or a side-load vector. The harness classes call these.

using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

// The whole assembly is Windows-only: it wires the portable handshake into Win32
// primitives. Marking it here satisfies the platform-compatibility analyzer
// (CA1416) for the CNG / message-mode-pipe call sites while still compiling on the
// macOS authoring host (it just never runs there).
[assembly: SupportedOSPlatform("windows")]

// Pin every P/Invoke in this assembly to the System32 search path (mitigates DLL
// planting / side-loading, R19). Assembly-level because the attribute is not
// valid on a class declaration.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace OpenBurnBar.Pal.Ipc.Windows.Interop;

internal static class NativeMethods
{
    // ── Named pipe (kernel32) ──────────────────────────────────────────────────
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern SafePipeHandle CreateNamedPipeW(
        string lpName,
        uint dwOpenMode,
        uint dwPipeMode,
        uint nMaxInstances,
        uint nOutBufferSize,
        uint nInBufferSize,
        uint nDefaultTimeOut,
        ref SECURITY_ATTRIBUTES lpSecurityAttributes);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ConnectNamedPipe(SafePipeHandle hNamedPipe, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DisconnectNamedPipe(SafePipeHandle hNamedPipe);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle Pipe, out uint ClientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetNamedPipeServerProcessId(SafePipeHandle Pipe, out uint ServerProcessId);

    // ── SDDL -> security descriptor (advapi32) ─────────────────────────────────
    // R16 control: owner DACL — build the descriptor from an explicit SDDL string
    // so only the intended principals (SYSTEM, the interactive user) can open the
    // pipe.
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string StringSecurityDescriptor,
        uint StringSDRevision,
        out IntPtr SecurityDescriptor,
        out int SecurityDescriptorSize);

    // ── Peer impersonation / SID (advapi32) ────────────────────────────────────
    // R16 control: ImpersonateNamedPipeClient + SID — authenticate the connecting
    // token's owner instead of trusting a spoofable PID alone (TOCTOU/PID reuse).
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ImpersonateNamedPipeClient(SafePipeHandle hNamedPipe);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RevertToSelf();

    [DllImport("kernel32.dll")]
    internal static extern IntPtr GetCurrentThread();

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool OpenThreadToken(
        IntPtr ThreadHandle,
        uint DesiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool OpenAsSelf,
        out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetTokenInformation(
        IntPtr TokenHandle,
        int TokenInformationClass,
        IntPtr TokenInformation,
        int TokenInformationLength,
        out int ReturnLength);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ConvertSidToStringSidW(IntPtr Sid, out IntPtr StringSid);

    // ── ConPTY (kernel32) ──────────────────────────────────────────────────────
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreatePipe(
        out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);

    // Returns an HRESULT; S_OK (0) on success.
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern int CreatePseudoConsole(
        COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern void ClosePseudoConsole(IntPtr hPC);

    // ── Process + attribute list (kernel32) ────────────────────────────────────
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList,
        uint dwFlags,
        IntPtr Attribute,
        IntPtr lpValue,
        IntPtr cbSize,
        IntPtr lpPreviousValue,
        IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreateProcessW(
        string? lpApplicationName,
        string? lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFOEXW lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    // ── Job objects (kernel32) ─────────────────────────────────────────────────
    // R16/kill control: bind the child (and its whole tree) to a job so closing
    // the job terminates the tree — the Windows analog of exit-15-clean +
    // process-group kill.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetInformationJobObject(
        IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    // Returns the thread's previous suspend count, or 0xFFFFFFFF on failure.
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr hObject);

    // ── WinVerifyTrust (wintrust) ──────────────────────────────────────────────
    // R16/R19 control: verify the peer image is Authenticode-trusted. Image-only
    // is insufficient (a signed process can host an injected DLL) — see
    // PeerImageValidator, which pairs this with loaded-module validation.
    [DllImport("wintrust.dll", SetLastError = false)]
    internal static extern int WinVerifyTrust(IntPtr hwnd, ref Guid pgActionID, IntPtr pWVTData);

    [DllImport("wintrust.dll", SetLastError = false)]
    internal static extern IntPtr WTHelperProvDataFromStateData(IntPtr hStateData);

    [DllImport("wintrust.dll", SetLastError = false)]
    internal static extern IntPtr WTHelperGetProvSignerFromChain(
        IntPtr pProvData,
        uint idxSigner,
        [MarshalAs(UnmanagedType.Bool)] bool fCounterSigner,
        uint idxCounterSigner);

    // ── Generic (kernel32) ─────────────────────────────────────────────────────
    [DllImport("kernel32.dll")]
    internal static extern IntPtr LocalFree(IntPtr hMem);
}
