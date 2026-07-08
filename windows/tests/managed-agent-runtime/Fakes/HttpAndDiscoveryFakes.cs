using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime;
using OpenBurnBar.App.ManagedAgentRuntime.Discovery;
using OpenBurnBar.App.ManagedAgentRuntime.Http;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests.Fakes;

/// <summary>
/// A fully-deterministic <see cref="IManagedRuntimeHttpTransport"/> that records
/// every request and replays a scripted response (or throw). Lets the discovery +
/// gateway-probe tests assert the exact request SHAPE and drive every status
/// branch with no real socket.
/// </summary>
public sealed class FakeHttpTransport : IManagedRuntimeHttpTransport
{
    private readonly Func<HttpProbeRequest, HttpProbeResponse> _handler;

    public FakeHttpTransport(Func<HttpProbeRequest, HttpProbeResponse> handler)
    {
        _handler = handler;
    }

    public List<HttpProbeRequest> Requests { get; } = new();

    public HttpProbeRequest? LastRequest => Requests.Count > 0 ? Requests[Requests.Count - 1] : null;

    public static FakeHttpTransport Returning(int statusCode, string body) =>
        new(_ => new HttpProbeResponse(statusCode, Encoding.UTF8.GetBytes(body)));

    public static FakeHttpTransport Throwing(Exception error) =>
        new(_ => throw error);

    public Task<HttpProbeResponse> SendAsync(HttpProbeRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        try
        {
            return Task.FromResult(_handler(request));
        }
        catch (Exception error)
        {
            return Task.FromException<HttpProbeResponse>(error);
        }
    }
}

/// <summary>
/// A fixed-snapshot <see cref="IPiAgentRedisDiscovery"/> that records the
/// arguments it was called with, so the adapter tests can both control the
/// discovery result and assert the configured Redis URL / gateway URL / bearer
/// were forwarded.
/// </summary>
public sealed class FakeRedisDiscovery : IPiAgentRedisDiscovery
{
    private readonly PiAgentRedisSnapshot _snapshot;

    public FakeRedisDiscovery(PiAgentRedisSnapshot snapshot)
    {
        _snapshot = snapshot;
    }

    public int CallCount { get; private set; }

    public Uri? LastRedisUrl { get; private set; }

    public Uri? LastGatewayBaseUrl { get; private set; }

    public string? LastBearerToken { get; private set; }

    public Task<PiAgentRedisSnapshot> SnapshotAsync(
        Uri? redisUrl,
        Uri gatewayBaseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default)
    {
        CallCount++;
        LastRedisUrl = redisUrl;
        LastGatewayBaseUrl = gatewayBaseUrl;
        LastBearerToken = bearerToken;
        return Task.FromResult(_snapshot);
    }
}
