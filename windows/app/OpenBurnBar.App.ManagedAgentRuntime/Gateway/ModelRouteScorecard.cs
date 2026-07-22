using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ModelRouteTrustStatus
{
    Legacy,
    Ready,
    CoolingDown,
    Exhausted,
    MissingSecret,
    Disabled,
}

/// <summary>Non-secret inputs used to rank one provider credential slot.</summary>
public sealed record ModelRouteRoutingMetadata(
    string? CredentialSlotId = null,
    string? CanonicalModelId = null,
    string? FormatFamily = null,
    string? EndpointProfileId = null,
    double CapabilityScore = 0.7,
    double CostPerMillionTokens = 0,
    double LatencyMilliseconds = 150,
    ModelRouteTrustStatus TrustStatus = ModelRouteTrustStatus.Legacy,
    DateTimeOffset? CooldownUntil = null,
    bool PreferredSlot = false,
    DateTimeOffset? LastSelectedAt = null,
    DateTimeOffset? QuotaResetsAt = null,
    double? QuotaRemainingPercent = null,
    int? SlotPriority = null)
{
    public const int MaximumMetadataStringLength = 256;

    public void Validate()
    {
        ValidateOptional(CredentialSlotId, nameof(CredentialSlotId));
        ValidateOptional(CanonicalModelId, nameof(CanonicalModelId));
        ValidateOptional(FormatFamily, nameof(FormatFamily));
        ValidateOptional(EndpointProfileId, nameof(EndpointProfileId));
        ValidateFinite(CapabilityScore, nameof(CapabilityScore));
        ValidateFinite(CostPerMillionTokens, nameof(CostPerMillionTokens));
        ValidateFinite(LatencyMilliseconds, nameof(LatencyMilliseconds));
        if (CostPerMillionTokens < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(CostPerMillionTokens));
        }
        if (LatencyMilliseconds < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(LatencyMilliseconds));
        }
        if (QuotaRemainingPercent is double remaining && !double.IsFinite(remaining))
        {
            throw new ArgumentOutOfRangeException(nameof(QuotaRemainingPercent));
        }
        if (SlotPriority is < 0 or > GatewayRouteConfiguration.MaximumPriority)
        {
            throw new ArgumentOutOfRangeException(nameof(SlotPriority));
        }
        if (!Enum.IsDefined(TrustStatus))
        {
            throw new ArgumentOutOfRangeException(nameof(TrustStatus));
        }
    }

    private static void ValidateOptional(string? value, string name)
    {
        if (value?.Trim().Length > MaximumMetadataStringLength)
        {
            throw new ArgumentException(
                $"Route routing metadata {name} exceeds {MaximumMetadataStringLength} characters.",
                name);
        }
    }

    private static void ValidateFinite(double value, string name)
    {
        if (!double.IsFinite(value))
        {
            throw new ArgumentOutOfRangeException(name);
        }
    }
}

public sealed record ModelRouteScore(
    double Capability,
    double Cost,
    double Latency,
    double Trust,
    double PolicyFit)
{
    public double Composite =>
        Capability * 0.20
        + Cost * 0.25
        + Latency * 0.15
        + Trust * 0.25
        + PolicyFit * 0.15;
}

public sealed record ModelRouteScoreBreakdown(
    string RouteId,
    string Vendor,
    string? CredentialSlotId,
    ModelRouteScore Score,
    double RawCapability,
    double RawCostPerMillionTokens,
    double RawLatencyMilliseconds,
    ModelRouteTrustStatus RawTrustStatus,
    bool RawPolicyFitPreferred);

public sealed record RankedModelRoute(ModelRoute Route, ModelRouteScoreBreakdown Breakdown);

/// <summary>macOS-compatible five-factor provider scorecard and quota-drain ordering.</summary>
public static class ModelRouteScorecard
{
    public static IReadOnlyList<RankedModelRoute> Rank(
        IEnumerable<ModelRoute> routes,
        string? preferredVendor = null,
        DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(routes);
        DateTimeOffset effectiveNow = now ?? DateTimeOffset.UtcNow;
        ModelRoute[] candidates = routes
            .Where(route => route.IsAvailable())
            .ToArray();
        if (candidates.Length == 0)
        {
            return Array.Empty<RankedModelRoute>();
        }

        double minimumCost = candidates.Min(route => route.Routing?.CostPerMillionTokens ?? 0);
        double maximumCost = candidates.Max(route => route.Routing?.CostPerMillionTokens ?? 0);
        RankedModelRoute[] scored = candidates
            .Select(route => Score(route, preferredVendor, minimumCost, maximumCost, effectiveNow))
            .ToArray();

        return scored
            .GroupBy(entry => PoolKey(entry.Route), StringComparer.Ordinal)
            .Select(pool => new RankedPool(
                pool.Key,
                pool.OrderBy(entry => entry, new WithinPoolComparer(effectiveNow)).ToArray()))
            .OrderBy(pool => pool, RankedPoolComparer.Instance)
            .SelectMany(pool => pool.Routes)
            .ToArray();
    }

