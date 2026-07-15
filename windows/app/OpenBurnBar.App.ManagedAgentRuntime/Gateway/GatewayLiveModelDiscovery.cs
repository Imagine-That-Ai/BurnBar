using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public sealed record GatewayModelDiscoverySourceStatus(
    string RouteId,
    string SourceKind,
    DateTimeOffset RefreshedAt,
    int ModelCount,
    string? Error);

public sealed record GatewayModelDiscoverySnapshot(
    DateTimeOffset GeneratedAt,
    IReadOnlyList<GatewayModelDiscoverySourceStatus> Sources,
    int DiscoveredRouteCount)
{
    public static GatewayModelDiscoverySnapshot Empty { get; } =
        new(DateTimeOffset.MinValue, Array.Empty<GatewayModelDiscoverySourceStatus>(), 0);
}

/// <summary>
/// Proactively refreshes models from loopback OpenAI-compatible servers,
/// Ollama's native catalog, and the protected Factory Droid CLI.
/// </summary>
public sealed class GatewayLiveModelDiscovery : IDisposable
{
    public const int MaximumModelsPerSource = 128;
    public const int MaximumDiscoveredRoutes = 512;
    public const int MaximumResponseBytes = 2 * 1024 * 1024;
    public const int MaximumDisplayNameLength = 256;
    public const int MaximumParallelRefreshes = 4;
    private static readonly TimeSpan DefaultRefreshInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(12);

    private readonly ModelProxyRouter _router;
    private readonly HttpClient _httpClient;
    private readonly IProviderCliProcessRunner? _cliRunner;
    private readonly TimeSpan _refreshInterval;
    private readonly TimeSpan _requestTimeout;
    private readonly Func<DateTimeOffset> _clock;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly object _stateGate = new();
    private Task? _loop;
    private GatewayModelDiscoverySnapshot _snapshot = GatewayModelDiscoverySnapshot.Empty;
    private volatile bool _disposed;

