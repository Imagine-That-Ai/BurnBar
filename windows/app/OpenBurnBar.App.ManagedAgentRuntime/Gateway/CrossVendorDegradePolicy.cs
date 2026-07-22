using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>Off-by-default operator policy for cross-vendor model substitution.</summary>
public sealed class CrossVendorDegradePolicy
{
    public const string EnabledEnvironmentVariable = "OPENBURNBAR_CROSS_VENDOR_DEGRADE";
    public const string VendorsEnvironmentVariable = "OPENBURNBAR_CROSS_VENDOR_DEGRADE_VENDORS";
    public const int MaximumVendorCount = 16;
    public const int MaximumCandidatesLimit = 16;

    private CrossVendorDegradePolicy(
        bool isEnabled,
        IReadOnlyList<string> allowedVendorIds,
        IReadOnlyDictionary<string, string> preferredModelByVendorId,
        int maxCandidates)
    {
        IsEnabled = isEnabled;
        AllowedVendorIds = allowedVendorIds;
        PreferredModelByVendorId = preferredModelByVendorId;
        MaxCandidates = maxCandidates;
    }

    public bool IsEnabled { get; }
    public IReadOnlyList<string> AllowedVendorIds { get; }
    public IReadOnlyDictionary<string, string> PreferredModelByVendorId { get; }
    public int MaxCandidates { get; }

    public static IReadOnlyList<string> DefaultVendorIds { get; } =
        new[] { "deepseek", "zai", "moonshot" };

    public static IReadOnlyDictionary<string, string> DefaultPreferredModels { get; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["deepseek"] = "deepseek-chat",
            ["zai"] = "glm-4.6",
            ["moonshot"] = "kimi-k2",
        };

    public static CrossVendorDegradePolicy Disabled { get; } = new(
        false,
        DefaultVendorIds,
        DefaultPreferredModels,
        4);

    public static CrossVendorDegradePolicy Create(
        bool isEnabled,
        IEnumerable<string>? allowedVendorIds = null,
        IReadOnlyDictionary<string, string>? preferredModelByVendorId = null,
        int maxCandidates = 4)
    {
        string[] vendors = (allowedVendorIds ?? DefaultVendorIds)
            .Select(value => value?.Trim().ToLowerInvariant() ?? string.Empty)
            .Where(value => value.Length > 0)
            .Where(value => value.Length <= GatewayRouteConfiguration.MaximumVendorLength)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(MaximumVendorCount)
            .ToArray();
        var preferred = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach ((string vendor, string model) in preferredModelByVendorId ?? DefaultPreferredModels)
        {
            string normalizedVendor = vendor?.Trim().ToLowerInvariant() ?? string.Empty;
            string normalizedModel = model?.Trim() ?? string.Empty;
            if (normalizedVendor.Length > 0
                && normalizedVendor.Length <= GatewayRouteConfiguration.MaximumVendorLength
                && normalizedModel.Length > 0
                && normalizedModel.Length <= GatewayRouteConfiguration.MaximumModelLength)
            {
                preferred[normalizedVendor] = normalizedModel;
            }
        }
        return new CrossVendorDegradePolicy(
            isEnabled,
            vendors,
            preferred,
            Math.Clamp(maxCandidates, 1, MaximumCandidatesLimit));
    }

    public static CrossVendorDegradePolicy FromEnvironment(
        IReadOnlyDictionary<string, string?>? environment = null)
    {
        string? rawEnabled;
        string? rawVendors;
        if (environment is null)
        {
            rawEnabled = Environment.GetEnvironmentVariable(EnabledEnvironmentVariable);
            rawVendors = Environment.GetEnvironmentVariable(VendorsEnvironmentVariable);
        }
        else
        {
            environment.TryGetValue(EnabledEnvironmentVariable, out rawEnabled);
            environment.TryGetValue(VendorsEnvironmentVariable, out rawVendors);
        }
        string flag = rawEnabled?.Trim().ToLowerInvariant() ?? string.Empty;
        bool enabled = flag is "1" or "true" or "yes" or "on";
        if (!enabled)
        {
            return Disabled;
        }

        IReadOnlyList<string> vendors = DefaultVendorIds;
        if (rawVendors is not null)
        {
            string[] parsed = (rawVendors ?? string.Empty)
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (parsed.Length > 0)
            {
                vendors = parsed;
            }
        }
        return Create(true, vendors);
    }

    public bool Allows(ModelRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        if (!IsEnabled
            || !AllowedVendorIds.Contains(route.Vendor, StringComparer.OrdinalIgnoreCase)
            || !IsOpenAICompatible(route))
        {
            return false;
        }
        return !PreferredModelByVendorId.TryGetValue(route.Vendor, out string? preferredModel)
            || string.Equals(route.Model, preferredModel, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsOpenAICompatible(ModelRoute route)
    {
        string? family = route.Routing?.FormatFamily?.Trim();
        if (string.IsNullOrEmpty(family))
        {
            return !string.Equals(route.Vendor, "anthropic", StringComparison.OrdinalIgnoreCase);
        }
        return family.Equals("openai-compatible", StringComparison.OrdinalIgnoreCase)
            || family.Equals("openai_compat", StringComparison.OrdinalIgnoreCase)
            || family.Equals("openaiCompat", StringComparison.OrdinalIgnoreCase);
    }
}