    private static RankedModelRoute Score(
        ModelRoute route,
        string? preferredVendor,
        double minimumCost,
        double maximumCost,
        DateTimeOffset now)
    {
        ModelRouteRoutingMetadata metadata = route.Routing ?? new ModelRouteRoutingMetadata();
        double capability = Clamp01(metadata.CapabilityScore);
        double costSpan = maximumCost - minimumCost;
        double cost = costSpan > 0
            ? 1 - ((metadata.CostPerMillionTokens - minimumCost) / costSpan)
            : 1;
        double latency = Clamp01(1 - ((metadata.LatencyMilliseconds - 50) / 150));
        double trust = TrustScore(metadata, now);
        bool preferred = metadata.PreferredSlot
            || string.Equals(route.Vendor, preferredVendor, StringComparison.OrdinalIgnoreCase);
        double policyFit = metadata.PreferredSlot
            ? 1
            : string.Equals(route.Vendor, preferredVendor, StringComparison.OrdinalIgnoreCase)
                ? 0.85
                : 0.3;
        var score = new ModelRouteScore(capability, Clamp01(cost), latency, trust, policyFit);
        return new RankedModelRoute(
            route,
            new ModelRouteScoreBreakdown(
                route.Id,
                route.Vendor,
                metadata.CredentialSlotId,
                score,
                metadata.CapabilityScore,
                metadata.CostPerMillionTokens,
                metadata.LatencyMilliseconds,
                metadata.TrustStatus,
                preferred));
    }

    private static double TrustScore(ModelRouteRoutingMetadata metadata, DateTimeOffset now) =>
        metadata.TrustStatus switch
        {
            ModelRouteTrustStatus.Ready => 1,
            ModelRouteTrustStatus.CoolingDown when metadata.CooldownUntil > now => 0.3,
            ModelRouteTrustStatus.CoolingDown => 0.9,
            ModelRouteTrustStatus.Exhausted => 0.1,
            ModelRouteTrustStatus.MissingSecret or ModelRouteTrustStatus.Disabled => 0,
            _ => 0.6,
        };

    private static string PoolKey(ModelRoute route)
    {
        ModelRouteRoutingMetadata metadata = route.Routing ?? new ModelRouteRoutingMetadata();
        return string.Join(
            "\u001f",
            route.Vendor.ToLowerInvariant(),
            route.Model.ToLowerInvariant(),
            metadata.CanonicalModelId?.ToLowerInvariant() ?? string.Empty,
            metadata.FormatFamily?.ToLowerInvariant() ?? string.Empty,
            metadata.EndpointProfileId?.ToLowerInvariant() ?? string.Empty);
    }

    private static bool? CompareQuota(ModelRoute left, ModelRoute right, DateTimeOffset now)
    {
        ModelRouteRoutingMetadata lhs = left.Routing ?? new ModelRouteRoutingMetadata();
        ModelRouteRoutingMetadata rhs = right.Routing ?? new ModelRouteRoutingMetadata();
        DateTimeOffset? lhsReset = lhs.QuotaResetsAt > now ? lhs.QuotaResetsAt : null;
        DateTimeOffset? rhsReset = rhs.QuotaResetsAt > now ? rhs.QuotaResetsAt : null;
        if (lhsReset != rhsReset)
        {
            if (lhsReset is null) return false;
            if (rhsReset is null) return true;
            return lhsReset < rhsReset;
        }

        double? lhsRemaining = NormalizeRemaining(lhs.QuotaRemainingPercent);
        double? rhsRemaining = NormalizeRemaining(rhs.QuotaRemainingPercent);
        if (lhsRemaining != rhsRemaining && lhsRemaining is not null && rhsRemaining is not null)
        {
            return lhsRemaining > rhsRemaining;
        }
        return null;
    }

    private static double? NormalizeRemaining(double? value) => value is double finite && double.IsFinite(finite)
        ? Math.Clamp(finite, 0, 100)
        : null;

    private static int CompareScoreAndTies(RankedModelRoute left, RankedModelRoute right)
    {
        int score = right.Breakdown.Score.Composite.CompareTo(left.Breakdown.Score.Composite);
        if (score != 0) return score;
        int vendor = string.Compare(left.Route.Vendor, right.Route.Vendor, StringComparison.Ordinal);
        if (vendor != 0) return vendor;
        int priority = (left.Route.Routing?.SlotPriority ?? left.Route.Priority)
            .CompareTo(right.Route.Routing?.SlotPriority ?? right.Route.Priority);
        if (priority != 0) return priority;
        int selected = (left.Route.Routing?.LastSelectedAt ?? DateTimeOffset.MinValue)
            .CompareTo(right.Route.Routing?.LastSelectedAt ?? DateTimeOffset.MinValue);
        if (selected != 0) return selected;
        int slot = string.Compare(
            left.Route.Routing?.CredentialSlotId ?? "legacy",
            right.Route.Routing?.CredentialSlotId ?? "legacy",
            StringComparison.Ordinal);
        return slot != 0 ? slot : string.Compare(left.Route.Id, right.Route.Id, StringComparison.Ordinal);
    }

    private static double Clamp01(double value) => Math.Clamp(value, 0, 1);

    private sealed record RankedPool(string Key, IReadOnlyList<RankedModelRoute> Routes);

    private sealed class RankedPoolComparer : IComparer<RankedPool>
    {
        public static RankedPoolComparer Instance { get; } = new();

        public int Compare(RankedPool? left, RankedPool? right)
        {
            if (ReferenceEquals(left, right)) return 0;
            if (left is null) return 1;
            if (right is null) return -1;
            int score = CompareScoreAndTies(left.Routes[0], right.Routes[0]);
            return score != 0 ? score : string.Compare(left.Key, right.Key, StringComparison.Ordinal);
        }
    }

    private sealed class WithinPoolComparer : IComparer<RankedModelRoute>
    {
        private readonly DateTimeOffset _now;

        public WithinPoolComparer(DateTimeOffset now) => _now = now;

        public int Compare(RankedModelRoute? left, RankedModelRoute? right)
        {
            if (ReferenceEquals(left, right)) return 0;
            if (left is null) return 1;
            if (right is null) return -1;
            bool? quota = CompareQuota(left.Route, right.Route, _now);
            if (quota is bool ordered) return ordered ? -1 : 1;
            return CompareScoreAndTies(left, right);
        }
    }
}
