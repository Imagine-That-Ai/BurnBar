using System;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Outcome of a gateway liveness probe: whether the OpenAI-compatible gateway
/// answered <c>GET /v1/models</c> with a 2xx, and the first advertised model
/// name when present. Mirrors the Swift
/// <c>probeWithModel</c> return tuple <c>(available: Bool, modelName: String?)</c>.
/// </summary>
/// <param name="Available">True when the gateway returned a 2xx to <c>/v1/models</c>.</param>
/// <param name="ModelName">First advertised model id / <c>model</c> field, if any.</param>
public readonly record struct GatewayProbeResult(bool Available, string? ModelName);

/// <summary>
/// Injectable gateway-probe seam. The runtime controller depends only on this
/// interface so tests drive the "gateway up / down / up-with-model" branches
/// deterministically, and the real network probe stays swappable.
///
/// Faithful port of the entry point the Pi adapter uses in Swift:
/// <c>dependencies.probeGateway</c> -&gt;
/// <c>OpenAICompatibleModelProbe.probeWithModel(baseURL:bearerToken:)</c>
/// (AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift, lines
/// 1185-1193).
/// </summary>
public interface IManagedRuntimeGatewayProbe
{
    /// <summary>
    /// Probe <c>GET /v1/models</c> on <paramref name="baseUrl"/> with an optional
    /// bearer token. Never throws — a transport failure resolves to
    /// <c>Available = false</c>, matching the Swift <c>catch</c>.
    /// </summary>
    Task<GatewayProbeResult> ProbeAsync(
        Uri baseUrl,
        string? bearerToken,
        CancellationToken cancellationToken = default);
}
