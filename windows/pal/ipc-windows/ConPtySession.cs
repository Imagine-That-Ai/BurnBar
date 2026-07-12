// ConPTY session harness — spawn + resize + clean process-tree kill.
//
// The Windows analog of the macOS openpty() interactive session. It creates a
// pseudoconsole (CreatePseudoConsole), launches a child bound to it via the
// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE startup attribute, exposes the child's tty
// as input/output streams, supports live resize (ResizePseudoConsole), and kills
// the whole child process tree through a Job Object (JobObjectProcessTree) — the
// substitute for the mac's SIGTERM/exit-15 + process-group kill, since Windows
// has no SIGTERM.
//
// Scaffold for VAL-P0-CONPTY-018 (compiles on macOS). Interactive spawn/resize/
// kill against a real console program (e.g. claude / cmd.exe) is
// VAL-P0-CONPTY-019 — see the runbook.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using OpenBurnBar.Pal.Ipc.Windows.Interop;

namespace OpenBurnBar.Pal.Ipc.Windows;

/// <summary>
/// A live pseudoconsole session wrapping a spawned child process.
/// </summary>
public sealed class ConPtySession : IDisposable
{
    private IntPtr _hPseudoConsole;
    private IntPtr _attributeList;
    private PROCESS_INFORMATION _processInfo;
    private readonly JobObjectProcessTree _job;
    private bool _disposed;

    private ConPtySession(
        IntPtr hPseudoConsole,
        IntPtr attributeList,
        PROCESS_INFORMATION processInfo,
        JobObjectProcessTree job,
        FileStream input,
        FileStream output)
    {
        _hPseudoConsole = hPseudoConsole;
        _attributeList = attributeList;
        _processInfo = processInfo;
        _job = job;
        Input = input;
        Output = output;
    }

    /// <summary>Write end of the child's stdin (bytes typed into the terminal).</summary>
    public Stream Input { get; }

    /// <summary>Read end of the child's terminal output (VT stream).</summary>
    public Stream Output { get; }

    /// <summary>The spawned child's process id.</summary>
    public int ProcessId => _processInfo.dwProcessId;

    /// <summary>
    /// Spawns <paramref name="commandLine"/> attached to a fresh pseudoconsole of
    /// the given size.
    /// </summary>
    /// <exception cref="InvalidOperationException">On any Win32 failure.</exception>
    public static ConPtySession Spawn(
        string commandLine,
        short columns,
        short rows,
        string? workingDirectory = null,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(commandLine);
        if (columns <= 0 || rows <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(columns), "Console dimensions must be positive.");
        }

