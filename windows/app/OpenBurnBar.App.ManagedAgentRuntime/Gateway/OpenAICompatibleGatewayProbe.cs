using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Http;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Live <see cref="IManagedRuntimeGatewayProbe"/>: <c>GET /v1/models</c> over the
/// injectable HTTP seam, with the first advertised model extracted from the body.
///
/// Faithful port of <c>OpenAICompatibleModelProbe.probeWithModel</c> +
/// <c>probeWithModels</c>
/// (AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift, lines
/// 1130-1243) and the model-name extraction in
/// <c>OpenAICompatibleModelListParser.modelName</c>
/// (AgentLens/Services/CLIBridge/CLIStreamParsers.swift, lines 522-533):
///   * endpoint = <c>v1/models</c> resolved relative to the base URL;
///   * optional <c>Authorization: Bearer &lt;trimmed token&gt;</c> when non-empty;
///   * non-2xx or transport failure -&gt; <c>Available = false</c>;
///   * model name = <c>data[0].id</c> (non-empty) else the top-level <c>model</c>
///     string, else null.
/// </summary>
public sealed class OpenAICompatibleGatewayProbe : IManagedRuntimeGatewayProbe
{
    private static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(2);

    private readonly IManagedRuntimeHttpTransport _transport;
    private readonly TimeSpan _requestTimeout;

    /// <param name="transport">The HTTP seam (defaults are supplied by the caller/DI).</param>
    /// <param name="requestTimeout">
    /// Per-request timeout; defaults to 2s to match the Swift probe's
    /// <c>timeout: TimeInterval = 2</c>. Injectable so timing is not baked in.
    /// </param>
    public OpenAICompatibleGatewayProbe(IManagedRuntimeHttpTransport transport, TimeSpan? requestTimeout = null)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _requestTimeout = requestTimeout ?? DefaultRequestTimeout;
    }

    /// <inheritdoc />
    public async Task<GatewayProbeResult> ProbeAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default)
    {
        if (!TryBuildModelsEndpoint(baseUrl, out var endpoint))
        {
            return new GatewayProbeResult(false, null);
        }

        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        var trimmedToken = bearerToken?.Trim();
        if (!string.IsNullOrEmpty(trimmedToken))
        {
            headers["Authorization"] = "Bearer " + trimmedToken;
        }

        var request = new HttpProbeRequest(endpoint, "GET", headers, _requestTimeout);

        HttpProbeResponse response;
        try
        {
            response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return new GatewayProbeResult(false, null);
        }

        if (!IsSuccess(response.StatusCode))
        {
            return new GatewayProbeResult(false, null);
        }

        return new GatewayProbeResult(true, ModelName(response.Body));
    }

    /// <summary>
    /// Port of <c>OpenAICompatibleModelListParser.modelName(from:)</c>:
    /// <c>data[0].id</c> (non-empty) wins, else the top-level <c>model</c> string,
    /// else null. Malformed JSON yields null (Swift <c>try?</c> parity).
    /// </summary>
    public static string? ModelName(byte[] data)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data);
        }
        catch (JsonException)
        {
            return null;
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (root.TryGetProperty("data", out var models)
                && models.ValueKind == JsonValueKind.Array
                && models.GetArrayLength() > 0)
            {
                var first = models[0];
                if (first.ValueKind == JsonValueKind.Object
                    && first.TryGetProperty("id", out var id)
                    && id.ValueKind == JsonValueKind.String)
                {
                    var value = id.GetString();
                    if (!string.IsNullOrEmpty(value))
                    {
                        return value;
                    }
                }
            }

            if (root.TryGetProperty("model", out var model)
                && model.ValueKind == JsonValueKind.String)
            {
                var value = model.GetString();
                if (!string.IsNullOrEmpty(value))
                {
                    return value;
                }
            }

            return null;
        }
    }

    private static bool TryBuildModelsEndpoint(Uri baseUrl, out Uri endpoint)
    {
        endpoint = baseUrl;
        if (baseUrl is null || !baseUrl.IsAbsoluteUri)
        {
            return false;
        }

        try
        {
            endpoint = new Uri(baseUrl, "v1/models");
            return true;
        }
        catch (UriFormatException)
        {
            return false;
        }
    }

    private static bool IsSuccess(int statusCode) => statusCode >= 200 && statusCode <= 299;
}
