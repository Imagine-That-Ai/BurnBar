using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>
/// F2 model-proxy router with cross-vendor degrade policy and route metrics.
/// Production path for gateway routing decisions (not settings-only).
/// </summary>
public sealed class ModelProxyRouter
{
    private readonly IReadOnlyList<ModelRoute> _configuredRoutes;
    private IReadOnlyList<ModelRoute> _routes;
    private readonly ModelRouteHealthStore _healthStore;
    private readonly CrossVendorDegradePolicy _degradePolicy;
    private readonly GatewayRouteTelemetryStore _telemetryStore;
    private readonly object _gate = new();
    private readonly object _routesGate = new();
    private readonly Dictionary<string, RouteMetrics> _metrics = new(StringComparer.Ordinal);

    public ModelProxyRouter(
        IReadOnlyList<ModelRoute> routes,
        ModelRouteHealthStore? healthStore = null,
        CrossVendorDegradePolicy? degradePolicy = null,
        GatewayRouteTelemetryStore? telemetryStore = null)
    {
        ArgumentNullException.ThrowIfNull(routes);
        if (routes.Count == 0)
        {
            throw new ArgumentException("At least one route is required.", nameof(routes));
        }
        _configuredRoutes = routes.ToArray();
        _routes = _configuredRoutes;
        _healthStore = healthStore ?? new ModelRouteHealthStore();
        _degradePolicy = degradePolicy ?? CrossVendorDegradePolicy.Disabled;
        _telemetryStore = telemetryStore ?? new GatewayRouteTelemetryStore();
    }

    /// <summary>Immutable route view used by gateway model discovery.</summary>
    public IReadOnlyList<ModelRoute> Routes
    {
        get
        {
            lock (_routesGate) return _routes;
        }
    }

    /// <summary>
    /// Atomically replaces live-discovered routes while preserving the durable
    /// configured catalog. Discovered rows can never shadow a configured route.
    /// </summary>
    public int ReplaceDiscoveredRoutes(IEnumerable<ModelRoute> discoveredRoutes)
    {
        ArgumentNullException.ThrowIfNull(discoveredRoutes);
        ModelRoute[] configured = _configuredRoutes.ToArray();
        var routeIds = new HashSet<string>(configured.Select(route => route.Id), StringComparer.OrdinalIgnoreCase);
        var modelKeys = new HashSet<string>(configured.Select(ModelKey), StringComparer.OrdinalIgnoreCase);
        var accepted = new List<ModelRoute>();
        foreach (ModelRoute route in discoveredRoutes.Take(513))
        {
            ArgumentNullException.ThrowIfNull(route);
            if (accepted.Count >= 512) break;
            if (route.Discovery is null || !route.IsExecutable) continue;
            if (!routeIds.Add(route.Id) || !modelKeys.Add(ModelKey(route))) continue;
            accepted.Add(route);
        }

        lock (_routesGate)
        {
            _routes = configured.Concat(accepted).ToArray();
        }
        return accepted.Count;
    }

    /// <summary>Metadata-only route and token-usage history for authenticated diagnostics.</summary>
    public GatewayRouteTelemetryStore TelemetryStore => _telemetryStore;

    /// <summary>
    /// Select the best healthy route for <paramref name="vendorPreference"/>.
    /// Degrades to the next healthy route when preferred vendor is unhealthy.
    /// </summary>
    public ModelRouteDecision Select(string? vendorPreference = null)
        => SelectCore(vendorPreference, recordSelection: true);

    private ModelRouteDecision SelectCore(string? vendorPreference, bool recordSelection)
    {
        IReadOnlyList<ModelRoute> routes = Routes;
        IReadOnlyList<RankedModelRoute> ranked = ModelRouteScorecard.Rank(
            routes.Where(IsRouteEligible),
            vendorPreference);
        foreach (RankedModelRoute entry in ranked)
        {
            ModelRoute route = entry.Route;
            bool degraded = !string.IsNullOrWhiteSpace(vendorPreference)
                && !string.Equals(route.Vendor, vendorPreference, StringComparison.OrdinalIgnoreCase);
            if (recordSelection)
            {
                Record(route.Id, success: true, degraded);
            }

            return new ModelRouteDecision(route, Degraded: degraded, Score: entry.Breakdown);
        }

        // Fail closed: no healthy route.
        ModelRoute first = routes.OrderBy(r => r.Priority).First();
        if (recordSelection)
        {
            Record(first.Id, success: false, degraded: false);
        }

        return new ModelRouteDecision(first, Degraded: false, FailedClosed: true);
    }

