using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Process;

/// <summary>
/// Generic command-failed error so callers don't need to depend on a specific
/// adapter's error type. Faithful port of the Swift
/// <c>ManagedRuntimeProcessRunner.CommandFailedError</c>
/// (AgentLens/Services/ManagedAgentRuntime/ManagedRuntimeProcessRunner.swift,
/// lines 12-20), including its message rule: <c>"&lt;command&gt; failed."</c> when
/// the trimmed detail is empty, else <c>"&lt;command&gt; failed: &lt;detail&gt;"</c>.
/// </summary>
public sealed class ManagedRuntimeCommandFailedException : Exception
{
    /// <summary>The full command line that failed (executable + arguments, space-joined).</summary>
    public string Command { get; }

    /// <summary>The captured stderr (or stdout) detail, verbatim.</summary>
    public string Detail { get; }

    /// <summary>Builds the exception with the same message rule as the Swift original.</summary>
    public ManagedRuntimeCommandFailedException(string command, string detail)
        : base(BuildMessage(command, detail))
    {
        Command = command;
        Detail = detail;
    }

    private static string BuildMessage(string command, string detail)
    {
        var trimmed = (detail ?? string.Empty).Trim();
        return trimmed.Length == 0 ? command + " failed." : command + " failed: " + trimmed;
    }
}

/// <summary>
/// Shared process invocation seam used by every managed runtime adapter. Faithful
/// port of the Swift <c>ManagedRuntimeProcessRunner</c> enum
/// (AgentLens/Services/ManagedAgentRuntime/ManagedRuntimeProcessRunner.swift): a
/// blocking "run and collect merged output" call plus a "launch detached" call.
///
/// DEFERRED (Windows/bucket-B remainder): the real implementation launches a
/// Win32 child process. It reuses the process/stream seam already landed in the
/// Windows tree rather than inventing one — <c>ConPtySession.Spawn</c>
/// (OpenBurnBar.Pal.Ipc.Windows) driven by
/// <c>windows/app/OpenBurnBar.App/Cli/ConPtyCliStream.cs</c>: <see cref="RunAsync"/>
/// spawns the child and reads its ConPTY output to EOF (the equivalent of the
/// Swift <c>Pipe</c> + <c>readDataToEndOfFile</c>), while
/// <see cref="LaunchDetachedAsync"/> spawns with output/stdin detached (the
/// <c>FileHandle.nullDevice</c> analog). That adapter is net8.0-windows and
/// cannot build on macOS, so it lives outside this portable core; the state
/// machine here depends only on this interface and tests fake it.
///
/// The environment-hardening the Swift runner applies
/// (<c>CLIExecutableResolver.enrichedProcessEnvironment</c> — an allowlisted PATH
/// baseline that strips app/daemon secrets, M-040) is the adapter's
/// responsibility on the same deferred path; this contract documents it so it is
/// not lost.
/// </summary>
public interface IManagedRuntimeProcessRunner
{
    /// <summary>
    /// Run <paramref name="executable"/> to completion and return its merged
    /// stdout/stderr. Throws <see cref="ManagedRuntimeCommandFailedException"/> on a
    /// non-zero exit. Parity: <c>ManagedRuntimeProcessRunner.run</c> (lines 28-53).
    /// </summary>
    Task<string> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Launch <paramref name="executable"/> and return immediately, with
    /// stdout/stderr/stdin detached — for long-lived companion apps that own their
    /// own lifecycle. Parity: <c>ManagedRuntimeProcessRunner.launchDetached</c>
    /// (lines 60-69).
    /// </summary>
    Task LaunchDetachedAsync(
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default);
}
