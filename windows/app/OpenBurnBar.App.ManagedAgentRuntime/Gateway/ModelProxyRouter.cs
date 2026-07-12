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

    /// <summary>
    /// Select the best healthy route for <paramref name="vendorPreference"/>.
    /// Degrades to the next healthy route when preferred vendor is unhealthy.
    /// </summary>
    public ModelRouteDecision Select(string? vendorPreference = null)
    {
        IEnumerable<ModelRoute> ordered = _routes;
        if (!string.IsNullOrWhiteSpace(vendorPreference))
        {
            ordered = _routes
                .OrderByDescending(r => string.Equals(r.Vendor, vendorPreference, StringComparison.OrdinalIgnoreCase))
                .ThenBy(r => r.Priority);
        }
        else
        {
            ordered = _routes.OrderBy(r => r.Priority);
        }

        foreach (ModelRoute route in ordered)
        {
            if (route.Healthy)
            {
                Record(route.Id, success: true, degraded: !string.IsNullOrWhiteSpace(vendorPreference)
                    && !string.Equals(route.Vendor, vendorPreference, StringComparison.OrdinalIgnoreCase));
                return new ModelRouteDecision(route, Degraded: !string.IsNullOrWhiteSpace(vendorPreference)
                    && !string.Equals(route.Vendor, vendorPreference, StringComparison.OrdinalIgnoreCase));
            }
        }

        // Fail closed: no healthy route.
        ModelRoute first = _routes.OrderBy(r => r.Priority).First();
        Record(first.Id, success: false, degraded: false);
        return new ModelRouteDecision(first, Degraded: false, FailedClosed: true);
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

public sealed record ModelRoute(string Id, string Vendor, string Model, int Priority, bool Healthy);

public sealed record ModelRouteDecision(ModelRoute Route, bool Degraded, bool FailedClosed = false);

public sealed record RouteMetrics(int Attempts, int Successes, int Degrades);
