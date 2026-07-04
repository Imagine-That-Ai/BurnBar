using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.CloudSync.AppCheck.Mint;

// HTTP transport seam for the portable App Check mint client.
//
// The portable AppCheckMintClient owns ALL orchestration (Firebase callable URL
// assembly, Authorization bearer header, JSON body encode, response decode,
// fail-closed classification). The transport is the ONLY thing that touches a
// real network stack — on Windows/macOS it is a System.Net.Http implementation
// (OpenBurnBar.CloudSync.AppCheck.Net.HttpClientAppCheckMintTransport); in tests
// it is a deterministic fake OR a loopback HttpListener that mints a canned
// callable response, so the full claim->mint->install path is proven off-Windows.
//
// This mirrors the already-proven IHomeAssistantHttpTransport seam.

/// <summary>A single HTTP header (name/value) for the mint request/response.</summary>
public sealed record AppCheckMintHeader(string Name, string Value);

/// <summary>An outbound mint HTTP request the transport must send verbatim.</summary>
public sealed record AppCheckMintHttpRequest(
    string Method,
    string Url,
    IReadOnlyList<AppCheckMintHeader> Headers,
    byte[] Body,
    double TimeoutSeconds);

/// <summary>
/// The transport's response. A transport that cannot reach the host throws
/// <see cref="AppCheckMintException"/> (Timeout / Transport) rather than returning
/// a synthetic status, so the mint client can fail closed on transport faults.
/// </summary>
public sealed record AppCheckMintHttpResponse(
    int StatusCode,
    string Body);

/// <summary>The network seam the portable mint client sends its assembled request through.</summary>
public interface IAppCheckMintTransport
{
    Task<AppCheckMintHttpResponse> SendAsync(
        AppCheckMintHttpRequest request,
        CancellationToken cancellationToken = default);
}
