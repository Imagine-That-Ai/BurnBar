using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Discovery;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.App.ManagedAgentRuntime;

/// <summary>
/// The Pi Agent managed-runtime controller: a state machine over the injected
/// seams that reads runtime status (refresh) and brings the runtime up (open).
///
/// Faithful port of the Swift <c>PiAgentRuntimeAdapter</c> final class
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRuntimeAdapter.swift, lines
/// 31-266). Every transition, message string, concurrency shape, and helper is
/// preserved:
///   * <see cref="RefreshManagedStatusAsync"/> resolves the CLI, fans out the
///     gateway probe + app-status probe + Redis discovery CONCURRENTLY (the Swift
///     <c>async let</c> trio), composes instances, resolves the selected one, and
///     builds the status message;
///   * <see cref="OpenManagedRuntimeAsync"/> ensures the gateway is up (start,
///     then install+start on failure), launches the app detached if needed, then
///     refreshes.
///
/// THREADING (see <see cref="IManagedAgentRuntimeAdapter"/>): the Swift class is
/// <c>@Observable @MainActor</c>. This port performs no internal locking — a single
/// instance is expected to be driven from one logical context (the UI dispatcher),
/// exactly like the single-actor Swift original. The WinUI layer marshals mutation
/// of the observable state onto the UI thread.
///
/// TIMING: the controller itself reads no wall clock (neither does the Swift
/// original). The only timing in the subsystem is the per-request HTTP timeout,
/// which is injected at the discovery + gateway-probe seams, so there is nothing
/// to fake here for deterministic tests.
/// </summary>
public sealed class PiAgentRuntimeAdapter : IManagedAgentRuntimeAdapter
{
    private const string CliNotFoundMessage =
        "Pi CLI is not installed or could not be found in the app PATH.";

    private readonly PiAgentRuntimeAdapterDependencies _dependencies;

    /// <inheritdoc />
    public ManagedAgentRuntimeKind Kind => ManagedAgentRuntimeKind.PiAgent;

    /// <inheritdoc />
    public ManagedAgentRuntimeStatus ManagedStatus { get; private set; } =
        new ManagedAgentRuntimeStatus { Message = "Pi has not been checked yet." };

    /// <inheritdoc />
    public bool IsBusy { get; private set; }

    /// <inheritdoc />
    public string? LastError { get; private set; }

    /// <summary>
    /// Currently selected instance ID, persisted by the caller (Settings). Parity:
    /// <c>preferredInstanceID</c> (line 44).
    /// </summary>
    public string? PreferredInstanceId { get; set; }

    /// <summary>
    /// Optional Redis URL configured in Settings, forwarded to discovery. Parity:
    /// <c>redisURL</c> (line 47).
    /// </summary>
    public Uri? RedisUrl { get; set; }

    /// <summary>Constructs the adapter. Parity: <c>init(dependencies:preferredInstanceID:redisURL:)</c> (lines 49-57).</summary>
    public PiAgentRuntimeAdapter(
        PiAgentRuntimeAdapterDependencies dependencies,
        string? preferredInstanceId = null,
        Uri? redisUrl = null)
    {
        _dependencies = dependencies ?? throw new ArgumentNullException(nameof(dependencies));
        PreferredInstanceId = preferredInstanceId;
        RedisUrl = redisUrl;
    }

