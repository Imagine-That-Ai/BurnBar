using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.HomeAssistant.Rest;

namespace OpenBurnBar.Integrations.Tests;

/// Loads the recorded HA response fixtures copied next to the test assembly.
internal static class Fixtures
{
    public static string Load(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", name);
        return File.ReadAllText(path);
    }
}

/// A deterministic IHomeAssistantHttpTransport that records the request it was
/// handed and replies with a queued canned response (or throws a queued
/// exception), so the portable client can be driven off recorded fixtures with
/// zero network.
internal sealed class FakeHomeAssistantTransport : IHomeAssistantHttpTransport
{
    private readonly Queue<Func<HaHttpRequest, HaHttpResponse>> _responders = new();

    public List<HaHttpRequest> Requests { get; } = new();

    public HaHttpRequest LastRequest => Requests[^1];

    public void EnqueueResponse(int statusCode, string body, params HaHeader[] headers)
    {
        var response = new HaHttpResponse(statusCode, headers, body);
        _responders.Enqueue(_ => response);
    }

    public void EnqueueResponder(Func<HaHttpRequest, HaHttpResponse> responder) => _responders.Enqueue(responder);

    public void EnqueueThrow(HomeAssistantClientException exception) =>
        _responders.Enqueue(_ => throw exception);

    public Task<HaHttpResponse> SendAsync(HaHttpRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        if (_responders.Count == 0)
        {
            throw new InvalidOperationException("FakeHomeAssistantTransport received an unexpected request: " + request.Url);
        }
        var responder = _responders.Dequeue();
        return Task.FromResult(responder(request));
    }
}
