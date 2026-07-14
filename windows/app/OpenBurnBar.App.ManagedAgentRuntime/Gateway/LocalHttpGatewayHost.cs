using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// Configurable local OpenAI-compatible gateway for the Windows F2 runtime.
///
/// The host owns transport and request safety; route selection and provider
/// execution are injected. That keeps the app's multi-client boundary real
/// while allowing each provider adapter to remain independently testable.
/// </summary>
public sealed class LocalHttpGatewayHost : IAsyncDisposable
{
    private readonly HttpListener _listener = new();
    private readonly GatewayListenerOptions _listenerOptions;
    private readonly ModelProxyRouter _router;
    private readonly IModelCompletionExecutor _executor;
    private readonly GatewayLiveModelDiscovery? _discovery;
    private readonly byte[]? _accessToken;
    private readonly GatewayRateLimiter _rateLimiter;
    private readonly GatewayRateLimiter? _unauthenticatedLoopbackRateLimiter;
    private readonly int _maxRequestBytes;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    /// <summary>
    /// Creates an honest local gateway with a single unconfigured route. Health
    /// and model discovery work immediately; completion requests fail closed
    /// until a real provider route is supplied by composition.
    /// </summary>
    public LocalHttpGatewayHost(int port = 8642)
        : this(
            "127.0.0.1",
            port,
            new ModelProxyRouter(new[]
            {
                new ModelRoute("openburnbar-local", "openburnbar", "openburnbar-local", 0, true),
            }),
            new DelegateModelCompletionExecutor(
                (_, _, _) => Task.FromResult(new ModelCompletionResult(
                    503,
                    Array.Empty<byte>(),
                    "application/json",
                    false))))
    {
    }

    public LocalHttpGatewayHost(
        int port,
        ModelProxyRouter router,
        IModelCompletionExecutor executor,
        string? accessToken = null,
        int maxRequestBytes = 4 * 1024 * 1024,
        GatewayLiveModelDiscovery? discovery = null,
        GatewayRateLimiter? rateLimiter = null,
        GatewayRateLimiter? unauthenticatedLoopbackRateLimiter = null)
        : this(
            "127.0.0.1",
            port,
            router,
            executor,
            accessToken,
            maxRequestBytes,
            discovery,
            rateLimiter,
            unauthenticatedLoopbackRateLimiter)
    {
    }

