using System;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

/// <summary>Gateway authentication defaults and explicit loopback opt-out.</summary>
public sealed class GatewayAuthTokenPolicyTests
{
    [Fact]
    public void Resolve_PreservesConfiguredTokenAndTrimsIt()
    {
        Assert.Equal("token", GatewayAuthTokenPolicy.Resolve("  token  ", false));
    }

    [Fact]
    public void Resolve_OnlyReturnsNullForExplicitUnauthenticatedOptOut()
    {
        Assert.Null(GatewayAuthTokenPolicy.Resolve(null, true, () => throw new InvalidOperationException()));
        Assert.Equal("generated", GatewayAuthTokenPolicy.Resolve(null, false, () => " generated "));
    }

    [Fact]
    public void Generate_ReturnsUrlSafe256BitToken()
    {
        string token = GatewayAuthTokenPolicy.Generate();

        Assert.Equal(43, token.Length);
        Assert.DoesNotContain("+", token, StringComparison.Ordinal);
        Assert.DoesNotContain("/", token, StringComparison.Ordinal);
        Assert.DoesNotContain("=", token, StringComparison.Ordinal);
    }

    [Fact]
    public void Resolve_FailsClosedWhenGeneratorReturnsEmpty()
    {
        var error = Assert.Throws<InvalidOperationException>(() =>
            GatewayAuthTokenPolicy.Resolve(null, false, () => "  "));

        Assert.Equal("Gateway authentication token generation returned an empty value.", error.Message);
    }
}
