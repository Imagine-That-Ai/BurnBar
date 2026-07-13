// Code-behind for General. Registers the General-tab anchored rows, consumes the
// router's pending anchor on Loaded, and drills into the Appearance subpage when its
// card is clicked (the same content Frame, carrying the shared context).

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Settings.ViewModels;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class GeneralSettingsPage : Page, ISettingsAnchorTarget
{
    private readonly SettingsAnchorScroller _scroller = new();
    private readonly GeneralSettingsViewModel _settings = new(
        new WindowsGeneralSettingsStore(WindowsSettingsComposition.SharedPersistence));
    private SettingsPageContext? _context;
    private bool _loading;

    public GeneralSettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as SettingsPageContext;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        LoadControls();
        _scroller.RegisterAnchor(SettingsAnchor.OperatorWizard, OperatorCard);
        _scroller.RegisterAnchor(SettingsAnchor.DefaultsTimeRange, TimeRangeCard);
        _scroller.RegisterAnchor(SettingsAnchor.DefaultsUsageMode, UsageModeCard);
        _scroller.RegisterAnchor(SettingsAnchor.RefreshInterval, RefreshCard);
        _scroller.RegisterAnchor(SettingsAnchor.IndexingToggle, IndexingCard);
        _scroller.RegisterAnchor(SettingsAnchor.SummariesAuto, SummariesCard);
        SettingsLeafPageSupport.ConsumePending(_context?.Router, _scroller);
    }

    private void LoadControls()
    {
        _loading = true;
        TimeRangePicker.SelectedIndex = _settings.TimeRange switch
        {
            GeneralTimeRange.Today => 0,
            GeneralTimeRange.Week => 1,
            GeneralTimeRange.Month => 2,
            _ => 0,
        };
        UsageModePicker.SelectedIndex = _settings.UsageDisplayMode == GeneralUsageDisplayMode.Currency ? 0 : 1;
        RefreshPicker.SelectedIndex = RefreshIndex(_settings.RefreshIntervalSeconds);
        IndexingToggle.IsOn = _settings.IndexingEnabled;
        SummariesToggle.IsOn = _settings.AutoSummariesEnabled;
        EmbeddingProviderPicker.SelectedIndex = _settings.EmbeddingProvider == GeneralEmbeddingProvider.OpenAI ? 1 : 0;
        EmbeddingModelPicker.SelectedIndex = ModelIndex(_settings.OpenAIEmbeddingModel);
        EmbeddingModelPicker.IsEnabled = _settings.EmbeddingProvider == GeneralEmbeddingProvider.OpenAI;
        RefreshEmbeddingStatus();
        _loading = false;
    }

    private void TimeRangePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading)
        {
            _settings.TimeRange = TimeRangePicker.SelectedIndex switch
            {
                1 => GeneralTimeRange.Week,
                2 => GeneralTimeRange.Month,
                _ => GeneralTimeRange.Today,
            };
        }
    }

    private void UsageModePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading)
        {
            _settings.UsageDisplayMode = UsageModePicker.SelectedIndex == 1
                ? GeneralUsageDisplayMode.Tokens
                : GeneralUsageDisplayMode.Currency;
        }
    }

    private void RefreshPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && RefreshPicker.SelectedIndex >= 0)
        {
            _settings.RefreshIntervalSeconds = GeneralSettingsViewModel.RefreshIntervalChoices[RefreshPicker.SelectedIndex];
        }
    }

    private void IndexingToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (!_loading)
        {
            _settings.IndexingEnabled = IndexingToggle.IsOn;
        }
    }

    private void SummariesToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (!_loading)
        {
            _settings.AutoSummariesEnabled = SummariesToggle.IsOn;
        }
    }

    private void EmbeddingProviderPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading)
        {
            _settings.EmbeddingProvider = EmbeddingProviderPicker.SelectedIndex == 1
                ? GeneralEmbeddingProvider.OpenAI
                : GeneralEmbeddingProvider.Deterministic;
            EmbeddingModelPicker.IsEnabled = _settings.EmbeddingProvider == GeneralEmbeddingProvider.OpenAI;
            RefreshEmbeddingStatus();
        }
    }

    private void EmbeddingModelPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && EmbeddingModelPicker.SelectedIndex >= 0)
        {
            _settings.OpenAIEmbeddingModel = GeneralSettingsViewModel.OpenAIEmbeddingModels[EmbeddingModelPicker.SelectedIndex];
        }
    }

    private void SaveOpenAIKey_Click(object sender, RoutedEventArgs e)
    {
        string key = OpenAIKeyBox.Password.Trim();
        if (key.Length == 0)
        {
            EmbeddingStatus.Text = "Enter a key before saving.";
            return;
        }

        try
        {
            string secretName = AppSecretNames.ProviderSecret("openai", "project-code", "api-key");
            AppConfiguration.Current.SecretStore.Write(secretName, key);
            SecretRedactor.Shared.Register(key);
            OpenAIKeyBox.Password = string.Empty;
            EmbeddingStatus.Text = "Protected key saved. Restart indexing to use the selected provider.";
        }
        catch (SecretStoreException exception)
        {
            EmbeddingStatus.Text = "Protected storage is unavailable; the key was not saved.";
            AppDiagnostics.LogEvent("settings.embedding-key", exception.Failure.ToString());
        }
    }

    private void RefreshEmbeddingStatus()
    {
        if (_settings.EmbeddingProvider != GeneralEmbeddingProvider.OpenAI)
        {
            EmbeddingStatus.Text = "Local deterministic embeddings are active; no network key is required.";
            return;
        }

        string secretName = AppSecretNames.ProviderSecret("openai", "project-code", "api-key");
        try
        {
            bool configured = AppConfiguration.Current.SecretStore.Contains(secretName);
            EmbeddingStatus.Text = configured
                ? "Protected OpenAI key configured. Changes apply after indexing restarts."
                : "OpenAI is selected but no protected key is configured; indexing will remain local.";
        }
        catch (SecretStoreException exception)
        {
            EmbeddingStatus.Text = "Protected storage is unavailable; indexing will remain local.";
            AppDiagnostics.LogEvent("settings.embedding-key", exception.Failure.ToString());
        }
    }

    private static int RefreshIndex(double seconds)
    {
        for (int index = 0; index < GeneralSettingsViewModel.RefreshIntervalChoices.Count; index++)
        {
            if (Math.Abs(GeneralSettingsViewModel.RefreshIntervalChoices[index] - seconds) < 0.001)
            {
                return index;
            }
        }

        return 3;
    }

    private static int ModelIndex(string model)
    {
        for (int index = 0; index < GeneralSettingsViewModel.OpenAIEmbeddingModels.Count; index++)
        {
            if (string.Equals(GeneralSettingsViewModel.OpenAIEmbeddingModels[index], model, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }

        return 0;
    }

    public void ScrollToAnchor(string anchorId, string? focusId) => _scroller.ScrollTo(anchorId, focusId);

    private void Appearance_Click(object sender, RoutedEventArgs e)
    {
        // Drill into the Appearance subpage in the same content Frame.
        Frame?.Navigate(typeof(AppearanceSettingsPage), _context);
    }
}