    public LocalHttpGatewayHost(
        string host,
        int port,
        ModelProxyRouter router,
        IModelCompletionExecutor executor,
        string? accessToken = null,
        int maxRequestBytes = 4 * 1024 * 1024,
        GatewayLiveModelDiscovery? discovery = null,
        GatewayRateLimiter? rateLimiter = null,
        GatewayRateLimiter? unauthenticatedLoopbackRateLimiter = null)
    {
        if (maxRequestBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxRequestBytes));
        }

        _listenerOptions = GatewayListenerOptions.Resolve(
            configuredEnabled: true,
            configuredHost: host,
            configuredPort: port);
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _executor = executor ?? throw new ArgumentNullException(nameof(executor));
        _discovery = discovery;
        _maxRequestBytes = maxRequestBytes;
        _accessToken = string.IsNullOrWhiteSpace(accessToken)
            ? null
            : Encoding.UTF8.GetBytes(accessToken.Trim());
        _rateLimiter = rateLimiter ?? new GatewayRateLimiter(GatewayRateLimitConfiguration.Default);
        _unauthenticatedLoopbackRateLimiter = _accessToken is null
            ? unauthenticatedLoopbackRateLimiter
                ?? new GatewayRateLimiter(GatewayRateLimitConfiguration.UnauthenticatedLoopbackDefault)
            : null;
    }

    public string Host => _listenerOptions.Host;

    public int Port => _listenerOptions.Port;

    public Uri BaseAddress => _listenerOptions.BaseAddress;

    public bool IsRunning => _loop is { IsCompleted: false };

    public void Start()
    {
        if (_loop is not null)
        {
            return;
        }

        _listener.Prefixes.Add(BaseAddress.AbsoluteUri);
        _listener.Start();
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { /* best effort */ }
        try { _listener.Stop(); } catch { /* best effort */ }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { /* best effort */ }
        }

        _listener.Close();
        _cts?.Dispose();
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync().ConfigureAwait(false);
            }
            catch (HttpListenerException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }

            _ = Task.Run(() => HandleAsync(context, cancellationToken), cancellationToken);
        }
    }

    private async Task HandleAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        try
        {
            string path = context.Request.Url?.AbsolutePath ?? "/";
            if (context.Request.HttpMethod.Equals("GET", StringComparison.OrdinalIgnoreCase)
                && path is "/" or "/health" or "/v1/health")
            {
                await WriteJsonAsync(context.Response, 200, new
                {
                    ok = true,
                    service = "openburnbar-local-gateway",
                    finishLine = "F2",
                    routeCount = _router.Routes.Count,
                }).ConfigureAwait(false);
                return;
            }

            if (!IsAuthorized(context.Request))
            {
                await WriteJsonAsync(context.Response, 401, new
                {
                    error = new { type = "authentication_error", message = "Gateway authentication is required." },
                }).ConfigureAwait(false);
                return;
            }

            GatewayRateLimitDecision limit = _rateLimiter.CheckLimit(RateLimitClientKey(context.Request));
            if (!limit.IsAllowed)
            {
                await WriteRateLimitResponseAsync(context.Response, limit.RetryAfterSeconds)
                    .ConfigureAwait(false);
                return;
            }

            if (_unauthenticatedLoopbackRateLimiter is not null)
            {
                GatewayRateLimitDecision anonymousLimit =
                    _unauthenticatedLoopbackRateLimiter.CheckLimit("unauthenticated-loopback");
                if (!anonymousLimit.IsAllowed)
                {
                    await WriteRateLimitResponseAsync(context.Response, anonymousLimit.RetryAfterSeconds)
                        .ConfigureAwait(false);
                    return;
                }
            }

            if (context.Request.HttpMethod.Equals("GET", StringComparison.OrdinalIgnoreCase)
                && path is "/v1/models" or "/models")
            {
                GatewayModelDiscoverySnapshot? discovery = _discovery?.Snapshot();
                var models = _router.Routes
                    .OrderBy(route => route.Priority)
                    .Select(route =>
                    {
                        ModelRouteHealthRecord? failure = _router.ActiveHealthFailure(route);
                        return new
                        {
                            id = route.Model,
                            @object = "model",
                            owned_by = route.Vendor,
                            healthy = route.Healthy && failure is null,
                            route_eligible = route.IsExecutable && failure is null,
                            provider_id = route.Vendor,
                            provider_name = route.Vendor,
                            display_name = route.Discovery?.DisplayName ?? route.Model,
                            discovered = route.Discovery is not null,
                            discovery_source = route.Discovery?.SourceKind,
                            source_route_id = route.Discovery?.SourceRouteId,
                            refreshed_at = route.Discovery?.RefreshedAt,
                            health_failure = failure?.FailureKind.ToString(),
                            blocked_until = failure?.BlockedUntil,
                        };
                    });
                await WriteJsonAsync(context.Response, 200, new
                {
                    @object = "list",
                    data = models,
                    discovery = discovery is null ? null : new
                    {
                        generated_at = discovery.GeneratedAt,
                        discovered_route_count = discovery.DiscoveredRouteCount,
                        sources = discovery.Sources.Select(source => new
                        {
                            route_id = source.RouteId,
                            source_kind = source.SourceKind,
                            refreshed_at = source.RefreshedAt,
                            model_count = source.ModelCount,
                            error = source.Error,
                        }),
                    },
                })
                    .ConfigureAwait(false);
                return;
            }

            if (context.Request.HttpMethod.Equals("GET", StringComparison.OrdinalIgnoreCase)
                && path is "/v1/metrics" or "/metrics")
            {
                GatewayTelemetrySnapshot telemetry = _router.TelemetryStore.Snapshot();
                var recentRoutes = _router.TelemetryStore.Recent().Select(entry => new
                {
                    id = entry.Id,
                    started_at = entry.StartedAt,
                    completed_at = entry.CompletedAt,
                    duration_milliseconds = entry.DurationMilliseconds,
                    request_path = entry.RequestPath,
                    client_model = entry.ClientModel,
                    routed_model = entry.RoutedModel,
                    route_id = entry.RouteId,
                    vendor = entry.Vendor,
                    account_id = entry.AccountId,
                    canonical_model_id = entry.CanonicalModelId,
                    format_family = entry.FormatFamily,
                    endpoint_profile_id = entry.EndpointProfileId,
                    degraded = entry.Degraded,
                    succeeded = entry.Succeeded,
                    status_code = entry.StatusCode,
                    streamed = entry.Streamed,
                    usage = entry.Usage,
                });
                await WriteJsonAsync(context.Response, 200, new
                {
                    routes = _router.SnapshotMetrics()
                        .ToDictionary(pair => pair.Key, pair => pair.Value),
                    health = _router.SnapshotHealth()
                        .ToDictionary(pair => pair.Key, pair => pair.Value),
                    telemetry = new
                    {
                        retained_requests = telemetry.RetainedRequests,
                        successes = telemetry.Successes,
                        failures = telemetry.Failures,
                        degrades = telemetry.Degrades,
                        input_tokens = telemetry.InputTokens,
                        output_tokens = telemetry.OutputTokens,
                        cache_creation_tokens = telemetry.CacheCreationTokens,
                        cache_read_tokens = telemetry.CacheReadTokens,
                        reasoning_tokens = telemetry.ReasoningTokens,
                    },
                    recent_routes = recentRoutes,
                }).ConfigureAwait(false);
                return;
            }

            if (context.Request.HttpMethod.Equals("POST", StringComparison.OrdinalIgnoreCase)
                && path is "/v1/chat/completions" or "/chat/completions")
            {
                await HandleCompletionAsync(context, cancellationToken).ConfigureAwait(false);
                return;
            }

            await WriteJsonAsync(context.Response, 404, new
            {
                error = new { type = "not_found", message = "The requested gateway route does not exist." },
            }).ConfigureAwait(false);
        }
        catch (RequestTooLargeException error)
        {
            await WriteJsonAsync(context.Response, 413, new
            {
                error = new { type = "request_too_large", message = error.Message },
            }).ConfigureAwait(false);
        }
        catch (JsonException)
        {
            await WriteJsonAsync(context.Response, 400, new
            {
                error = new { type = "invalid_request", message = "Request body must be valid JSON." },
            }).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            try { context.Response.Abort(); } catch { /* best effort */ }
        }
        catch
        {
            try { context.Response.Abort(); } catch { /* best effort */ }
        }
    }

    private async Task HandleCompletionAsync(
        HttpListenerContext context,
        CancellationToken cancellationToken)
    {
        byte[] requestBody = await ReadBodyAsync(context.Request, cancellationToken).ConfigureAwait(false);
        using JsonDocument document = JsonDocument.Parse(requestBody);
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("model", out JsonElement modelElement)
            || modelElement.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(modelElement.GetString()))
        {
            await WriteJsonAsync(context.Response, 400, new
            {
                error = new { type = "invalid_request", message = "A non-empty model is required." },
            }).ConfigureAwait(false);
            return;
        }

        string model = modelElement.GetString()!;
        bool allowDegrade = root.TryGetProperty("openburnbar_allow_degrade", out JsonElement degrade)
            && degrade.ValueKind == JsonValueKind.True;
        DateTimeOffset startedAt = DateTimeOffset.UtcNow;
        ModelRouteDecision decision = _router.SelectForModel(model, allowDegrade);
        if (decision.FailedClosed)
        {
            RecordTelemetry(
                startedAt,
                model,
                decision,
                new ModelCompletionResult(503, Array.Empty<byte>(), "application/json", false));
            await WriteJsonAsync(context.Response, 503, new
            {
                error = new { type = "model_unavailable", message = $"No healthy route is available for '{model}'." },
            }).ConfigureAwait(false);
            return;
        }

        ModelCompletionResult result = await _executor
            .ExecuteAsync(
                decision.Route,
                decision.Degraded ? RewriteModel(requestBody, decision.Route.Model) : requestBody,
                cancellationToken)
            .ConfigureAwait(false);
        _router.RecordOutcome(decision.Route, result, decision.Degraded);
        RecordTelemetry(startedAt, model, decision, result);

        if (!result.Succeeded)
        {
            int status = result.StatusCode is >= 400 and <= 599 ? result.StatusCode : 502;
            await WriteJsonAsync(context.Response, status, new
            {
                error = new
                {
                    type = "upstream_error",
                    message = $"Provider route '{decision.Route.Id}' did not complete the request.",
                    degraded = decision.Degraded,
                },
            }).ConfigureAwait(false);
            return;
        }

        await WriteBytesAsync(context.Response, result.StatusCode, result.ContentType, result.Body)
            .ConfigureAwait(false);
    }

    private void RecordTelemetry(
        DateTimeOffset startedAt,
        string clientModel,
        ModelRouteDecision decision,
        ModelCompletionResult result)
    {
        DateTimeOffset completedAt = DateTimeOffset.UtcNow;
        ModelRoute route = decision.Route;
        ModelRouteRoutingMetadata metadata = route.Routing ?? new ModelRouteRoutingMetadata();
        _router.TelemetryStore.Append(new GatewayRouteLogEntry(
            Guid.NewGuid().ToString("N"),
            startedAt,
            completedAt,
            Math.Max((long)(completedAt - startedAt).TotalMilliseconds, 0),
            "/v1/chat/completions",
            clientModel,
            route.Model,
            route.Id,
            route.Vendor,
            metadata.CredentialSlotId,
            metadata.CanonicalModelId,
            metadata.FormatFamily ?? route.Vendor,
            metadata.EndpointProfileId,
            decision.Degraded,
            result.Succeeded,
            result.StatusCode,
            result.ContentType.StartsWith("text/event-stream", StringComparison.OrdinalIgnoreCase),
            result.Succeeded ? GatewayUsageParser.Parse(result) : null));
    }

    private byte[] RewriteModel(byte[] requestBody, string model)
    {
        JsonNode? parsed = JsonNode.Parse(requestBody);
        if (parsed is not JsonObject request)
        {
            throw new JsonException("Completion request must be a JSON object.");
        }
        request["model"] = model;
        byte[] rewritten = JsonSerializer.SerializeToUtf8Bytes(request);
        if (rewritten.Length > _maxRequestBytes)
        {
            throw new RequestTooLargeException(
                $"Request body exceeds the {_maxRequestBytes}-byte gateway limit after model substitution.");
        }
        return rewritten;
    }

    private bool IsAuthorized(HttpListenerRequest request)
    {
        if (_accessToken is null)
        {
            return true;
        }

        string? header = request.Headers["Authorization"];
        const string prefix = "Bearer ";
        if (header is null || !header.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        byte[] actual = Encoding.UTF8.GetBytes(header[prefix.Length..].Trim());
        return CryptographicOperations.FixedTimeEquals(actual, _accessToken);
    }

    private string RateLimitClientKey(HttpListenerRequest request)
    {
        if (_accessToken is null)
        {
            return "anonymous";
        }

        string? header = request.Headers["Authorization"];
        const string prefix = "Bearer ";
        string token = header is not null && header.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? header[prefix.Length..].Trim()
            : string.Empty;
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(token));
        return $"token:{Convert.ToHexString(digest.AsSpan(0, 12)).ToLowerInvariant()}";
    }

    private async Task<byte[]> ReadBodyAsync(HttpListenerRequest request, CancellationToken cancellationToken)
    {
        if (request.ContentLength64 > _maxRequestBytes)
        {
            throw new RequestTooLargeException($"Request body exceeds {_maxRequestBytes} bytes.");
        }

        using var output = new MemoryStream();
        byte[] buffer = new byte[Math.Min(32 * 1024, _maxRequestBytes)];
        int total = 0;
        while (true)
        {
            int read = await request.InputStream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            total += read;
            if (total > _maxRequestBytes)
            {
                throw new RequestTooLargeException($"Request body exceeds {_maxRequestBytes} bytes.");
            }

            output.Write(buffer, 0, read);
        }

        return output.ToArray();
    }

    private static async Task WriteJsonAsync(HttpListenerResponse response, int status, object body)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(body);
        await WriteBytesAsync(response, status, "application/json; charset=utf-8", bytes).ConfigureAwait(false);
    }

    private static async Task WriteRateLimitResponseAsync(
        HttpListenerResponse response,
        double retryAfterSeconds)
    {
        response.Headers["Retry-After"] = Math.Max((int)Math.Ceiling(retryAfterSeconds), 1)
            .ToString(CultureInfo.InvariantCulture);
        await WriteJsonAsync(response, 429, new
        {
            error = new { type = "rate_limit_error", message = "Gateway rate limit exceeded." },
        }).ConfigureAwait(false);
    }

    private static async Task WriteBytesAsync(
        HttpListenerResponse response,
        int status,
        string contentType,
        byte[] bytes)
    {
        response.StatusCode = status;
        response.ContentType = contentType;
        response.ContentLength64 = bytes.Length;
        await response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
        response.OutputStream.Close();
    }

    private sealed class RequestTooLargeException : Exception
    {
        public RequestTooLargeException(string message) : base(message) { }
    }
}
