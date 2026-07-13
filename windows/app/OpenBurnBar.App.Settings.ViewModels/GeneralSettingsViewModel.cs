using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Persisted General settings shared by the WinUI page and runtime composition.</summary>
public sealed record GeneralSettingsSnapshot(
    GeneralTimeRange TimeRange,
    GeneralUsageDisplayMode UsageDisplayMode,
    double RefreshIntervalSeconds,
    bool IndexingEnabled,
    bool AutoSummariesEnabled,
    GeneralEmbeddingProvider EmbeddingProvider,
    string OpenAIEmbeddingModel)
{
    public static readonly GeneralSettingsSnapshot Default = new(
        GeneralTimeRange.Today,
        GeneralUsageDisplayMode.Currency,
        600,
        IndexingEnabled: false,
        AutoSummariesEnabled: true,
        GeneralEmbeddingProvider.Deterministic,
        "text-embedding-3-small");
}

public enum GeneralTimeRange
{
    Today,
    Week,
    Month,
}

public enum GeneralUsageDisplayMode
{
    Currency,
    Tokens,
}

public enum GeneralEmbeddingProvider
{
    Deterministic,
    OpenAI,
}

/// <summary>Storage boundary for General settings.</summary>
public interface IGeneralSettingsStore
{
    GeneralSettingsSnapshot Load();

    void Save(GeneralSettingsSnapshot settings);
}

/// <summary>In-memory implementation used by portable tests and design hosts.</summary>
public sealed class InMemoryGeneralSettingsStore : IGeneralSettingsStore
{
    private GeneralSettingsSnapshot _settings;

    public InMemoryGeneralSettingsStore(GeneralSettingsSnapshot? seed = null) =>
        _settings = seed ?? GeneralSettingsSnapshot.Default;

    public GeneralSettingsSnapshot Load() => _settings;

    public void Save(GeneralSettingsSnapshot settings) => _settings = settings;
}

/// <summary>
/// General settings model. Values are normalized on load and mutation so malformed
/// persisted data cannot produce an unsupported refresh interval or embedding model.
/// </summary>
public sealed class GeneralSettingsViewModel : ObservableSettingsViewModel
{
    public const double DefaultRefreshIntervalSeconds = 600;

    public static IReadOnlyList<double> RefreshIntervalChoices { get; } =
        new[] { 30d, 60d, 300d, 600d, 900d };

    public static IReadOnlyList<string> OpenAIEmbeddingModels { get; } = new[]
    {
        "text-embedding-3-small",
        "text-embedding-3-large",
        "text-embedding-ada-002",
    };

    private readonly IGeneralSettingsStore _store;
    private GeneralTimeRange _timeRange = GeneralSettingsSnapshot.Default.TimeRange;
    private GeneralUsageDisplayMode _usageDisplayMode = GeneralSettingsSnapshot.Default.UsageDisplayMode;
    private double _refreshIntervalSeconds = DefaultRefreshIntervalSeconds;
    private bool _indexingEnabled;
    private bool _autoSummariesEnabled = true;
    private GeneralEmbeddingProvider _embeddingProvider = GeneralSettingsSnapshot.Default.EmbeddingProvider;
    private string _openAIEmbeddingModel = GeneralSettingsSnapshot.Default.OpenAIEmbeddingModel;

    public GeneralSettingsViewModel(IGeneralSettingsStore? store = null)
    {
        _store = store ?? new InMemoryGeneralSettingsStore();
        Load();
    }

    /// <summary>Returns the normalized values consumed by Windows composition roots.</summary>
    public GeneralSettingsSnapshot Snapshot => new(
        _timeRange,
        _usageDisplayMode,
        _refreshIntervalSeconds,
        _indexingEnabled,
        _autoSummariesEnabled,
        _embeddingProvider,
        _openAIEmbeddingModel);

    public void Load()
    {
        GeneralSettingsSnapshot settings = _store.Load();
        _timeRange = Enum.IsDefined(settings.TimeRange) ? settings.TimeRange : GeneralSettingsSnapshot.Default.TimeRange;
        _usageDisplayMode = Enum.IsDefined(settings.UsageDisplayMode)
            ? settings.UsageDisplayMode
            : GeneralSettingsSnapshot.Default.UsageDisplayMode;
        _refreshIntervalSeconds = NormalizeRefreshInterval(settings.RefreshIntervalSeconds);
        _indexingEnabled = settings.IndexingEnabled;
        _autoSummariesEnabled = settings.AutoSummariesEnabled;
        _embeddingProvider = Enum.IsDefined(settings.EmbeddingProvider)
            ? settings.EmbeddingProvider
            : GeneralSettingsSnapshot.Default.EmbeddingProvider;
        _openAIEmbeddingModel = NormalizeEmbeddingModel(settings.OpenAIEmbeddingModel);
        RaiseAll();
    }

    public GeneralTimeRange TimeRange
    {
        get => _timeRange;
        set { if (Set(ref _timeRange, value)) Persist(); }
    }

    public GeneralUsageDisplayMode UsageDisplayMode
    {
        get => _usageDisplayMode;
        set { if (Set(ref _usageDisplayMode, value)) Persist(); }
    }

    public double RefreshIntervalSeconds
    {
        get => _refreshIntervalSeconds;
        set
        {
            double normalized = NormalizeRefreshInterval(value);
            if (Set(ref _refreshIntervalSeconds, normalized)) Persist();
        }
    }

    public bool IndexingEnabled
    {
        get => _indexingEnabled;
        set { if (Set(ref _indexingEnabled, value)) Persist(); }
    }

    public bool AutoSummariesEnabled
    {
        get => _autoSummariesEnabled;
        set { if (Set(ref _autoSummariesEnabled, value)) Persist(); }
    }

    public GeneralEmbeddingProvider EmbeddingProvider
    {
        get => _embeddingProvider;
        set { if (Set(ref _embeddingProvider, value)) Persist(); }
    }

    public string OpenAIEmbeddingModel
    {
        get => _openAIEmbeddingModel;
        set
        {
            string normalized = NormalizeEmbeddingModel(value);
            if (Set(ref _openAIEmbeddingModel, normalized)) Persist();
        }
    }

    private void Persist() => _store.Save(Snapshot);

    private static double NormalizeRefreshInterval(double value)
    {
        foreach (double choice in RefreshIntervalChoices)
        {
            if (Math.Abs(choice - value) < 0.001)
            {
                return choice;
            }
        }

        return DefaultRefreshIntervalSeconds;
    }

    private static string NormalizeEmbeddingModel(string? model)
    {
        string trimmed = (model ?? string.Empty).Trim();
        string? match = OpenAIEmbeddingModels.FirstOrDefault(candidate =>
            string.Equals(candidate, trimmed, StringComparison.OrdinalIgnoreCase));
        return match ?? GeneralSettingsSnapshot.Default.OpenAIEmbeddingModel;
    }

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(TimeRange));
        OnPropertyChanged(nameof(UsageDisplayMode));
        OnPropertyChanged(nameof(RefreshIntervalSeconds));
        OnPropertyChanged(nameof(IndexingEnabled));
        OnPropertyChanged(nameof(AutoSummariesEnabled));
        OnPropertyChanged(nameof(EmbeddingProvider));
        OnPropertyChanged(nameof(OpenAIEmbeddingModel));
    }
}
