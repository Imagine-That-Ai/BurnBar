using System;
using System.Collections.Generic;
using OpenBurnBar.App.ManagedAgentRuntime;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ManagedAgentRuntimeKindTests
{
    [Theory]
    [InlineData(ManagedAgentRuntimeKind.Hermes, "hermes")]
    [InlineData(ManagedAgentRuntimeKind.PiAgent, "piAgent")]
    public void RawValueMatchesSwiftCaseNames(ManagedAgentRuntimeKind kind, string expected)
    {
        Assert.Equal(expected, kind.RawValue());
    }

    [Theory]
    [InlineData(ManagedAgentRuntimeKind.Hermes, "Hermes")]
    [InlineData(ManagedAgentRuntimeKind.PiAgent, "Pi Agent")]
    public void DisplayName(ManagedAgentRuntimeKind kind, string expected)
    {
        Assert.Equal(expected, kind.DisplayName());
    }

    [Theory]
    [InlineData(ManagedAgentRuntimeKind.Hermes, "http://127.0.0.1:8642/")]
    [InlineData(ManagedAgentRuntimeKind.PiAgent, "http://127.0.0.1:8765/")]
    public void DefaultGatewayBaseUrl(ManagedAgentRuntimeKind kind, string expected)
    {
        Assert.Equal(expected, kind.DefaultGatewayBaseUrl().ToString());
    }

    [Theory]
    [InlineData(ManagedAgentRuntimeKind.Hermes, "Open Hermes + Gateway")]
    [InlineData(ManagedAgentRuntimeKind.PiAgent, "Open Pi + Gateway")]
    public void OpenActionLabel(ManagedAgentRuntimeKind kind, string expected)
    {
        Assert.Equal(expected, kind.OpenActionLabel());
    }

    [Fact]
    public void PiDefaultGatewayPortIs8765()
    {
        // The Pi runtime listens on a different default port than Hermes; this
        // guards the two from silently colliding.
        Assert.Equal(8765, ManagedAgentRuntimeKind.PiAgent.DefaultGatewayBaseUrl().Port);
        Assert.Equal(8642, ManagedAgentRuntimeKind.Hermes.DefaultGatewayBaseUrl().Port);
    }

    [Fact]
    public void StatusIsReadyRequiresExecutableAndGateway()
    {
        Assert.True(new ManagedAgentRuntimeStatus { ExecutablePath = "/usr/bin/pi", GatewayRunning = true }.IsReady);
        Assert.False(new ManagedAgentRuntimeStatus { ExecutablePath = "/usr/bin/pi", GatewayRunning = false }.IsReady);
        Assert.False(new ManagedAgentRuntimeStatus { ExecutablePath = null, GatewayRunning = true }.IsReady);
        Assert.False(new ManagedAgentRuntimeStatus().IsReady);
    }

    [Fact]
    public void StatusIsReadyIgnoresRedis()
    {
        // Redis is optional, never required — a ready runtime with no Redis is ready.
        var status = new ManagedAgentRuntimeStatus
        {
            ExecutablePath = "/usr/bin/pi",
            GatewayRunning = true,
            RedisStatus = null,
        };
        Assert.True(status.IsReady);
    }

    [Fact]
    public void StatusEqualityIsStructuralIncludingInstances()
    {
        var a = new ManagedAgentRuntimeStatus
        {
            ExecutablePath = "/usr/bin/pi",
            GatewayRunning = true,
            Instances = new List<ManagedAgentInstance> { new("one", "One") },
            Message = "up",
        };
        var b = new ManagedAgentRuntimeStatus
        {
            ExecutablePath = "/usr/bin/pi",
            GatewayRunning = true,
            Instances = new List<ManagedAgentInstance> { new("one", "One") },
            Message = "up",
        };
        var c = b with { Instances = new List<ManagedAgentInstance> { new("two", "Two") } };

        Assert.Equal(a, b);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
        Assert.NotEqual(a, c);
    }

    [Fact]
    public void InstanceDefaultsMirrorSwiftInitializer()
    {
        var instance = new ManagedAgentInstance("id-1", "Display");
        Assert.True(instance.IsOnline);
        Assert.Null(instance.ActiveSessionId);
        Assert.Null(instance.GatewayBaseUrl);

        var offline = new ManagedAgentInstance(
            "id-2",
            "Off",
            isOnline: false,
            activeSessionId: "sess",
            gatewayBaseUrl: new Uri("http://127.0.0.1:8765"));
        Assert.False(offline.IsOnline);
        Assert.Equal("sess", offline.ActiveSessionId);
        Assert.Equal(new Uri("http://127.0.0.1:8765"), offline.GatewayBaseUrl);
    }
}
