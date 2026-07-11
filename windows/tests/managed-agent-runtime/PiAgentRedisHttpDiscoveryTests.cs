using System;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Discovery;
using OpenBurnBar.App.ManagedAgentRuntime.Tests.Fakes;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class PiAgentRedisHttpDiscoveryTests
{
    private static readonly Uri Gateway = new("http://127.0.0.1:8765");

    [Fact]
    public async Task BuildsAdminInstancesEndpointRelativeToGateway()
    {
        var transport = FakeHttpTransport.Returning(200, "[]");
        var discovery = new PiAgentRedisHttpDiscovery(transport);

        await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: null);

        Assert.NotNull(transport.LastRequest);
        Assert.Equal("http://127.0.0.1:8765/admin/instances", transport.LastRequest!.Value.Url.ToString());
        Assert.Equal("GET", transport.LastRequest.Value.Method);
    }

    [Fact]
    public async Task AttachesBearerTokenWhenPresent()
    {
        var transport = FakeHttpTransport.Returning(200, "[]");
        var discovery = new PiAgentRedisHttpDiscovery(transport);

        await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: "  tok-123  ");

        Assert.Equal("Bearer tok-123", transport.LastRequest!.Value.Headers["Authorization"]);
    }

    [Fact]
    public async Task OmitsAuthorizationForBlankToken()
    {
        var transport = FakeHttpTransport.Returning(200, "[]");
        var discovery = new PiAgentRedisHttpDiscovery(transport);

        await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: "   ");

        Assert.False(transport.LastRequest!.Value.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public async Task ForwardsRedisUrlHeaderWhenConfigured()
    {
        var transport = FakeHttpTransport.Returning(200, "[]");
        var discovery = new PiAgentRedisHttpDiscovery(transport);

        await discovery.SnapshotAsync(
            redisUrl: new Uri("redis://cache:6379"),
            gatewayBaseUrl: Gateway,
            bearerToken: null);

        Assert.Equal("redis://cache:6379/", transport.LastRequest!.Value.Headers["X-Pi-Redis-URL"]);
    }

    [Fact]
    public async Task InvalidGatewayUrlIsReportedWithoutCallingTransport()
    {
        var transport = FakeHttpTransport.Returning(200, "[]");
        var discovery = new PiAgentRedisHttpDiscovery(transport);

        var snapshot = await discovery.SnapshotAsync(
            redisUrl: null,
            gatewayBaseUrl: new Uri("admin/instances", UriKind.Relative),
            bearerToken: null);

        Assert.False(snapshot.Available);
        Assert.Equal("Pi gateway base URL is invalid.", snapshot.StatusMessage);
        Assert.Empty(transport.Requests);
    }

    [Fact]
    public async Task Non2xxWithoutRedisUrlReportsNoRegistry()
    {
        var discovery = new PiAgentRedisHttpDiscovery(FakeHttpTransport.Returning(404, ""));

        var snapshot = await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: null);

        Assert.False(snapshot.Available);
        Assert.Equal("Pi gateway has no Redis-backed instance registry.", snapshot.StatusMessage);
    }

    [Fact]
    public async Task Non2xxWithRedisUrlReportsUnreachableConfigured()
    {
        var discovery = new PiAgentRedisHttpDiscovery(FakeHttpTransport.Returning(500, ""));

        var snapshot = await discovery.SnapshotAsync(
            redisUrl: new Uri("redis://cache:6379"),
            gatewayBaseUrl: Gateway,
            bearerToken: null);

        Assert.False(snapshot.Available);
        Assert.Equal("Pi Redis registry not reachable at the configured URL.", snapshot.StatusMessage);
    }

    [Fact]
    public async Task SuccessEmptyBodyReportsOnlineButEmpty()
    {
        var discovery = new PiAgentRedisHttpDiscovery(FakeHttpTransport.Returning(200, "[]"));

        var snapshot = await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: null);

        Assert.True(snapshot.Available);
        Assert.Empty(snapshot.Instances);
        Assert.Equal("Pi Redis registry is online but empty.", snapshot.StatusMessage);
    }

    [Fact]
    public async Task SingleInstanceUsesSingularNoun()
    {
        var discovery = new PiAgentRedisHttpDiscovery(
            FakeHttpTransport.Returning(200, """[{"id":"one"}]"""));

        var snapshot = await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: null);

        Assert.True(snapshot.Available);
        Assert.Single(snapshot.Instances);
        Assert.Equal("Pi Redis registry online — 1 instance.", snapshot.StatusMessage);
    }

    [Fact]
    public async Task MultipleInstancesUsePluralNoun()
    {
        var discovery = new PiAgentRedisHttpDiscovery(
            FakeHttpTransport.Returning(200, """[{"id":"one"},{"id":"two"},{"id":"three"}]"""));

        var snapshot = await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: null);

        Assert.Equal(3, snapshot.Instances.Count);
        Assert.Equal("Pi Redis registry online — 3 instances.", snapshot.StatusMessage);
    }

    [Fact]
    public async Task TransportThrowWithoutRedisUrlReportsGatewayUnreachable()
    {
        var discovery = new PiAgentRedisHttpDiscovery(
            FakeHttpTransport.Throwing(new IOException("connection refused")));

        var snapshot = await discovery.SnapshotAsync(redisUrl: null, gatewayBaseUrl: Gateway, bearerToken: null);

        Assert.False(snapshot.Available);
        Assert.Equal("Pi gateway not reachable for instance discovery.", snapshot.StatusMessage);
    }

    [Fact]
    public async Task TransportThrowWithRedisUrlIncludesErrorMessage()
    {
        var discovery = new PiAgentRedisHttpDiscovery(
            FakeHttpTransport.Throwing(new IOException("connection refused")));

        var snapshot = await discovery.SnapshotAsync(
            redisUrl: new Uri("redis://cache:6379"),
            gatewayBaseUrl: Gateway,
            bearerToken: null);

        Assert.False(snapshot.Available);
        Assert.Equal("Pi Redis registry not reachable: connection refused", snapshot.StatusMessage);
    }

    [Fact]
    public void UnavailableSnapshotConstant()
    {
        Assert.False(PiAgentRedisSnapshot.Unavailable.Available);
        Assert.Equal("Redis not configured.", PiAgentRedisSnapshot.Unavailable.StatusMessage);
        Assert.Empty(PiAgentRedisSnapshot.Unavailable.Instances);
    }
}