    /// <inheritdoc />
    public async Task<ManagedAgentRuntimeStatus> RefreshManagedStatusAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default)
    {
        IsBusy = true;
        try
        {
            var executable = await _dependencies.ResolvePiExecutable(cancellationToken).ConfigureAwait(false);
            if (executable is null)
            {
                var missing = new ManagedAgentRuntimeStatus
                {
                    ExecutablePath = null,
                    GatewayRunning = false,
                    AppRunning = false,
                    ModelName = null,
                    RedisStatus = null,
                    SelectedInstanceId = null,
                    Instances = Array.Empty<ManagedAgentInstance>(),
                    Message = CliNotFoundMessage,
                };
                ManagedStatus = missing;
                LastError = missing.Message;
                return missing;
            }

            // Fan out the three probes concurrently — the Swift `async let` trio.
            var gatewayTask = _dependencies.ProbeGateway(baseUrl, bearerToken, cancellationToken);
            var appTask = AppIsRunningAsync(executable, cancellationToken);
            var redisTask = _dependencies.RedisDiscovery.SnapshotAsync(
                RedisUrl,
                baseUrl,
                bearerToken,
                cancellationToken);

            var gateway = await gatewayTask.ConfigureAwait(false);
            var appRunning = await appTask.ConfigureAwait(false);
            var redisSnapshot = await redisTask.ConfigureAwait(false);

            var instances = ComposeInstances(redisSnapshot, gateway.Available, baseUrl);
            var selected = ResolveSelectedInstance(instances);

            var next = new ManagedAgentRuntimeStatus
            {
                ExecutablePath = executable,
                GatewayRunning = gateway.Available,
                AppRunning = appRunning,
                ModelName = gateway.ModelName,
                RedisStatus = redisSnapshot.StatusMessage,
                SelectedInstanceId = selected?.Id,
                Instances = instances,
                Message = StatusMessage(
                    gateway.Available,
                    appRunning,
                    gateway.ModelName,
                    redisSnapshot,
                    selected),
            };
            ManagedStatus = next;
            LastError = null;
            return next;
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <inheritdoc />
    public async Task<ManagedAgentRuntimeStatus> OpenManagedRuntimeAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default)
    {
        IsBusy = true;
        LastError = null;
        try
        {
            var executable = await _dependencies.ResolvePiExecutable(cancellationToken).ConfigureAwait(false);
            if (executable is null)
            {
                var missing = new ManagedAgentRuntimeStatus { Message = CliNotFoundMessage };
                ManagedStatus = missing;
                LastError = CliNotFoundMessage;
                return missing;
            }

            try
            {
                // Step 1: ensure the gateway is up.
                var gatewayProbe = await _dependencies
                    .ProbeGateway(baseUrl, bearerToken, cancellationToken)
                    .ConfigureAwait(false);
                if (!gatewayProbe.Available)
                {
                    try
                    {
                        await _dependencies
                            .RunCommand(executable, _dependencies.CommandProfile.StartGatewayArguments, cancellationToken)
                            .ConfigureAwait(false);
                    }
                    catch
                    {
                        await _dependencies
                            .RunCommand(executable, _dependencies.CommandProfile.InstallGatewayArguments, cancellationToken)
                            .ConfigureAwait(false);
                        await _dependencies
                            .RunCommand(executable, _dependencies.CommandProfile.StartGatewayArguments, cancellationToken)
                            .ConfigureAwait(false);
                    }
                }

                // Step 2: ensure the Pi app/instance is up. Detached, like the
                // Hermes Dashboard.
                if (!await AppIsRunningAsync(executable, cancellationToken).ConfigureAwait(false))
                {
                    await _dependencies
                        .LaunchDetached(executable, _dependencies.CommandProfile.LaunchAppArguments, cancellationToken)
                        .ConfigureAwait(false);
                }

                return await RefreshManagedStatusAsync(baseUrl, bearerToken, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                var detail = error.Message;
                var next = new ManagedAgentRuntimeStatus
                {
                    ExecutablePath = executable,
                    GatewayRunning = false,
                    AppRunning = false,
                    ModelName = null,
                    RedisStatus = null,
                    SelectedInstanceId = null,
                    Instances = Array.Empty<ManagedAgentInstance>(),
                    Message = detail,
                };
                ManagedStatus = next;
                LastError = detail;
                return next;
            }
        }
        finally
        {
            IsBusy = false;
        }
    }

    // MARK: - Helpers

    /// <summary>
    /// Parity: <c>appIsRunning(executable:)</c> (lines 191-202). Runs the status
    /// command; alive when stdout contains <c>running</c> or <c>PID</c>
    /// (case-insensitive). A thrown command resolves to false.
    /// </summary>
    private async Task<bool> AppIsRunningAsync(string executable, CancellationToken cancellationToken)
    {
        try
        {
            var output = await _dependencies
                .RunCommand(executable, _dependencies.CommandProfile.AppStatusArguments, cancellationToken)
                .ConfigureAwait(false);
            return output.Contains("running", StringComparison.OrdinalIgnoreCase)
                || output.Contains("PID", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Parity: <c>composeInstances(redis:gatewayRunning:baseURL:)</c> (lines 204-224).</summary>
    private static IReadOnlyList<ManagedAgentInstance> ComposeInstances(
        PiAgentRedisSnapshot redis,
        bool gatewayRunning,
        Uri baseUrl)
    {
        if (redis.Available && redis.Instances.Count > 0)
        {
            return redis.Instances;
        }

        if (!gatewayRunning)
        {
            return Array.Empty<ManagedAgentInstance>();
        }

        // Single synthetic instance so the picker always offers something when the
        // gateway is alive but Redis isn't wired up.
        return new[]
        {
            new ManagedAgentInstance(
                id: "default",
                displayName: "Default",
                isOnline: true,
                activeSessionId: null,
                gatewayBaseUrl: baseUrl),
        };
    }

    /// <summary>Parity: <c>resolveSelectedInstance(from:)</c> (lines 226-232).</summary>
    private ManagedAgentInstance? ResolveSelectedInstance(IReadOnlyList<ManagedAgentInstance> instances)
    {
        if (PreferredInstanceId is not null)
        {
            foreach (var instance in instances)
            {
                if (instance.Id == PreferredInstanceId)
                {
                    return instance;
                }
            }
        }

        return instances.Count > 0 ? instances[0] : null;
    }

    /// <summary>Parity: <c>statusMessage(gatewayRunning:appRunning:modelName:redis:selected:)</c> (lines 234-265).</summary>
    private static string StatusMessage(
        bool gatewayRunning,
        bool appRunning,
        string? modelName,
        PiAgentRedisSnapshot redis,
        ManagedAgentInstance? selected)
    {
        if (gatewayRunning && appRunning)
        {
            var head = new StringBuilder("Pi agent and gateway are running.");
            if (!string.IsNullOrEmpty(modelName))
            {
                head = new StringBuilder("Pi agent and gateway are running. Model: " + modelName + ".");
            }

            if (selected is not null)
            {
                head.Append(" Active instance: " + selected.DisplayName + ".");
            }

            if (redis.Available && redis.Instances.Count > 1)
            {
                head.Append(" Redis registry reports " + redis.Instances.Count + " instances.");
            }

            return head.ToString();
        }

        if (gatewayRunning)
        {
            if (!string.IsNullOrEmpty(modelName))
            {
                return "Pi gateway is running. Model: " + modelName + ".";
            }

            return "Pi gateway is running.";
        }

        if (appRunning)
        {
            return "Pi agent is running, but the local gateway is not reachable yet.";
        }

        return "Pi agent and gateway are not running.";
    }
}
