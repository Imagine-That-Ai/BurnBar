// Job-Object-backed clean process-tree kill.
//
// Windows has no SIGTERM and no POSIX process group, so the mac's
// "SIGTERM the group, treat exit 15 as clean" logic is rewritten here: assign the
// child to a Job Object flagged JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE so the entire
// tree dies when the job closes, and expose an explicit TerminateJobObject for a
// deterministic kill. A `taskkill /T /F /PID` fallback covers the rare case where
// a grandchild broke away into its own job (breakaway is denied by default, but
// the fallback keeps the harness honest).
//
// Scaffold for VAL-P0-CONPTY-018 (compiles on macOS). Proving no orphaned
// grandchild survives a kill is VAL-P0-CONPTY-019 — see the runbook.

using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using OpenBurnBar.Pal.Ipc.Windows.Interop;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>
/// A Job Object that kills its whole process tree on demand or on close.
/// </summary>
public sealed class JobObjectProcessTree : IDisposable
{
    private IntPtr _hJob;
    private int _rootProcessId;
    private bool _disposed;

    /// <summary>
    /// Creates an anonymous job configured to terminate every assigned process
    /// (and their descendants) when the job handle closes.
    /// </summary>
    public JobObjectProcessTree()
    {
        _hJob = NativeMethods.CreateJobObjectW(IntPtr.Zero, null);
        if (_hJob == IntPtr.Zero)
        {
            throw new InvalidOperationException($"CreateJobObject failed (Win32={Marshal.GetLastWin32Error()}).");
        }

        ConfigureKillOnClose();
    }

    private void ConfigureKillOnClose()
    {
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = NativeConstants.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        int length = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(info, buffer, fDeleteOld: false);
            if (!NativeMethods.SetInformationJobObject(
                    _hJob, NativeConstants.JobObjectExtendedLimitInformation, buffer, (uint)length))
            {
                throw new InvalidOperationException(
                    $"SetInformationJobObject failed (Win32={Marshal.GetLastWin32Error()}).");
            }
        }
        finally
        {
            Marshal.DestroyStructure<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>(buffer);
            Marshal.FreeHGlobal(buffer);
        }
    }

    /// <summary>
    /// Assigns a process (by native handle) to this job. Everything the process
    /// spawns afterward is captured by the job as well.
    /// </summary>
    public void Assign(IntPtr processHandle)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!NativeMethods.AssignProcessToJobObject(_hJob, processHandle))
        {
            throw new InvalidOperationException(
                $"AssignProcessToJobObject failed (Win32={Marshal.GetLastWin32Error()}).");
        }
    }

    /// <summary>Records the tree root PID so the taskkill fallback can target it.</summary>
    public void TrackRootProcessId(int processId) => _rootProcessId = processId;

    /// <summary>
    /// Terminates every process in the job (the whole tree) with
    /// <paramref name="exitCode"/>.
    /// </summary>
    public void TerminateTree(uint exitCode = 1)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!NativeMethods.TerminateJobObject(_hJob, exitCode) && _rootProcessId != 0)
        {
            TaskKillFallback(_rootProcessId);
        }
    }

    /// <summary>
    /// Last-resort tree kill via <c>taskkill /T /F</c>, used only if
    /// <see cref="TerminateJobObject"/> could not (e.g. a broken-away child).
    /// </summary>
    private static void TaskKillFallback(int rootProcessId)
    {
        var psi = new ProcessStartInfo("taskkill.exe", $"/PID {rootProcessId} /T /F")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.Environment.Clear();
        AddIfPresent(psi, "SystemRoot");
        AddIfPresent(psi, "WINDIR");
        AddIfPresent(psi, "PATH");
        AddIfPresent(psi, "PATHEXT");

        using Process? killer = Process.Start(psi);
        killer?.WaitForExit(5_000);
    }

    private static void AddIfPresent(ProcessStartInfo psi, string name)
    {
        string? value = Environment.GetEnvironmentVariable(name);
        if (!string.IsNullOrWhiteSpace(value))
        {
            psi.Environment[name] = value;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_hJob != IntPtr.Zero)
        {
            // Closing the handle triggers KILL_ON_JOB_CLOSE for anything still
            // running in the job.
            NativeMethods.CloseHandle(_hJob);
            _hJob = IntPtr.Zero;
        }
    }
}
