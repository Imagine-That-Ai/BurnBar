using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Http;

/// <summary>
/// A single HTTP request the managed-runtime discovery + gateway probe issue.
/// This is the portable analog of the Swift <c>URLRequest</c> the Redis
/// discovery and the OpenAI-compatible model probe build.
/// </summary>
/// <param name="Url">Absolute request URL.</param>
/// <param name="Method">HTTP verb (always <c>GET</c> for the current callers).</param>
/// <param name="Headers">Request headers (Authorization / X-Pi-Redis-URL).</param>
/// <param name="Timeout">
/// Per-request timeout. Mirrors <c>URLRequest.timeoutInterval</c> (2s for both
/// the discovery and the model probe); supplied by the caller so timing stays
/// injectable rather than hard-coded inside the transport.
/// </param>
public readonly record struct HttpProbeRequest(
    Uri Url,
    string Method,
    IReadOnlyDictionary<string, string> Headers,
    TimeSpan Timeout);

/// <summary>
/// The response half: the analog of the <c>(Data, URLResponse)</c> tuple the
/// Swift callers destructure. Only the status code and raw body are needed.
/// </summary>
/// <param name="StatusCode">HTTP status code.</param>
/// <param name="Body">Raw response bytes (may be empty).</param>
public readonly record struct HttpProbeResponse(int StatusCode, byte[] Body);

/// <summary>
/// Injectable HTTP seam behind the Redis discovery and the gateway probe — the
/// portable stand-in for Foundation's <c>URLSession.data(for:)</c>.
///
/// The real implementation (<see cref="HttpClientManagedRuntimeHttpTransport"/>)
/// wraps <c>System.Net.Http.HttpClient</c>, which is fully cross-platform, so the
/// request-SHAPE + response-PARSE core is exercised unchanged on the macOS
/// authoring host. Tests inject a fake to drive every branch deterministically.
/// </summary>
public interface IManagedRuntimeHttpTransport
{
    /// <summary>
    /// Issue the request and return its response. Throws on a transport-level
    /// failure (no connection, timeout, cancellation); callers translate a throw
    /// into the "not reachable" snapshot, mirroring the Swift <c>catch</c>.
    /// </summary>
    Task<HttpProbeResponse> SendAsync(HttpProbeRequest request, CancellationToken cancellationToken = default);
}
