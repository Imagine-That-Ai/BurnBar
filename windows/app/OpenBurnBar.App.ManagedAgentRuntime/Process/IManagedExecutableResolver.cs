using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Process;

/// <summary>
/// Resolves a CLI executable name (e.g. <c>pi</c>) to an absolute path, or null
/// when it cannot be found. Faithful analog of the Swift adapter's
/// <c>resolvePiExecutable</c> dependency, which delegates to
/// <c>CLIExecutableResolver().resolveExecutable(named: "pi")</c>
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRuntimeAdapter.swift, lines
/// 14-16; AgentLens/Services/CLIBridge/CLIExecutableResolver.swift).
///
/// DEFERRED (Windows/bucket-B remainder): the concrete resolver walks the
/// process PATH (honoring <c>PATHEXT</c>) plus the Windows equivalents of the
/// macOS search roots (<c>%USERPROFILE%\.local\bin</c>, the npm/bun/volta/asdf/
/// mise/nvm/fnm shim dirs, etc.) and probes for an executable file. That is a
/// filesystem/OS concern, so it ships in the net8.0-windows adapter; the state
/// machine depends only on this seam and tests fake it.
/// </summary>
public interface IManagedExecutableResolver
{
    /// <summary>
    /// Resolve <paramref name="name"/> to an absolute executable path, or null if
    /// not found. Must not throw for a missing executable — return null instead,
    /// matching the Swift <c>-&gt; String?</c> contract.
    /// </summary>
    Task<string?> ResolveExecutableAsync(string name, CancellationToken cancellationToken = default);
}
