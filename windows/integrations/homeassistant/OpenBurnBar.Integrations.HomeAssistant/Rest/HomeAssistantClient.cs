using System;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.Integrations.HomeAssistant.Models;

namespace OpenBurnBar.Integrations.HomeAssistant.Rest;

// Portable Home Assistant REST client orchestration.
//
// Parity: AgentLens/Services/HomeAssistant/HomeAssistantClient.swift
//   probe / validateToken / listMediaPlayers / upsertAutomation / callService /
//   triggerWebhook + the static haEndpoint(base:path:) builder.
//
// Every network byte flows through the injected IHomeAssistantHttpTransport, so
// the whole surface is exercised off-Windows against recorded fixtures.

public sealed class HomeAssistantClient
{
    private readonly IHomeAssistantHttpTransport _transport;
    private readonly double _timeout;

    public HomeAssistantClient(IHomeAssistantHttpTransport transport, double timeoutSeconds = 10)
    {
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _timeout = timeoutSeconds;
    }

    /// Builds an HA endpoint URL preserving any trailing slash in `path`.
    /// Parity: Swift `HomeAssistantClient.haEndpoint(base:path:)`.
    public static string Endpoint(string baseUrl, string path)
    {
        var trimmedBase = baseUrl.EndsWith("/", StringComparison.Ordinal)
            ? baseUrl.Substring(0, baseUrl.Length - 1)
            : baseUrl;
        var trimmedPath = path.StartsWith("/", StringComparison.Ordinal)
            ? path.Substring(1)
            : path;
        return $"{trimmedBase}/{trimmedPath}";
    }

    /// Unauthenticated `/api/` probe. Parity: Swift `probe(baseURL:)` — any
    /// transport error maps to Unreachable; otherwise MapProbe classifies the
    /// status + X-HA-Version header.
    public async Task<HomeAssistantProbeStatus> ProbeAsync(string baseUrl, CancellationToken cancellationToken = default)
    {
        var request = new HaHttpRequest(
            "GET",
            Endpoint(baseUrl, "api/"),
            Array.Empty<HaHeader>(),
            null,
            _timeout);
        try
        {
            var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var version = response.Header("X-HA-Version");
            return HomeAssistantResponseMapper.MapProbe(response.StatusCode, version);
        }
        catch (HomeAssistantClientException ex)
        {
            var message = ex.Kind == HomeAssistantClientErrorKind.Timeout ? "Timed out" : ex.Detail;
            return new HomeAssistantProbeStatus.Unreachable(string.IsNullOrEmpty(message) ? ex.Message : message);
        }
    }

    /// Validates a long-lived access token against `/api/`. Parity: Swift
    /// `validateToken(baseURL:accessToken:)`, including the tolerant body sanity
    /// check that only rejects an explicitly non-JSON body.
    public async Task ValidateTokenAsync(string baseUrl, string accessToken, CancellationToken cancellationToken = default)
    {
        var request = new HaHttpRequest(
            "GET",
            Endpoint(baseUrl, "api/"),
            new[]
            {
                new HaHeader("Authorization", $"Bearer {accessToken}"),
                new HaHeader("Content-Type", "application/json"),
            },
            null,
            _timeout);

        var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        HomeAssistantResponseMapper.EnsureSuccess(response.StatusCode, response.Body, "/api/");

        var body = response.Body;
        if (!body.Contains("API running", StringComparison.Ordinal) &&
            !body.Contains("API is running", StringComparison.Ordinal))
        {
            if (!IsJson(body))
            {
                var prefix = body.Length <= 120 ? body : body.Substring(0, 120);
                throw HomeAssistantClientException.Decoding($"unexpected /api/ body: {prefix}");
            }
        }
    }

    /// Fetches every entity and projects the `media_player.*` rows.
    /// Parity: Swift `listMediaPlayers(baseURL:accessToken:)`.
    public async Task<IReadOnlyList<HaMediaPlayer>> ListMediaPlayersAsync(
        string baseUrl,
        string accessToken,
        CancellationToken cancellationToken = default)
    {
        var request = new HaHttpRequest(
            "GET",
            Endpoint(baseUrl, "api/states"),
            new[] { new HaHeader("Authorization", $"Bearer {accessToken}") },
            null,
            _timeout);

        var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        HomeAssistantResponseMapper.EnsureSuccess(response.StatusCode, response.Body, "/api/states");

        var states = HomeAssistantStateProjection.DecodeStates(response.Body);
        return HomeAssistantStateProjection.ProjectMediaPlayers(states);
    }

    /// Creates or updates an HA automation by ID. Parity: Swift
    /// `upsertAutomation(...)`. `jsonBody` is the pre-serialized automation
    /// config the caller assembled.
    public async Task UpsertAutomationAsync(
        string baseUrl,
        string accessToken,
        string automationId,
        string jsonBody,
        CancellationToken cancellationToken = default)
    {
        var request = new HaHttpRequest(
            "POST",
            Endpoint(baseUrl, $"api/config/automation/config/{automationId}"),
            JsonPostHeaders(accessToken),
            Encoding.UTF8.GetBytes(jsonBody),
            _timeout);

        var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        HomeAssistantResponseMapper.EnsureSuccess(response.StatusCode, response.Body, "/api/config/automation/config");
    }

    /// Triggers any HA service. Parity: Swift `callService(...)`.
    public async Task CallServiceAsync(
        string baseUrl,
        string accessToken,
        string domain,
        string service,
        string jsonBody,
        CancellationToken cancellationToken = default)
    {
        var path = $"api/services/{domain}/{service}";
        var request = new HaHttpRequest(
            "POST",
            Endpoint(baseUrl, path),
            JsonPostHeaders(accessToken),
            Encoding.UTF8.GetBytes(jsonBody),
            _timeout);

        var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        HomeAssistantResponseMapper.EnsureSuccess(response.StatusCode, response.Body, $"/api/services/{domain}/{service}");
    }

    /// POSTs a payload to a local webhook URL. Parity: Swift `triggerWebhook(_:payload:)`.
    public async Task TriggerWebhookAsync(string webhookUrl, byte[]? payload, CancellationToken cancellationToken = default)
    {
        var request = new HaHttpRequest(
            "POST",
            webhookUrl,
            new[] { new HaHeader("Content-Type", "application/json") },
            payload,
            _timeout);

        var response = await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        HomeAssistantResponseMapper.EnsureSuccess(response.StatusCode, response.Body, "/api/webhook");
    }

    private static HaHeader[] JsonPostHeaders(string accessToken) => new[]
    {
        new HaHeader("Authorization", $"Bearer {accessToken}"),
        new HaHeader("Content-Type", "application/json"),
    };

    private static bool IsJson(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return false;
        }
        try
        {
            using var _ = JsonDocument.Parse(body);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}
