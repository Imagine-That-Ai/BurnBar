using System;
using System.Text.Json;
using System.Threading.Tasks;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// The pure bridge route dispatcher.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   respond(to:on:) route switch + handleRefreshRequest + handlePeriodRequest.
//
// Given a parsed request + runtime state (+ injected refresh/period handlers),
// this produces the BridgeResponse the socket adapter writes back. Every
// state-bearing route is bridge-token gated; OPTIONS and the brand logo are not.

public sealed class BridgeRouter
{
    private readonly BridgeRuntimeState _state;
    private readonly BridgeAssets _assets;
    private readonly Func<Task<bool>>? _refreshHandler;
    private readonly Func<SmartHubTimePeriod, Task>? _periodHandler;

    public BridgeRouter(
        BridgeRuntimeState state,
        BridgeAssets? assets = null,
        Func<Task<bool>>? refreshHandler = null,
        Func<SmartHubTimePeriod, Task>? periodHandler = null)
    {
        _state = state ?? throw new ArgumentNullException(nameof(state));
        _assets = assets ?? BridgeAssets.Placeholder;
        _refreshHandler = refreshHandler;
        _periodHandler = periodHandler;
    }

    /// Convenience: parse raw request bytes and dispatch. Mirrors the Swift
    /// server's parse-then-route path, including the 404-on-non-UTF8 and
    /// 400-on-malformed-request-line behaviors.
    public async Task<BridgeResponse> HandleAsync(byte[] requestBytes)
    {
        var parsed = BridgeHttpParser.Parse(requestBytes);
        if (parsed.Request is null)
        {
            return parsed.Error == BridgeParseError.BadRequest
                ? BridgeResponse.Status(400)
                : BridgeResponse.Status(404);
        }
        return await DispatchAsync(parsed.Request).ConfigureAwait(false);
    }

    public async Task<BridgeResponse> DispatchAsync(BridgeRequest request)
    {
        var method = request.Method;
        var pathOnly = request.PathOnly;
        var rawPath = request.RawPath;
        var authHeader = request.Header("Authorization");
        var token = _state.BridgeAccessToken;

        if (method == "OPTIONS")
        {
            return BridgeResponse.Status(204);
        }

        if (method == "GET" && pathOnly == "/brand-logo.svg")
        {
            return BridgeResponse.Svg(_assets.BrandLogoSvg);
        }

        bool Authorized() => BridgeAccessControl.IsAuthorized(rawPath, authHeader, token);

        switch ((method, pathOnly))
        {
            case ("GET", "/"):
            case ("GET", ""):
                if (!Authorized())
                {
                    return BridgeResponse.Status(401);
                }
                return BridgeResponse.Redirect(BridgeAccessControl.SecuredPath("/render.html", token));

            case ("GET", "/render.html"):
                if (!Authorized())
                {
                    return BridgeResponse.Status(401);
                }
                return BridgeResponse.Html(_assets.Html);

            case ("GET", "/state.json"):
                if (!Authorized())
                {
                    return BridgeResponse.Status(401);
                }
                // Record the poll BEFORE rendering so the watchdog sees the
                // heartbeat the moment it arrives.
                _state.RecordClientPoll();
                return BridgeResponse.Json(_state.RenderStateJson());

            case ("POST", "/refresh"):
                if (!Authorized())
                {
                    return BridgeResponse.Status(401);
                }
                return await HandleRefreshAsync().ConfigureAwait(false);

            case ("POST", "/period"):
                if (!Authorized())
                {
                    return BridgeResponse.Status(401);
                }
                return await HandlePeriodAsync(rawPath, request.Body).ConfigureAwait(false);

            case ("POST", "/voice-refresh"):
                if (!Authorized())
                {
                    return BridgeResponse.Status(401);
                }
                return BridgeResponse.Json("{\"ok\":true,\"voice\":\"queued\"}");

            default:
                return BridgeResponse.Status(404);
        }
    }

    /// Parity: Swift `handleRefreshRequest` — flips refreshing on, awaits the
    /// injected fetch (or best-effort version bump), reports the version, then
    /// flips refreshing off (the flip-off bump is NOT reflected in the reported
    /// version, matching the Swift defer-after-send ordering).
    private async Task<BridgeResponse> HandleRefreshAsync()
    {
        _state.SetRefreshing(true);
        try
        {
            bool succeeded;
            if (_refreshHandler is not null)
            {
                succeeded = await _refreshHandler().ConfigureAwait(false);
            }
            else
            {
                _state.BumpRefresh();
                succeeded = true;
            }

            return BridgeResponse.Json(
                $"{{\"ok\":{(succeeded ? "true" : "false")},\"version\":{_state.RefreshVersion},\"refreshing\":false}}");
        }
        finally
        {
            _state.SetRefreshing(false);
        }
    }

    /// Parity: Swift `handlePeriodRequest` — period from `?p=` query OR JSON
    /// body `{"period":"…"}`; 400 when neither yields a valid period.
    private async Task<BridgeResponse> HandlePeriodAsync(string rawPath, byte[]? body)
    {
        SmartHubTimePeriod? period = null;

        var queryValue = BridgeAccessControl.QueryValue(rawPath, "p");
        if (queryValue is not null && SmartHubTimePeriodExtensions.Parse(queryValue) is { } fromQuery)
        {
            period = fromQuery;
        }
        else if (body is not null && ParsePeriodBody(body) is { } fromBody)
        {
            period = fromBody;
        }

        if (period is not { } resolved)
        {
            return BridgeResponse.Status(400);
        }

        if (_periodHandler is not null)
        {
            await _periodHandler(resolved).ConfigureAwait(false);
        }
        // Mirror the period locally so /state.json reports the requested value
        // even when no handler is wired.
        _state.UpdateTimePeriod(resolved);

        return BridgeResponse.Json(
            $"{{\"ok\":true,\"timePeriod\":\"{resolved.RawValue()}\",\"version\":{_state.RefreshVersion}}}");
    }

    private static SmartHubTimePeriod? ParsePeriodBody(byte[] body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                doc.RootElement.TryGetProperty("period", out var value) &&
                value.ValueKind == JsonValueKind.String)
            {
                return SmartHubTimePeriodExtensions.Parse(value.GetString());
            }
        }
        catch (JsonException)
        {
            // Malformed body -> treated as "no period" (Swift try? path -> 400).
        }
        return null;
    }
}