    /// <summary>
    /// Select a route for a requested model. Exact model matches are preferred;
    /// healthy fallback routes are allowed only when <paramref name="allowDegrade"/>
    /// is true. This keeps an unavailable model from silently becoming a
    /// different model unless the caller explicitly opted into degradation.
    /// </summary>
    public ModelRouteDecision SelectForModel(string model, bool allowDegrade = false)
    {
        if (string.IsNullOrWhiteSpace(model))
        {
            throw new ArgumentException("A model is required.", nameof(model));
        }

        IReadOnlyList<ModelRoute> routes = Routes;
        ModelRoute[] exact = routes
            .Where(route => string.Equals(route.Model, model, StringComparison.OrdinalIgnoreCase))
            .OrderBy(route => route.Priority)
            .ToArray();
        RankedModelRoute? healthyExact = ModelRouteScorecard.Rank(exact.Where(IsRouteEligible)).FirstOrDefault();
        if (healthyExact is not null)
        {
            return new ModelRouteDecision(
                healthyExact.Route,
                Degraded: false,
                Score: healthyExact.Breakdown);
        }

        if (!allowDegrade || !_degradePolicy.IsEnabled)
        {
            ModelRoute failed = exact.FirstOrDefault()
                ?? routes.OrderBy(route => route.Priority).First();
            Record(failed.Id, success: false, degraded: false);
            return new ModelRouteDecision(failed, Degraded: false, FailedClosed: true);
        }

        RankedModelRoute? degraded = ModelRouteScorecard.Rank(
                routes.Where(IsRouteEligible).Where(_degradePolicy.Allows))
            .Take(_degradePolicy.MaxCandidates)
            .FirstOrDefault();
        if (degraded is null)
        {
            ModelRoute failed = exact.FirstOrDefault()
                ?? routes.OrderBy(route => route.Priority).First();
            Record(failed.Id, success: false, degraded: false);
            return new ModelRouteDecision(failed, Degraded: false, FailedClosed: true);
        }
        return new ModelRouteDecision(
            degraded.Route,
            Degraded: true,
            Score: degraded.Breakdown);
    }

    /// <summary>Records the final outcome of a forwarded request.</summary>
    public void RecordOutcome(ModelRoute route, bool succeeded, bool degraded)
    {
        ArgumentNullException.ThrowIfNull(route);
        Record(route.Id, succeeded, degraded);
        if (succeeded)
        {
            _healthStore.RecordSuccess(route);
        }
    }

    public void RecordOutcome(ModelRoute route, ModelCompletionResult result, bool degraded)
    {
        ArgumentNullException.ThrowIfNull(route);
        Record(route.Id, result.Succeeded, degraded);
        if (result.Succeeded)
        {
            _healthStore.RecordSuccess(route);
        }
        else
        {
            _healthStore.RecordFailure(route, result);
        }
    }

    /// <summary>
    /// Records an authentication failure proven by a catalog request without
    /// counting the background probe as a user completion.
    /// </summary>
    public void RecordDiscoveryAuthenticationFailure(ModelRoute route, int statusCode)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (statusCode is not 401 and not 403)
        {
            throw new ArgumentOutOfRangeException(nameof(statusCode));
        }
        _healthStore.RecordFailure(
            route,
            new ModelCompletionResult(statusCode, Array.Empty<byte>(), "application/json", false));
    }

    /// <summary>
    /// Clears only a stale authentication block after the same HTTP source
    /// accepts its catalog credential. Quota and capacity blocks remain intact.
    /// </summary>
    public void RecordDiscoverySuccess(ModelRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (_healthStore.ActiveFailure(route)?.FailureKind == ModelRouteHealthFailureKind.Authentication)
        {
            _healthStore.RecordSuccess(route);
        }
    }

    public bool IsRouteEligible(ModelRoute route) =>
        route.IsAvailable() && _healthStore.ActiveFailure(route) is null;

    public ModelRouteHealthRecord? ActiveHealthFailure(ModelRoute route) =>
        _healthStore.ActiveFailure(route);

    public IReadOnlyDictionary<string, ModelRouteHealthRecord> SnapshotHealth() =>
        _healthStore.Snapshot();

    public IReadOnlyDictionary<string, RouteMetrics> SnapshotMetrics()
    {
        lock (_gate)
        {
            return _metrics.ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.Ordinal);
        }
    }

    private void Record(string routeId, bool success, bool degraded)
    {
        lock (_gate)
        {
            _metrics.TryGetValue(routeId, out RouteMetrics? existing);
            existing ??= new RouteMetrics(0, 0, 0);
            _metrics[routeId] = existing with
            {
                Attempts = existing.Attempts + 1,
                Successes = existing.Successes + (success ? 1 : 0),
                Degrades = existing.Degrades + (degraded ? 1 : 0),
            };
        }
    }

    private static string ModelKey(ModelRoute route) =>
        string.Join("\u001f", route.Vendor, route.Endpoint?.ToString() ?? string.Empty, route.Model);
}

public sealed record ModelRouteDiscoveryMetadata(
    string SourceRouteId,
    string SourceKind,
    string DisplayName,
    DateTimeOffset RefreshedAt);

public sealed record ModelRoute(
    string Id,
    string Vendor,
    string Model,
    int Priority,
    bool Healthy,
    Uri? Endpoint = null,
    string? BearerToken = null,
    ModelRouteRoutingMetadata? Routing = null,
    ModelRouteDiscoveryMetadata? Discovery = null)
{
    /// <summary>Whether this route can accept a completion request now.</summary>
    public bool IsExecutable => Healthy
        && Endpoint is not null
        && (GatewayRouteConfiguration.IsEndpointAllowed(Endpoint)
            || GatewayRouteConfiguration.IsCliEndpointAllowed(Endpoint, Vendor));

    public bool IsAvailable()
    {
        if (!Healthy)
        {
            return false;
        }

        return Routing?.TrustStatus is not (
            ModelRouteTrustStatus.Exhausted
            or ModelRouteTrustStatus.MissingSecret
            or ModelRouteTrustStatus.Disabled);
    }
}

public sealed record ModelRouteDecision(
    ModelRoute Route,
    bool Degraded,
    bool FailedClosed = false,
    ModelRouteScoreBreakdown? Score = null);

public sealed record RouteMetrics(int Attempts, int Successes, int Degrades);
