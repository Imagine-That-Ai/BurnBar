using System;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class GatewayListenerOptionsTests
{
    [Fact]
    public void Resolve_UsesPersistedSettingsWhenNoOverridesExist()
    {
        GatewayListenerOptions options = GatewayListenerOptions.Resolve(
            configuredEnabled: true,
            configuredHost: " localhost ",
            configuredPort: 8317);

        Assert.True(options.Enabled);
        Assert.Equal("localhost", options.Host);
        Assert.Equal(8317, options.Port);
        Assert.True(options.IsLoopback);
        Assert.Equal("http://localhost:8317/", options.BaseAddress.AbsoluteUri);
    }

    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("127.42.0.8")]
    [InlineData("::1")]
    [InlineData("localhost")]
    [InlineData("LOCALHOST")]
    public void Resolve_RecognizesLoopbackHosts(string host)
    {
        GatewayListenerOptions options = GatewayListenerOptions.Resolve(false, host, 8317);

        Assert.True(options.IsLoopback);
    }

    [Fact]
    public void Resolve_EnvironmentEndpointOverrideEnablesLegacyAutomationPath()
    {
        GatewayListenerOptions options = GatewayListenerOptions.Resolve(
            configuredEnabled: false,
            configuredHost: "127.0.0.1",
            configuredPort: 8317,
            hostOverride: "0.0.0.0",
            portOverride: "8642");

        Assert.True(options.Enabled);
        Assert.Equal("0.0.0.0", options.Host);
        Assert.Equal(8642, options.Port);
        Assert.False(options.IsLoopback);
    }

    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("localhost", true)]
    [InlineData("0.0.0.0", false)]
    [InlineData("192.168.1.10", false)]
    public void AllowsUnauthenticatedAccess_RequiresAnActualLoopbackBind(string host, bool expected)
    {
        GatewayListenerOptions options = GatewayListenerOptions.Resolve(true, host, 8317);

        Assert.Equal(expected, options.AllowsUnauthenticatedAccess(configuredAllow: true));
        Assert.Equal(expected, options.AllowsUnauthenticatedAccess(configuredAllow: false, allowOverride: "1"));
    }

    [Theory]
    [InlineData("0", false)]
    [InlineData("false", false)]
    [InlineData("1", true)]
    [InlineData("TRUE", true)]
    public void Resolve_ExplicitEnabledOverrideWins(string value, bool expected)
    {
        GatewayListenerOptions options = GatewayListenerOptions.Resolve(
            configuredEnabled: !expected,
            configuredHost: "127.0.0.1",
            configuredPort: 8317,
            enabledOverride: value,
            portOverride: "8642");

        Assert.Equal(expected, options.Enabled);
    }

    [Theory]
    [InlineData("")]
    [InlineData("http://localhost")]
    [InlineData("localhost/path")]
    [InlineData("localhost\\path")]
    public void Resolve_RejectsInvalidHosts(string host)
    {
        Assert.Throws<ArgumentException>(() => GatewayListenerOptions.Resolve(true, host, 8317));
    }

    [Theory]
    [InlineData("maybe")]
    [InlineData("2")]
    public void Resolve_RejectsInvalidEnabledOverrides(string value)
    {
        Assert.Throws<ArgumentException>(() => GatewayListenerOptions.Resolve(
            true,
            "127.0.0.1",
            8317,
            enabledOverride: value));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(65536)]
    public void Resolve_RejectsInvalidPorts(int port)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            GatewayListenerOptions.Resolve(true, "127.0.0.1", port));
    }

    [Fact]
    public void Constructor_CannotBypassValidation()
    {
        Assert.Throws<ArgumentException>(() => new GatewayListenerOptions(true, "http://localhost", 8317));
        Assert.Throws<ArgumentOutOfRangeException>(() => new GatewayListenerOptions(true, "localhost", 0));
    }
}
