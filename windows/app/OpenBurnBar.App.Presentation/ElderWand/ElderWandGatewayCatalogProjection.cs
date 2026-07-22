using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>
/// Projects the gateway's actual provider routes into the model catalog consumed
/// by the Elder Wand configurator. Routes without an endpoint are composition
/// placeholders and are deliberately not presented as advertised models.
/// </summary>
public static class ElderWandGatewayCatalogProjection
{
    public static IReadOnlyList<ElderWandProviderGroup> Groups(IEnumerable<ModelRoute> routes)
    {
        ArgumentNullException.ThrowIfNull(routes);

        IEnumerable<ElderWandAdvertisedModel> advertised = routes
            .Where(route => route.Endpoint is not null && !string.IsNullOrWhiteSpace(route.Model))
            .OrderBy(route => route.Priority)
            .GroupBy(route => route.Model.Trim(), StringComparer.Ordinal)
            .Select(group => group.FirstOrDefault(route => route.IsExecutable) ?? group.First())
            .Select(route => new ElderWandAdvertisedModel(
                route.Model.Trim(),
                ElderWandModelName.Abbreviate(route.Model),
                route.IsExecutable,
                ProviderDisplayName(route.Vendor),
                route.Vendor));

        return ElderWandModelGrouping.Group(advertised);
    }

    private static string ProviderDisplayName(string? vendor)
    {
        string value = (vendor ?? string.Empty).Trim();
        return value.ToLowerInvariant() switch
        {
            "openai" => "OpenAI",
            "anthropic" => "Anthropic",
            "google" or "gemini" => "Google",
            "ollama" => "Ollama",
            "openburnbar" => "OpenBurnBar",
            _ => value.Length == 0 ? "Other" : value,
        };
    }
}
