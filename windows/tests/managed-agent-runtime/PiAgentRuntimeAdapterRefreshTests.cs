using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime;
using OpenBurnBar.App.ManagedAgentRuntime.Discovery;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Tests.Fakes;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class PiAgentRuntimeAdapterRefreshTests
{
    private static readonly Uri BaseUrl = new("http://127.0.0.1:8765");
    private const string Pi = "/usr/local/bin/pi";

    private static PiAgentRedisSnapshot RedisWith(params ManagedAgentInstance[] instances) =>
        new(available: true, statusMessage: "registry", instances: instances);

    private static (
        PiAgentRuntimeAdapter Adapter,
        RecordingProcessRunner Runner,
        StubGatewayProbe Probe,
        FakeRedisDiscovery Redis,
        StubExecutableResolver Resolver)
        Build(
            string? executable,
            GatewayProbeResult gateway,
            string appStatusOutput,
            PiAgentRedisSnapshot? redis = null,
            string? preferred = null,
            Uri? redisUrl = null)
    {
        var resolver = new StubExecutableResolver(executable);
        var runner = new RecordingProcessRunner((_, _) => appStatusOutput);
        var probe = new StubGatewayProbe(gateway);
        var discovery = new FakeRedisDiscovery(redis ?? PiAgentRedisSnapshot.Unavailable);
        var deps = PiAgentRuntimeAdapterDependencies.FromSeams(resolver, runner, probe, discovery);
        var adapter = new PiAgentRuntimeAdapter(deps, preferredInstanceId: preferred, redisUrl: redisUrl);
        return (adapter, runner, probe, discovery, resolver);
    }

    [Fact]
    public async Task MissingCliShortCircuitsAndSetsError()
    {
        var (adapter, _, probe, redis, resolver) = Build(
            executable: null,
            gateway: new GatewayProbeResult(true, "m"),
            appStatusOutput: "running");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Null(status.ExecutablePath);
        Assert.False(status.GatewayRunning);
        Assert.False(status.AppRunning);
        Assert.Empty(status.Instances);
        Assert.Equal("Pi CLI is not installed or could not be found in the app PATH.", status.Message);
        Assert.Equal(status.Message, adapter.LastError);
        Assert.False(adapter.IsBusy);

        // The probes must NOT run when the CLI is absent.
        Assert.Empty(probe.Calls);
        Assert.Equal(0, redis.CallCount);
        Assert.Equal("pi", resolver.RequestedName);
    }

    [Fact]
    public async Task GatewayAndAppRunningYieldsReadyStatusWithSyntheticDefault()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "agent running (pid 42)");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.True(status.IsReady);
        Assert.True(status.GatewayRunning);
        Assert.True(status.AppRunning);
        Assert.Equal(Pi, status.ExecutablePath);
        var instance = Assert.Single(status.Instances);
        Assert.Equal("default", instance.Id);
        Assert.Equal("Default", instance.DisplayName);
        Assert.Equal(BaseUrl, instance.GatewayBaseUrl);
        Assert.Equal("default", status.SelectedInstanceId);
        Assert.Equal("Pi agent and gateway are running. Active instance: Default.", status.Message);
        Assert.Null(adapter.LastError);
    }

    [Fact]
    public async Task ModelNameIsWovenIntoRunningMessage()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, "pi-opus"),
            appStatusOutput: "running");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Equal("pi-opus", status.ModelName);
        Assert.Equal(
            "Pi agent and gateway are running. Model: pi-opus. Active instance: Default.",
            status.Message);
    }

    [Fact]
    public async Task GatewayOnlyMessage()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "stopped");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.True(status.GatewayRunning);
        Assert.False(status.AppRunning);
        Assert.Equal("Pi gateway is running.", status.Message);
        // A live gateway still offers the synthetic default instance.
        Assert.Equal("default", status.SelectedInstanceId);
    }

    [Fact]
    public async Task GatewayOnlyMessageWithModel()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, "pi-haiku"),
            appStatusOutput: "");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Equal("Pi gateway is running. Model: pi-haiku.", status.Message);
    }

    [Fact]
    public async Task AppOnlyMessageAndNoInstances()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(false, null),
            appStatusOutput: "running");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.False(status.GatewayRunning);
        Assert.True(status.AppRunning);
        Assert.Empty(status.Instances);
        Assert.Null(status.SelectedInstanceId);
        Assert.Equal("Pi agent is running, but the local gateway is not reachable yet.", status.Message);
        Assert.False(status.IsReady);
    }

    [Fact]
    public async Task NothingRunningMessage()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(false, null),
            appStatusOutput: "");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Equal("Pi agent and gateway are not running.", status.Message);
        Assert.Empty(status.Instances);
    }

    [Fact]
    public async Task RedisInstancesReplaceSyntheticDefaultAndCountIsReported()
    {
        var redis = RedisWith(
            new ManagedAgentInstance("pi-a", "Alpha"),
            new ManagedAgentInstance("pi-b", "Beta"));
        var (adapter, _, _, discovery, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "running",
            redis: redis);

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Equal(2, status.Instances.Count);
        Assert.Equal("pi-a", status.Instances[0].Id);
        Assert.Equal("pi-a", status.SelectedInstanceId);
        Assert.Equal("registry", status.RedisStatus);
        Assert.Equal(
            "Pi agent and gateway are running. Active instance: Alpha. Redis registry reports 2 instances.",
            status.Message);
        Assert.Equal(1, discovery.CallCount);
    }

    [Fact]
    public async Task PreferredInstanceIsSelectedWhenPresent()
    {
        var redis = RedisWith(
            new ManagedAgentInstance("pi-a", "Alpha"),
            new ManagedAgentInstance("pi-b", "Beta"));
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "running",
            redis: redis,
            preferred: "pi-b");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Equal("pi-b", status.SelectedInstanceId);
        Assert.Contains("Active instance: Beta.", status.Message);
    }

    [Fact]
    public async Task PreferredInstanceFallsBackToFirstWhenAbsent()
    {
        var redis = RedisWith(
            new ManagedAgentInstance("pi-a", "Alpha"),
            new ManagedAgentInstance("pi-b", "Beta"));
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "running",
            redis: redis,
            preferred: "does-not-exist");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.Equal("pi-a", status.SelectedInstanceId);
    }

    [Fact]
    public async Task RedisAndGatewayReceiveConfiguredArguments()
    {
        var redisUrl = new Uri("redis://cache:6379");
        var (adapter, _, probe, discovery, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "running",
            redisUrl: redisUrl);

        await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: "tok");

        Assert.Equal(redisUrl, discovery.LastRedisUrl);
        Assert.Equal(BaseUrl, discovery.LastGatewayBaseUrl);
        Assert.Equal("tok", discovery.LastBearerToken);
        var call = Assert.Single(probe.Calls);
        Assert.Equal(BaseUrl, call.BaseUrl);
        Assert.Equal("tok", call.BearerToken);
    }

    [Fact]
    public async Task AppStatusProbeUsesTheCommandProfileArguments()
    {
        var (adapter, runner, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "running");

        await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        var call = Assert.Single(runner.RunCalls);
        Assert.Equal(Pi, call.Executable);
        Assert.Equal(new[] { "agent", "status" }, call.Arguments);
        Assert.Empty(runner.LaunchCalls);
    }

    [Fact]
    public async Task PidTokenAloneCountsAsAppRunning()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(false, null),
            appStatusOutput: "PID 9182 healthy");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.True(status.AppRunning);
    }

    [Fact]
    public async Task AppStatusUsesCaseInsensitiveSubstringMatchLikeSwift()
    {
        // Parity guard: the Swift oracle uses range(of: "running", .caseInsensitive),
        // a plain substring match. "Not Running" therefore counts as running — this
        // port keeps that exact heuristic on purpose.
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(false, null),
            appStatusOutput: "Agent is Not Running");

        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);

        Assert.True(status.AppRunning);
    }

    [Fact]
    public async Task IsBusyIsClearedAfterRefresh()
    {
        var (adapter, _, _, _, _) = Build(
            executable: Pi,
            gateway: new GatewayProbeResult(true, null),
            appStatusOutput: "running");

        Assert.False(adapter.IsBusy);
        var status = await adapter.RefreshManagedStatusAsync(BaseUrl, bearerToken: null);
        Assert.False(adapter.IsBusy);
        // The returned status is the one now published on the adapter.
        Assert.Equal(status, adapter.ManagedStatus);
    }
}
