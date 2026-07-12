using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.ElderWand;

// PORTED (faithful) from the value types the macOS configurator resolves once and
// hands to its pure section renderers:
//   AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorModel.swift
//     -> ElderWandModelOption, ElderWandProviderGroup
//   AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorView.swift (ElderWandModelGrouping)
//     -> ElderWandAdvertisedModel (the live-catalog input the grouping reads)
//   AgentLens/Services/Settings/Stores/ElderWandSettings.swift (elderWandPluginsPayload)
//     -> ElderWandFusionPlugin (the wire block the daemon gateway expects)
//
// All are dependency-free records so the grouping pass, the edit buffer, and the
// preset store run + unit-test on the macOS authoring host with zero WinUI dependency.

/// <summary>A single selectable model in a chip cloud. Swift: <c>struct ElderWandModelOption</c>.</summary>
/// <param name="Id">The wire model ID written into the preset.</param>
/// <param name="Title">Human-facing chip label.</param>
/// <param name="IsRouteEligible">Whether the model has an eligible live route right now.
/// Ineligible models render disabled so an unroutable panel can't be built.</param>
public sealed record ElderWandModelOption(string Id, string Title, bool IsRouteEligible);

/// <summary>A provider-titled group of model options. Swift: <c>struct ElderWandProviderGroup</c>
/// (identity is the provider display name — groups are de-duped by it).</summary>
public sealed record ElderWandProviderGroup(string ProviderName, IReadOnlyList<ElderWandModelOption> Options)
{
    /// <summary>Stable identity — the provider display name. Swift: <c>var id { providerName }</c>.</summary>
    public string Id => ProviderName;
}

/// <summary>The live-catalog input the grouping pass reads. Windows-side stand-in for the
/// macOS <c>OpenAICompatibleAdvertisedModel</c> fields the Swift
/// <c>ElderWandModelGrouping.groups(from:)</c> consumes (id, menuTitle, routeEligible,
/// providerName, providerID). The integrator maps the real advertised-model stream onto
/// this; the grouping logic + its tests stay engine-free.</summary>
public sealed record ElderWandAdvertisedModel(
    string Id,
    string MenuTitle,
    bool RouteEligible,
    string? ProviderName = null,
    string? ProviderId = null);

/// <summary>The OpenRouter "Fusion"-compatible plugin block the daemon gateway reads.
/// Swift: the dictionary element built by <c>elderWandPluginsPayload()</c>.</summary>
public sealed record ElderWandFusionPlugin(
    string Id,
    bool Enabled,
    IReadOnlyList<string> AnalysisModels,
    string Model,
    int MaxToolCalls);

/// <summary>Compact display name for a model ID. PORTED (faithful) from
/// <c>ChatSessionController.abbreviateChatModelName(_:)</c> — trims a known vendor prefix
/// and elides past 32 chars. Used by the preset-row summary.</summary>
public static class ElderWandModelName
{
    private static readonly string[] Prefixes =
    {
        "NousResearch/", "meta-llama/", "mistralai/", "Qwen/", "google/", "deepseek-ai/",
    };

    /// <summary>Swift: <c>abbreviateChatModelName(_:)</c>.</summary>
    public static string Abbreviate(string? name)
    {
        string shortName = (name ?? string.Empty).Trim();
        if (shortName.Length == 0)
        {
            return "Model";
        }

        foreach (var prefix in Prefixes)
        {
            if (shortName.StartsWith(prefix, StringComparison.Ordinal))
            {
                shortName = shortName.Substring(prefix.Length);
                break;
            }
        }

        if (shortName.Length > 32)
        {
            shortName = shortName.Substring(0, 30) + "…";
        }

        return shortName;
    }
}