        var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>() };

        // Two anonymous pipes: one feeds the ConPTY input, one drains its output.
        if (!NativeMethods.CreatePipe(out IntPtr inputRead, out IntPtr inputWrite, ref sa, 0))
        {
            throw Win32("CreatePipe(input)");
        }

        if (!NativeMethods.CreatePipe(out IntPtr outputRead, out IntPtr outputWrite, ref sa, 0))
        {
            NativeMethods.CloseHandle(inputRead);
            NativeMethods.CloseHandle(inputWrite);
            throw Win32("CreatePipe(output)");
        }

        IntPtr hpc = IntPtr.Zero;
        IntPtr attrList = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        JobObjectProcessTree? job = null;
        var pi = default(PROCESS_INFORMATION);
        bool processCreated = false;
        try
        {
            var size = new COORD { X = columns, Y = rows };
            int hr = NativeMethods.CreatePseudoConsole(size, inputRead, outputWrite, dwFlags: 0, out hpc);
            if (hr != NativeConstants.TRUST_S_OK)
            {
                throw new InvalidOperationException($"CreatePseudoConsole failed (HRESULT=0x{hr:X8}).");
            }

            // The ConPTY duplicated the ends it needs; close our copies of them so
            // only the app-facing ends (inputWrite / outputRead) remain.
            NativeMethods.CloseHandle(inputRead);
            NativeMethods.CloseHandle(outputWrite);
            inputRead = IntPtr.Zero;
            outputWrite = IntPtr.Zero;

            attrList = BuildPseudoConsoleAttributeList(hpc);

            var startupInfo = new STARTUPINFOEXW();
            startupInfo.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEXW>();
            startupInfo.lpAttributeList = attrList;
            environmentBlock = BuildEnvironmentBlock(environment);

            // CREATE_SUSPENDED so the child is assigned to the job BEFORE it runs;
            // otherwise a grandchild spawned in the gap before AssignProcessToJobObject
            // could escape the kill-on-close tree.
            uint flags =
                NativeConstants.EXTENDED_STARTUPINFO_PRESENT |
                NativeConstants.CREATE_UNICODE_ENVIRONMENT |
                NativeConstants.CREATE_SUSPENDED;
            if (!NativeMethods.CreateProcessW(
                    lpApplicationName: null,
                    lpCommandLine: commandLine,
                    lpProcessAttributes: IntPtr.Zero,
                    lpThreadAttributes: IntPtr.Zero,
                    bInheritHandles: false,
                    dwCreationFlags: flags,
                    lpEnvironment: environmentBlock,
                    lpCurrentDirectory: workingDirectory,
                    lpStartupInfo: ref startupInfo,
                    lpProcessInformation: out pi))
            {
                throw Win32("CreateProcess");
            }

            Marshal.FreeHGlobal(environmentBlock);
            environmentBlock = IntPtr.Zero;
            processCreated = true;

            // Bind the child (and everything it spawns) to a kill-on-close job,
            // then release the suspended primary thread.
            job = new JobObjectProcessTree();
            job.Assign(pi.hProcess);
            job.TrackRootProcessId(pi.dwProcessId);

            if (NativeMethods.ResumeThread(pi.hThread) == 0xFFFFFFFF)
            {
                throw Win32("ResumeThread");
            }

            var input = new FileStream(new SafeFileHandle(inputWrite, ownsHandle: true), FileAccess.Write);
            var output = new FileStream(new SafeFileHandle(outputRead, ownsHandle: true), FileAccess.Read);
            inputWrite = IntPtr.Zero;
            outputRead = IntPtr.Zero;

            return new ConPtySession(hpc, attrList, pi, job, input, output);
        }
        catch
        {
            // Kill and release a child already created before the failure.
            if (processCreated)
            {
                NativeMethods.TerminateProcess(pi.hProcess, 1);
                NativeMethods.CloseHandle(pi.hThread);
                NativeMethods.CloseHandle(pi.hProcess);
            }

            job?.Dispose();

            if (hpc != IntPtr.Zero)
            {
                NativeMethods.ClosePseudoConsole(hpc);
            }

            if (attrList != IntPtr.Zero)
            {
                NativeMethods.DeleteProcThreadAttributeList(attrList);
                Marshal.FreeHGlobal(attrList);
            }

            if (environmentBlock != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(environmentBlock);
            }

            foreach (IntPtr h in new[] { inputRead, inputWrite, outputRead, outputWrite })
            {
                if (h != IntPtr.Zero)
                {
                    NativeMethods.CloseHandle(h);
                }
            }

            throw;
        }
    }

    private static IntPtr BuildEnvironmentBlock(IReadOnlyDictionary<string, string>? environment)
    {
        if (environment is null)
        {
            return IntPtr.Zero;
        }

        var builder = new StringBuilder();
        foreach (var pair in environment)
        {
            if (string.IsNullOrEmpty(pair.Key))
            {
                continue;
            }

            builder.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
        }

        builder.Append('\0');
        return Marshal.StringToHGlobalUni(builder.ToString());
    }

    /// <summary>
    /// Resizes the live pseudoconsole. Safe to call while the child runs.
    /// </summary>
    public void Resize(short columns, short rows)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (columns <= 0 || rows <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(columns), "Console dimensions must be positive.");
        }

        int hr = NativeMethods.ResizePseudoConsole(_hPseudoConsole, new COORD { X = columns, Y = rows });
        if (hr != NativeConstants.TRUST_S_OK)
        {
            throw new InvalidOperationException($"ResizePseudoConsole failed (HRESULT=0x{hr:X8}).");
        }
    }

    /// <summary>
    /// Terminates the child and its entire process tree via the Job Object. This
    /// is the clean-kill path (R16/kill): no orphaned grandchildren survive.
    /// </summary>
    public void KillProcessTree(uint exitCode = 1)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _job.TerminateTree(exitCode);
    }

    private static IntPtr BuildPseudoConsoleAttributeList(IntPtr hpc)
    {
        // Sizing call: lpSize is filled with the required byte count.
        IntPtr size = IntPtr.Zero;
        NativeMethods.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);

        IntPtr attrList = Marshal.AllocHGlobal(size);
        if (!NativeMethods.InitializeProcThreadAttributeList(attrList, 1, 0, ref size))
        {
            Marshal.FreeHGlobal(attrList);
            throw Win32("InitializeProcThreadAttributeList");
        }

        IntPtr hpcValue = Marshal.AllocHGlobal(IntPtr.Size);
        try
        {
            Marshal.WriteIntPtr(hpcValue, hpc);
            if (!NativeMethods.UpdateProcThreadAttribute(
                    attrList,
                    dwFlags: 0,
                    NativeConstants.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    hpcValue,
                    (IntPtr)IntPtr.Size,
                    IntPtr.Zero,
                    IntPtr.Zero))
            {
                NativeMethods.DeleteProcThreadAttributeList(attrList);
                Marshal.FreeHGlobal(attrList);
                throw Win32("UpdateProcThreadAttribute");
            }
        }
        finally
        {
            // The attribute list holds a copy of the pointer value, not this
            // buffer, so it is safe to free the temporary immediately.
            Marshal.FreeHGlobal(hpcValue);
        }

        return attrList;
    }

    private static InvalidOperationException Win32(string what) =>
        new($"{what} failed (Win32={Marshal.GetLastWin32Error()}).");

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        Input.Dispose();
        Output.Dispose();

        // Closing the ConPTY signals the child to exit; the job guarantees the
        // whole tree is gone even if the child ignores the close.
        if (_hPseudoConsole != IntPtr.Zero)
        {
            NativeMethods.ClosePseudoConsole(_hPseudoConsole);
            _hPseudoConsole = IntPtr.Zero;
        }

        if (_attributeList != IntPtr.Zero)
        {
            NativeMethods.DeleteProcThreadAttributeList(_attributeList);
            Marshal.FreeHGlobal(_attributeList);
            _attributeList = IntPtr.Zero;
        }

        if (_processInfo.hThread != IntPtr.Zero)
        {
            NativeMethods.CloseHandle(_processInfo.hThread);
            _processInfo.hThread = IntPtr.Zero;
        }

        if (_processInfo.hProcess != IntPtr.Zero)
        {
            NativeMethods.CloseHandle(_processInfo.hProcess);
            _processInfo.hProcess = IntPtr.Zero;
        }

        _job.Dispose();
    }
}
