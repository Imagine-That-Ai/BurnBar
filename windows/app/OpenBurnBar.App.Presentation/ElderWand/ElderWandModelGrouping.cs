using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from the `enum ElderWandModelGrouping` in
//   AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorView.swift
//
// Resolves the live advertised models into a provider-grouped, de-duplicated chip
// catalog. Pure transform (no engine, no view) so the same grouping the WinUI chip
// clouds consume is exercised by `dotnet test` on macOS. The Swift version walks the
// routed gateway backends (hermes/openclaw/piAgent) and calls
// `controller.liveAdvertisedModels(for:)`; on Windows the integrator flattens that
// same stream into a single ordered `IEnumerable<ElderWandAdvertisedModel>` — the
// dedupe / provider-order / per-group sort invariants below are identical.

/// <summary>Groups a flattened advertised-model stream by provider. Swift:
/// <c>ElderWandModelGrouping.groups(from:)</c>.</summary>
public static class ElderWandModelGrouping
{
    /// <summary>
    /// Walks <paramref name="advertised"/> in order, keeps the first occurrence of each
    /// trimmed non-empty model ID, buckets it under its resolved provider name (preserving
    /// first-seen provider order), and sorts each bucket's options by title. Mirrors the
    /// Swift <c>seen</c>/<c>byProvider</c>/<c>providerOrder</c> pass exactly.
    /// </summary>
    public static IReadOnlyList<ElderWandProviderGroup> Group(IEnumerable<ElderWandAdvertisedModel> advertised)
    {
        if (advertised is null)
        {
            throw new ArgumentNullException(nameof(advertised));
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var byProvider = new Dictionary<string, List<ElderWandModelOption>>(StringComparer.Ordinal);
        var providerOrder = new List<string>();

        foreach (var model in advertised)
        {
            string modelId = (model.Id ?? string.Empty).Trim();
            if (modelId.Length == 0 || !seen.Add(modelId))
            {
                continue;
            }

            string providerName = ResolveProviderName(model);
            if (!byProvider.TryGetValue(providerName, out var bucket))
            {
                bucket = new List<ElderWandModelOption>();
                byProvider[providerName] = bucket;
                providerOrder.Add(providerName);
            }

            bucket.Add(new ElderWandModelOption(modelId, model.MenuTitle, model.RouteEligible));
        }

        var result = new List<ElderWandProviderGroup>(providerOrder.Count);
        foreach (var provider in providerOrder)
        {
            var options = byProvider[provider];
            options.Sort(static (a, b) => string.CompareOrdinal(a.Title, b.Title));
            result.Add(new ElderWandProviderGroup(provider, options));
        }

        return result;
    }

    private static string ResolveProviderName(ElderWandAdvertisedModel model)
    {
        string? name = model.ProviderName?.Trim();
        if (!string.IsNullOrEmpty(name))
        {
            return name;
        }

        string? id = model.ProviderId?.Trim();
        if (!string.IsNullOrEmpty(id))
        {
            return id;
        }

        return "Other";
    }
}
