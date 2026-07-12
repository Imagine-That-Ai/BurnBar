using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Http;

namespace OpenBurnBar.App.ManagedAgentRuntime.Discovery;

/// <summary>
/// Live <see cref="IPiAgentRedisDiscovery"/>: issues <c>GET /admin/instances</c>
/// against the Pi gateway (which proxies the Redis-backed registry) and decodes
/// the response into instances.
///
/// Faithful port of the Swift <c>PiAgentRedisHTTPDiscovery</c> struct
/// (AgentLens/Services/ManagedAgentRuntime/PiAgentRedisDiscovery.swift, lines
/// 32-90). The HTTP call goes through the injectable
/// <see cref="IManagedRuntimeHttpTransport"/> seam (the <c>URLSession</c> analog),
/// so the request shaping, status handling, and body decoding are all provable on
/// the macOS authoring host with a fake transport. Every status string, the
/// endpoint construction, the header set, and the empty/populated/failed branches
/// match the Swift original.
/// </summary>
public sealed class PiAgentRedisHttpDiscovery : IPiAgentRedisDiscovery
{
    private static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(2);

    private readonly IManagedRuntimeHttpTransport _transport;
    private readonly TimeSpan _requestTimeout;

    /// <param name="transport">The HTTP seam (defaults are supplied by the caller/DI).</param>
    /// <param name="requestTimeout">
    /// Per-request timeout; defaults to 2s to match the Swift
    /// <c>URLRequest(timeoutInterval: 2)</c>. Injectable so timing is not baked in.
    /// </param>
    public PiAgentRedisHttpDiscovery(IManagedRuntimeHttpTransport transport, TimeSpan? requestTimeout = null)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _requestTimeout = requestTimeout ?? DefaultRequestTimeout;
    }

    /// <inheritdoc />
    public async Task<PiAgentRedisSnapshot> SnapshotAsync(
        Uri? redisUrl,
        Uri gatewayBaseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default)
    {
        if (!TryBuildEndpoint(gatewayBaseUrl, out var endpoint))
        {
            return new PiAgentRedisSnapshot(
                available: false,
                statusMessage: "Pi gateway base URL is invalid.",
                instances: Array.Empty<ManagedAgentInstance>());
        }

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var trimmedToken = bearerToken?.Trim();
        if (!string.IsNullOrEmpty(trimmedToken))
        {
            headers["Authorization"] = "Bearer " + trimmedToken;
        }

        if (redisUrl is not null)
        {
            headers["X-Pi-Redis-URL"] = redisUrl.ToString();
        }

        var request = new HttpProbeRequest(endpoint, "GET", headers, _requestTimeout);

        HttpProbeResponse response;
        try
        {
            response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            // Swift catches every error (including cancellation) and reports the
            // configured-vs-unconfigured "not reachable" message.
            return new PiAgentRedisSnapshot(
                available: false,
                statusMessage: redisUrl is null
                    ? "Pi gateway not reachable for instance discovery."
                    : "Pi Redis registry not reachable: " + error.Message,
                instances: Array.Empty<ManagedAgentInstance>());
        }

        if (!IsSuccess(response.StatusCode))
        {
            return new PiAgentRedisSnapshot(
                available: false,
                statusMessage: redisUrl is null
                    ? "Pi gateway has no Redis-backed instance registry."
                    : "Pi Redis registry not reachable at the configured URL.",
                instances: Array.Empty<ManagedAgentInstance>());
        }

        var decoded = PiAgentRedisInstanceDecoder.Decode(response.Body);
        if (decoded.Count == 0)
        {
            return new PiAgentRedisSnapshot(
                available: true,
                statusMessage: "Pi Redis registry is online but empty.",
                instances: Array.Empty<ManagedAgentInstance>());
        }

        var plural = decoded.Count == 1 ? string.Empty : "s";
        var message = string.Format(
            CultureInfo.InvariantCulture,
            "Pi Redis registry online — {0} instance{1}.",
            decoded.Count,
            plural);

        return new PiAgentRedisSnapshot(available: true, statusMessage: message, instances: decoded);
    }

    /// <summary>
    /// Resolves <c>admin/instances</c> relative to the gateway base URL, matching
    /// <c>URL(string: "admin/instances", relativeTo: gatewayBaseURL)?.absoluteURL</c>.
    /// </summary>
    private static bool TryBuildEndpoint(Uri gatewayBaseUrl, out Uri endpoint)
    {
        endpoint = gatewayBaseUrl;
        if (gatewayBaseUrl is null || !gatewayBaseUrl.IsAbsoluteUri)
        {
            return false;
        }

        try
        {
            endpoint = new Uri(gatewayBaseUrl, "admin/instances");
            return true;
        }
        catch (UriFormatException)
        {
            return false;
        }
    }

    private static bool IsSuccess(int statusCode) => statusCode >= 200 && statusCode <= 299;
}
