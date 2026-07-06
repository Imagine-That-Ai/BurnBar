using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Process;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests.Fakes;

/// <summary>
/// A scripted <see cref="IManagedRuntimeProcessRunner"/>: a caller supplies a
/// handler that maps (executable, arguments) to stdout — and may throw to model a
/// failing command. Every run + detached launch is recorded in order so tests can
/// assert the exact command sequence (start / install / start; app status; detach).
/// </summary>
public sealed class RecordingProcessRunner : IManagedRuntimeProcessRunner
{
    private readonly Func<string, IReadOnlyList<string>, string> _run;

    public RecordingProcessRunner(Func<string, IReadOnlyList<string>, string> run)
    {
        _run = run;
    }

    public List<CommandInvocation> RunCalls { get; } = new();

    public List<CommandInvocation> LaunchCalls { get; } = new();

    public Task<string> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        RunCalls.Add(new CommandInvocation(executable, arguments));
        try
        {
            return Task.FromResult(_run(executable, arguments));
        }
        catch (Exception error)
        {
            return Task.FromException<string>(error);
        }
    }

    public Task LaunchDetachedAsync(
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        LaunchCalls.Add(new CommandInvocation(executable, arguments));
        return Task.CompletedTask;
    }
}

/// <summary>One recorded process invocation.</summary>
public sealed record CommandInvocation(string Executable, IReadOnlyList<string> Arguments);

/// <summary>Returns a fixed executable path (or null) and records the requested name.</summary>
public sealed class StubExecutableResolver : IManagedExecutableResolver
{
    private readonly string? _path;

    public StubExecutableResolver(string? path)
    {
        _path = path;
    }

    public string? RequestedName { get; private set; }

    public Task<string?> ResolveExecutableAsync(string name, CancellationToken cancellationToken = default)
    {
        RequestedName = name;
        return Task.FromResult(_path);
    }
}

/// <summary>Returns a scripted <see cref="GatewayProbeResult"/> and records each probe.</summary>
public sealed class StubGatewayProbe : IManagedRuntimeGatewayProbe
{
    private readonly Func<Uri, string?, GatewayProbeResult> _handler;

    public StubGatewayProbe(GatewayProbeResult result)
        : this((_, _) => result)
    {
    }

    public StubGatewayProbe(Func<Uri, string?, GatewayProbeResult> handler)
    {
        _handler = handler;
    }

    public List<(Uri BaseUrl, string? BearerToken)> Calls { get; } = new();

    public Task<GatewayProbeResult> ProbeAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default)
    {
        Calls.Add((baseUrl, bearerToken));
        return Task.FromResult(_handler(baseUrl, bearerToken));
    }
}
