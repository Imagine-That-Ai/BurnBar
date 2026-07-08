using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Discovery;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Process;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// Injected collaborators for <see cref="PiAgentRuntimeAdapter"/>. Faithful port
/// of the Swift <c>PiAgentRuntimeAdapterDependencies</c> struct
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRuntimeAdapter.swift, lines
/// 5-29): the executable resolver, the run/launch process calls, the gateway
/// probe, the Redis discovery, and the command profile — each a swappable seam so
/// the state machine is fully testable off any real process/network.
///
/// The four process/network entry points are modeled as delegates, exactly as the
/// Swift struct models them as <c>@Sendable</c> closures, so tests can supply
/// inline fakes without a class per seam. <see cref="FromSeams"/> is the analog of
/// the Swift <c>.live</c> static: it adapts the strongly-typed
/// <see cref="IManagedExecutableResolver"/> / <see cref="IManagedRuntimeProcessRunner"/>
/// / <see cref="IManagedRuntimeGatewayProbe"/> seams into that delegate shape.
/// </summary>
public sealed class PiAgentRuntimeAdapterDependencies
{
    /// <summary>Resolve the Pi CLI to an absolute path, or null when absent.</summary>
    public Func<CancellationToken, Task<string?>> ResolvePiExecutable { get; }

    /// <summary>Run a command to completion and return merged stdout/stderr.</summary>
    public Func<string, IReadOnlyList<string>, CancellationToken, Task<string>> RunCommand { get; }

    /// <summary>Launch a command detached (fire-and-forget companion process).</summary>
    public Func<string, IReadOnlyList<string>, CancellationToken, Task> LaunchDetached { get; }

    /// <summary>Probe the OpenAI-compatible gateway for liveness + model name.</summary>
    public Func<Uri, string?, CancellationToken, Task<GatewayProbeResult>> ProbeGateway { get; }

    /// <summary>Redis-backed instance discovery.</summary>
    public IPiAgentRedisDiscovery RedisDiscovery { get; }

    /// <summary>The Pi CLI command profile (argument vectors).</summary>
    public PiAgentCommandProfile CommandProfile { get; }

    /// <summary>Constructs the bundle from raw delegates (the shape tests use directly).</summary>
    public PiAgentRuntimeAdapterDependencies(
        Func<CancellationToken, Task<string?>> resolvePiExecutable,
        Func<string, IReadOnlyList<string>, CancellationToken, Task<string>> runCommand,
        Func<string, IReadOnlyList<string>, CancellationToken, Task> launchDetached,
        Func<Uri, string?, CancellationToken, Task<GatewayProbeResult>> probeGateway,
        IPiAgentRedisDiscovery redisDiscovery,
        PiAgentCommandProfile commandProfile)
    {
        ResolvePiExecutable = resolvePiExecutable ?? throw new ArgumentNullException(nameof(resolvePiExecutable));
        RunCommand = runCommand ?? throw new ArgumentNullException(nameof(runCommand));
        LaunchDetached = launchDetached ?? throw new ArgumentNullException(nameof(launchDetached));
        ProbeGateway = probeGateway ?? throw new ArgumentNullException(nameof(probeGateway));
        RedisDiscovery = redisDiscovery ?? throw new ArgumentNullException(nameof(redisDiscovery));
        CommandProfile = commandProfile ?? throw new ArgumentNullException(nameof(commandProfile));
    }

    /// <summary>
    /// Wires the bundle from the strongly-typed seams — the equivalent of the
    /// Swift <c>PiAgentRuntimeAdapterDependencies.live</c> (lines 13-28), which
    /// binds <c>CLIExecutableResolver</c>, <c>ManagedRuntimeProcessRunner.run</c> /
    /// <c>.launchDetached</c>, <c>OpenAICompatibleModelProbe.probeWithModel</c>,
    /// <c>PiAgentRedisHTTPDiscovery()</c>, and <c>PiAgentCommandProfile.live</c>.
    /// </summary>
    /// <param name="executableResolver">Resolves the CLI name to a path.</param>
    /// <param name="processRunner">Runs / launches the CLI.</param>
    /// <param name="gatewayProbe">Probes the gateway.</param>
    /// <param name="redisDiscovery">Discovers Redis-registered instances.</param>
    /// <param name="commandProfile">Command profile; defaults to <see cref="PiAgentCommandProfile.Live"/>.</param>
    /// <param name="executableName">CLI name to resolve; defaults to <c>pi</c>.</param>
    public static PiAgentRuntimeAdapterDependencies FromSeams(
        IManagedExecutableResolver executableResolver,
        IManagedRuntimeProcessRunner processRunner,
        IManagedRuntimeGatewayProbe gatewayProbe,
        IPiAgentRedisDiscovery redisDiscovery,
        PiAgentCommandProfile? commandProfile = null,
        string executableName = "pi")
    {
        if (executableResolver is null)
        {
            throw new ArgumentNullException(nameof(executableResolver));
        }

        if (processRunner is null)
        {
            throw new ArgumentNullException(nameof(processRunner));
        }

        if (gatewayProbe is null)
        {
            throw new ArgumentNullException(nameof(gatewayProbe));
        }

        return new PiAgentRuntimeAdapterDependencies(
            resolvePiExecutable: ct => executableResolver.ResolveExecutableAsync(executableName, ct),
            runCommand: (executable, arguments, ct) => processRunner.RunAsync(executable, arguments, ct),
            launchDetached: (executable, arguments, ct) => processRunner.LaunchDetachedAsync(executable, arguments, ct),
            probeGateway: (baseUrl, bearerToken, ct) => gatewayProbe.ProbeAsync(baseUrl, bearerToken, ct),
            redisDiscovery: redisDiscovery,
            commandProfile: commandProfile ?? PiAgentCommandProfile.Live);
    }
}
