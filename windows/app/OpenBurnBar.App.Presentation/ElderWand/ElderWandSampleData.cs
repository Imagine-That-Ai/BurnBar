using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.ElderWand;

/// <summary>
/// Dev-host seed for the Windows Elder Wand configurator. Stands in for the live
/// <c>controller.liveAdvertisedModels</c> stream + the <c>settingsManager.elderWand</c> preset
/// store the macOS surface picks up, so the hosted <c>ElderWandConfiguratorView</c> renders its
/// full live form (analysis / judge / research budget / presets) before the real advertised-model
/// stream + encrypted settings store are wired by the integration wave.
///
/// The advertised models are lowered through the real, unit-tested
/// <see cref="ElderWandModelGrouping.Group"/> pass, so the seed exercises the same grouping /
/// eligibility path the live catalog will. Kept in the portable (net8.0, no-WinUI) layer so it is
/// covered by <c>dotnet test</c> on macOS.
/// </summary>
public static class ElderWandSampleData
{
    /// <summary>A fresh preset store over an empty in-memory persistence.</summary>
    public static ElderWandSettingsModel CreateDevHostSettings() =>
        new(new InMemoryElderWandPersistence());

    /// <summary>The seeded provider groups, grouped + sorted by <see cref="ElderWandModelGrouping.Group"/>.</summary>
    public static IReadOnlyList<ElderWandProviderGroup> DevHostGroups() =>
        ElderWandModelGrouping.Group(DevHostAdvertisedModels());

    /// <summary>
    /// A representative advertised-model catalog: three providers, one deliberately route-ineligible
    /// option so the disabled-chip path renders.
    /// </summary>
    public static IReadOnlyList<ElderWandAdvertisedModel> DevHostAdvertisedModels() => new List<ElderWandAdvertisedModel>
    {
        new("anthropic/claude-opus-4", "Claude Opus 4", RouteEligible: true, ProviderName: "Anthropic", ProviderId: "anthropic"),
        new("anthropic/claude-sonnet-4", "Claude Sonnet 4", RouteEligible: true, ProviderName: "Anthropic", ProviderId: "anthropic"),
        new("openai/gpt-5", "GPT-5", RouteEligible: true, ProviderName: "OpenAI", ProviderId: "openai"),
        new("openai/o4-preview", "o4 (preview)", RouteEligible: false, ProviderName: "OpenAI", ProviderId: "openai"),
        new("google/gemini-2.5-pro", "Gemini 2.5 Pro", RouteEligible: true, ProviderName: "Google", ProviderId: "google"),
    };
}
