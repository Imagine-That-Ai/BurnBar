using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.Integrations.HomeAssistant.Rest;

// HTTP transport seam for the portable Home Assistant client.
//
// The portable client owns ALL orchestration (endpoint assembly, auth header,
// status/error mapping, entity projection). The transport is the ONLY thing
// that touches a real network stack — on Windows it is a System.Net.Http
// implementation (OpenBurnBar.Integrations.HomeAssistant.Net); in tests it is a
// deterministic fake fed by recorded HA response fixtures. Parity: this splits
// the Swift `URLSession`-backed `HomeAssistantClient` at its already
// URLProtocol-injectable seam.

/// A single HA HTTP header (name/value), preserving case for X-HA-Version reads.
public sealed record HaHeader(string Name, string Value);

/// An outbound HA HTTP request the transport must send verbatim.
public sealed record HaHttpRequest(
    string Method,
    string Url,
    IReadOnlyList<HaHeader> Headers,
    byte[]? Body,
    double TimeoutSeconds);

/// The transport's response. A transport that fails to reach the host throws
/// HomeAssistantClientException (Timeout / Transport), matching the Swift
/// `sendRequest` URLError mapping.
public sealed record HaHttpResponse(
    int StatusCode,
    IReadOnlyList<HaHeader> Headers,
    string Body)
{
    /// Case-insensitive header lookup (HA emits both `X-HA-Version` and
    /// `X-Ha-Version` across versions/proxies).
    public string? Header(string name)
    {
        foreach (var header in Headers)
        {
            if (string.Equals(header.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return header.Value;
            }
        }
        return null;
    }
}

public interface IHomeAssistantHttpTransport
{
    Task<HaHttpResponse> SendAsync(HaHttpRequest request, CancellationToken cancellationToken = default);
}
