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
    private readonly IReadOnlyList<ModelRoute> _routes;
    private readonly object _gate = new();
    private readonly Dictionary<string, RouteMetrics> _metrics = new(StringComparer.Ordinal);

    public ModelProxyRouter(IReadOnlyList<ModelRoute> routes)
    {
        _routes = routes ?? throw new ArgumentNullException(nameof(routes));
        if (_routes.Count == 0)
        {
            throw new ArgumentException("At least one route is required.", nameof(routes));
        }
    }

    /// <summary>Immutable route view used by gateway model discovery.</summary>
    public IReadOnlyList<ModelRoute> Routes => _routes;

    /// <summary>
    /// Select the best healthy route for <paramref name="vendorPreference"/>.
    /// Degrades to the next healthy route when preferred vendor is unhealthy.
    /// </summary>
    public ModelRouteDecision Select(string? vendorPreference = null)
        => SelectCore(vendorPreference, recordSelection: true);

    private ModelRouteDecision SelectCore(string? vendorPreference, bool recordSelection)
    {
        IReadOnlyList<RankedModelRoute> ranked = ModelRouteScorecard.Rank(_routes, vendorPreference);
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
        ModelRoute first = _routes.OrderBy(r => r.Priority).First();
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

        ModelRoute[] exact = _routes
            .Where(route => string.Equals(route.Model, model, StringComparison.OrdinalIgnoreCase))
            .OrderBy(route => route.Priority)
            .ToArray();
        RankedModelRoute? healthyExact = ModelRouteScorecard.Rank(exact).FirstOrDefault();
        if (healthyExact is not null)
        {
            return new ModelRouteDecision(
                healthyExact.Route,
                Degraded: false,
                Score: healthyExact.Breakdown);
        }

        if (!allowDegrade)
        {
            ModelRoute failed = exact.FirstOrDefault()
                ?? _routes.OrderBy(route => route.Priority).First();
            Record(failed.Id, success: false, degraded: false);
            return new ModelRouteDecision(failed, Degraded: false, FailedClosed: true);
        }

        ModelRouteDecision decision = SelectCore(null, recordSelection: false);
        return decision with { Degraded = true };
    }

    /// <summary>Records the final outcome of a forwarded request.</summary>
    public void RecordOutcome(ModelRoute route, bool succeeded, bool degraded)
    {
        ArgumentNullException.ThrowIfNull(route);
        Record(route.Id, succeeded, degraded);
    }

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
}

public sealed record ModelRoute(
    string Id,
    string Vendor,
    string Model,
    int Priority,
    bool Healthy,
    Uri? Endpoint = null,
    string? BearerToken = null,
    ModelRouteRoutingMetadata? Routing = null)
{
    /// <summary>Whether this route can accept a completion request now.</summary>
    public bool IsExecutable => Healthy
        && Endpoint is not null
        && GatewayRouteConfiguration.IsEndpointAllowed(Endpoint);

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