    public GatewayLiveModelDiscovery(
        ModelProxyRouter router,
        HttpClient httpClient,
        IProviderCliProcessRunner? cliRunner = null,
        TimeSpan? refreshInterval = null,
        TimeSpan? requestTimeout = null,
        Func<DateTimeOffset>? clock = null)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _cliRunner = cliRunner;
        _refreshInterval = refreshInterval ?? DefaultRefreshInterval;
        _requestTimeout = requestTimeout ?? DefaultRequestTimeout;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        if (_refreshInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(refreshInterval));
        if (_requestTimeout <= TimeSpan.Zero || _requestTimeout > TimeSpan.FromMinutes(1))
        {
            throw new ArgumentOutOfRangeException(nameof(requestTimeout));
        }
    }

    public GatewayModelDiscoverySnapshot Snapshot()
    {
        lock (_stateGate) return _snapshot;
    }

    public void Start()
    {
        lock (_stateGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _loop ??= Task.Run(() => RefreshLoopAsync(_lifetime.Token));
        }
    }

    public async Task<GatewayModelDiscoverySnapshot> RefreshAsync(
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ModelRoute[] sources = _router.Routes
                .Where(route => route.Discovery is null)
                .Where(IsDiscoverySource)
                .ToArray();
            using var parallelism = new SemaphoreSlim(MaximumParallelRefreshes);
            Task<SourceRefresh>[] tasks = sources.Select(async source =>
            {
                await parallelism.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    return await DiscoverAsync(source, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    parallelism.Release();
                }
            }).ToArray();
            SourceRefresh[] refreshes = await Task.WhenAll(tasks).ConfigureAwait(false);

            var routes = new List<ModelRoute>();
            var statuses = new List<GatewayModelDiscoverySourceStatus>();
            foreach (SourceRefresh refresh in refreshes.OrderBy(item => item.Source.Priority))
            {
                if (refresh.StatusCode is 401 or 403)
                {
                    _router.RecordDiscoveryAuthenticationFailure(refresh.Source, refresh.StatusCode.Value);
                }
                else if (refresh.Error is null && !IsFactoryCli(refresh.Source))
                {
                    _router.RecordDiscoverySuccess(refresh.Source);
                }
                foreach (DiscoveredModel model in refresh.Models)
                {
                    if (routes.Count >= MaximumDiscoveredRoutes) break;
                    routes.Add(RouteFor(refresh.Source, model, refresh.SourceKind, refresh.RefreshedAt));
                }
                statuses.Add(new GatewayModelDiscoverySourceStatus(
                    refresh.Source.Id,
                    refresh.SourceKind,
                    refresh.RefreshedAt,
                    refresh.Models.Count,
                    refresh.Error));
            }

            int acceptedRouteCount = _router.ReplaceDiscoveredRoutes(routes);
            var snapshot = new GatewayModelDiscoverySnapshot(_clock(), statuses.ToArray(), acceptedRouteCount);
            lock (_stateGate) _snapshot = snapshot;
            return snapshot;
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    public void Dispose()
    {
        lock (_stateGate)
        {
            if (_disposed) return;
            _disposed = true;
            _lifetime.Cancel();
        }
    }

    private async Task RefreshLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await RefreshAsync(cancellationToken).ConfigureAwait(false);
                await Task.Delay(_refreshInterval, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                try
                {
                    await Task.Delay(_refreshInterval, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
            }
        }
    }

    private async Task<SourceRefresh> DiscoverAsync(
        ModelRoute source,
        CancellationToken cancellationToken)
    {
        try
        {
            if (IsFactoryCli(source))
            {
                return await DiscoverFactoryAsync(source, cancellationToken).ConfigureAwait(false);
            }
            return await DiscoverHttpAsync(source, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error)
        {
            return SourceRefresh.Failure(source, SourceKind(source), _clock(), SafeError(error));
        }
    }

    private async Task<SourceRefresh> DiscoverHttpAsync(
        ModelRoute source,
        CancellationToken cancellationToken)
    {
        bool ollama = IsOllama(source);
        Uri endpoint = ollama ? OllamaTagsEndpoint(source.Endpoint!) : OpenAiModelsEndpoint(source.Endpoint!);
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        if (!ollama && !string.IsNullOrWhiteSpace(source.BearerToken))
        {
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue(
                "Bearer",
                source.BearerToken.Trim());
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_requestTimeout);
        using HttpResponseMessage response = await _httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            timeout.Token).ConfigureAwait(false);
        DateTimeOffset refreshedAt = _clock();
        if (!response.IsSuccessStatusCode)
        {
            return SourceRefresh.Failure(
                source,
                SourceKind(source),
                refreshedAt,
                $"Discovery failed with HTTP {(int)response.StatusCode}.",
                (int)response.StatusCode);
        }

        byte[] body = await ReadBoundedAsync(response.Content, timeout.Token).ConfigureAwait(false);
        IReadOnlyList<DiscoveredModel> models = ollama
            ? ParseOllamaModels(body)
            : ParseOpenAiModels(body);
        return SourceRefresh.Success(source, SourceKind(source), refreshedAt, models);
    }

    private async Task<SourceRefresh> DiscoverFactoryAsync(
        ModelRoute source,
        CancellationToken cancellationToken)
    {
        if (_cliRunner is null || string.IsNullOrWhiteSpace(source.BearerToken))
        {
            return SourceRefresh.Failure(source, "factory_droid_cli", _clock(), "Factory discovery is not configured.");
        }
        string directory = Path.Combine(Path.GetTempPath(), "openburnbar-discovery-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var request = new ProviderCliProcessRequest(
                "droid",
                new[] { "exec", "--help" },
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["FACTORY_API_KEY"] = source.BearerToken.Trim(),
                },
                directory,
                StandardInput: null,
                _requestTimeout);
            ProviderCliProcessResult result = await _cliRunner.RunAsync(request, cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0)
            {
                return SourceRefresh.Failure(
                    source,
                    "factory_droid_cli",
                    _clock(),
                    $"Factory Droid CLI exited with code {result.ExitCode}.");
            }
            if (Encoding.UTF8.GetByteCount(result.Stdout) > MaximumResponseBytes)
            {
                return SourceRefresh.Failure(
                    source,
                    "factory_droid_cli",
                    _clock(),
                    "Factory Droid CLI catalog exceeds the bounded size limit.");
            }
            IReadOnlyList<DiscoveredModel> models = ParseFactoryModels(result.Stdout);
            return models.Count == 0
                ? SourceRefresh.Failure(source, "factory_droid_cli", _clock(), "Factory Droid CLI returned no models.")
                : SourceRefresh.Success(source, "factory_droid_cli", _clock(), models);
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch { /* best effort */ }
        }
    }

    internal static IReadOnlyList<DiscoveredModel> ParseOpenAiModels(byte[] body)
    {
        using JsonDocument document = JsonDocument.Parse(body);
        if (document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("data", out JsonElement data)
            || data.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<DiscoveredModel>();
        }
        return ParseRows(data.EnumerateArray(), "id", allowCloud: true);
    }

    internal static IReadOnlyList<DiscoveredModel> ParseOllamaModels(byte[] body)
    {
        using JsonDocument document = JsonDocument.Parse(body);
        if (document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("models", out JsonElement models)
            || models.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<DiscoveredModel>();
        }
        return ParseRows(models.EnumerateArray(), "name", allowCloud: false);
    }

    internal static IReadOnlyList<DiscoveredModel> ParseFactoryModels(string help)
    {
        var models = new List<DiscoveredModel>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool inModels = false;
        foreach (string rawLine in help.Split('\n'))
        {
            string line = rawLine.Trim();
            if (line == "Available Models:" || line == "Custom Models:")
            {
                inModels = true;
                continue;
            }
            if (inModels && line.EndsWith(':')
                && line is not "Available Models:" and not "Custom Models:")
            {
                inModels = false;
                continue;
            }
            if (!inModels || line.Length == 0) continue;
            int separator = line.IndexOfAny(new[] { ' ', '\t' });
            if (separator <= 0) continue;
            string id = line[..separator].Trim();
            string candidateName = line[(separator + 1)..].Trim().TrimStart('-', ' ');
            if (!IsValidModelId(id) || !seen.Add(id)) continue;
            string displayName = IsValidDisplayName(candidateName) ? candidateName : id;
            models.Add(new DiscoveredModel(id, displayName));
            if (models.Count >= MaximumModelsPerSource) break;
        }
        return models;
    }

    private static IReadOnlyList<DiscoveredModel> ParseRows(
        JsonElement.ArrayEnumerator rows,
        string idProperty,
        bool allowCloud)
    {
        var models = new List<DiscoveredModel>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (JsonElement row in rows)
        {
            if (row.ValueKind != JsonValueKind.Object
                || !row.TryGetProperty(idProperty, out JsonElement idElement)
                || idElement.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            string id = idElement.GetString()?.Trim() ?? string.Empty;
            if (!IsValidModelId(id)
                || (!allowCloud && id.EndsWith(":cloud", StringComparison.OrdinalIgnoreCase))
                || !seen.Add(id))
            {
                continue;
            }
            string displayName = id;
            foreach (string property in new[] { "display_name", "name", "model" })
            {
                if (row.TryGetProperty(property, out JsonElement display)
                    && display.ValueKind == JsonValueKind.String
                    && IsValidDisplayName(display.GetString()))
                {
                    displayName = display.GetString()!.Trim();
                    break;
                }
            }
            models.Add(new DiscoveredModel(id, displayName));
            if (models.Count >= MaximumModelsPerSource) break;
        }
        return models;
    }

    private static async Task<byte[]> ReadBoundedAsync(
        HttpContent content,
        CancellationToken cancellationToken)
    {
        long? declared = content.Headers.ContentLength;
        if (declared > MaximumResponseBytes)
        {
            throw new InvalidDataException("Discovery response exceeds the bounded size limit.");
        }
        await using Stream stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        byte[] buffer = new byte[16 * 1024];
        while (true)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (output.Length + read > MaximumResponseBytes)
            {
                throw new InvalidDataException("Discovery response exceeds the bounded size limit.");
            }
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static ModelRoute RouteFor(
        ModelRoute source,
        DiscoveredModel model,
        string sourceKind,
        DateTimeOffset refreshedAt)
    {
        string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(model.Id)))
            .ToLowerInvariant()[..16];
        return source with
        {
            Id = source.Id + ":discovered:" + hash,
            Model = model.Id,
            Priority = Math.Min(source.Priority + 1, GatewayRouteConfiguration.MaximumPriority),
            Discovery = new ModelRouteDiscoveryMetadata(
                source.Id,
                sourceKind,
                model.DisplayName,
                refreshedAt),
        };
    }

    private static bool IsDiscoverySource(ModelRoute route) =>
        route.IsExecutable
        && (IsFactoryCli(route)
            || (route.Endpoint is not null
                && GatewayRouteConfiguration.IsEndpointAllowed(route.Endpoint)
                && IsLoopback(route.Endpoint.Host)));

    private static bool IsFactoryCli(ModelRoute route) =>
        route.Endpoint is not null
        && GatewayRouteConfiguration.IsCliEndpointAllowed(route.Endpoint, route.Vendor)
        && (route.Vendor.Equals("factory", StringComparison.OrdinalIgnoreCase)
            || route.Vendor.Equals("factory-droid", StringComparison.OrdinalIgnoreCase));

    private static bool IsOllama(ModelRoute route) =>
        route.Vendor.Equals("ollama", StringComparison.OrdinalIgnoreCase)
        || route.Vendor.Equals("ollama-local", StringComparison.OrdinalIgnoreCase);

    private static bool IsLoopback(string host)
    {
        string normalized = host.Trim().TrimEnd('.');
        return normalized.Equals("localhost", StringComparison.OrdinalIgnoreCase)
            || (IPAddress.TryParse(normalized, out IPAddress? address) && IPAddress.IsLoopback(address));
    }

    private static Uri OllamaTagsEndpoint(Uri source)
    {
        var builder = new UriBuilder(source) { Path = "/api/tags", Query = string.Empty };
        return builder.Uri;
    }

    private static Uri OpenAiModelsEndpoint(Uri source)
    {
        string path = source.AbsolutePath.TrimEnd('/');
        const string completionSuffix = "/chat/completions";
        string modelsPath = path.EndsWith(completionSuffix, StringComparison.OrdinalIgnoreCase)
            ? path[..^completionSuffix.Length] + "/models"
            : path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
                ? path + "/models"
                : "/v1/models";
        var builder = new UriBuilder(source) { Path = modelsPath, Query = string.Empty };
        return builder.Uri;
    }

    private static string SourceKind(ModelRoute route) =>
        IsFactoryCli(route)
            ? "factory_droid_cli"
            : IsOllama(route)
                ? "local_ollama_models_endpoint"
                : "local_openai_models_endpoint";

    private static bool IsValidModelId(string id) =>
        id.Length is > 0 and <= GatewayRouteConfiguration.MaximumModelLength
        && !id.Any(char.IsControl);

    private static bool IsValidDisplayName(string? displayName) =>
        !string.IsNullOrWhiteSpace(displayName)
        && displayName.Trim().Length <= MaximumDisplayNameLength
        && !displayName.Any(char.IsControl);

    private static string SafeError(Exception error) => error switch
    {
        OperationCanceledException => "Discovery timed out.",
        InvalidDataException => error.Message,
        JsonException => "Discovery returned invalid JSON.",
        _ => "Discovery source is unavailable.",
    };

    internal sealed record DiscoveredModel(string Id, string DisplayName);

    private sealed record SourceRefresh(
        ModelRoute Source,
        string SourceKind,
        DateTimeOffset RefreshedAt,
        IReadOnlyList<DiscoveredModel> Models,
        string? Error,
        int? StatusCode)
    {
        public static SourceRefresh Success(
            ModelRoute source,
            string sourceKind,
            DateTimeOffset refreshedAt,
            IReadOnlyList<DiscoveredModel> models) =>
            new(source, sourceKind, refreshedAt, models, null, null);

        public static SourceRefresh Failure(
            ModelRoute source,
            string sourceKind,
            DateTimeOffset refreshedAt,
            string error,
            int? statusCode = null) =>
            new(source, sourceKind, refreshedAt, Array.Empty<DiscoveredModel>(), error, statusCode);
    }
}
