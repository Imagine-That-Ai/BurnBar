using System;
using OpenBurnBar.App.Settings.ViewModels;

namespace OpenBurnBar.App.Settings.Winui;

/// <summary>JSON-backed adapter for the portable General settings model.</summary>
internal sealed class WindowsGeneralSettingsStore : IGeneralSettingsStore
{
    private readonly WindowsSettingsPersistence _persistence;

    public WindowsGeneralSettingsStore(WindowsSettingsPersistence persistence) =>
        _persistence = persistence ?? throw new ArgumentNullException(nameof(persistence));

    public GeneralSettingsSnapshot Load() => new(
        ParseEnum(_persistence.Read("defaultTimeRange", "today"), GeneralTimeRange.Today),
        ParseEnum(_persistence.Read("usageDisplayMode", "currency"), GeneralUsageDisplayMode.Currency),
        _persistence.Read("refreshInterval", GeneralSettingsViewModel.DefaultRefreshIntervalSeconds),
        _persistence.Read("conversationIndexingEnabled", GeneralSettingsSnapshot.Default.IndexingEnabled),
        _persistence.Read("autoSessionSummariesEnabled", GeneralSettingsSnapshot.Default.AutoSummariesEnabled),
        ParseEnum(_persistence.Read("indexEmbeddingProvider", "deterministic"), GeneralEmbeddingProvider.Deterministic),
        _persistence.Read("indexOpenAIModel", GeneralSettingsSnapshot.Default.OpenAIEmbeddingModel));

    public void Save(GeneralSettingsSnapshot settings)
    {
        _persistence.Write("defaultTimeRange", settings.TimeRange.ToString().ToLowerInvariant());
        _persistence.Write("usageDisplayMode", settings.UsageDisplayMode == GeneralUsageDisplayMode.Currency ? "currency" : "tokens");
        _persistence.Write("refreshInterval", settings.RefreshIntervalSeconds);
        _persistence.Write("conversationIndexingEnabled", settings.IndexingEnabled);
        _persistence.Write("autoSessionSummariesEnabled", settings.AutoSummariesEnabled);
        _persistence.Write("indexEmbeddingProvider", settings.EmbeddingProvider == GeneralEmbeddingProvider.OpenAI ? "openai" : "deterministic");
        _persistence.Write("indexOpenAIModel", settings.OpenAIEmbeddingModel);
    }

    private static T ParseEnum<T>(string raw, T fallback) where T : struct, Enum =>
        Enum.TryParse(raw, ignoreCase: true, out T value) && Enum.IsDefined(value) ? value : fallback;
}

/// <summary>Single composition boundary for normalized General settings.</summary>
internal static class WindowsGeneralSettingsComposition
{
    public static GeneralSettingsSnapshot Load() =>
        new GeneralSettingsViewModel(new WindowsGeneralSettingsStore(
            WindowsSettingsComposition.SharedPersistence)).Snapshot;
}
