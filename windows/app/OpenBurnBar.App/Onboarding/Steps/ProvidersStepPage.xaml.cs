using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Theme;
using Windows.Storage.Pickers;
using Windows.Storage;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Provider-cloud step. Windows peer of <c>OnboardingProviderCloudView.swift</c>:
/// a wrapping cloud of toggleable provider pills, detected-first, with "Select all
/// detected" and a live selected count.</summary>
public sealed partial class ProvidersStepPage : Page
{
    private OnboardingContext? _context;
    private readonly Dictionary<AgentProviderBrand, OnboardingProviderPill> _pills = new();

    /// <summary>
    /// Injected HWND resolver (the <c>Func&lt;IntPtr&gt;</c> pattern from
    /// <c>DataControlCenterView.WindowHandleProvider</c>). When set, <see cref="ResolveOwnerHwnd"/>
    /// uses this instead of the <see cref="OnboardingContext"/> provider so a host can supply
    /// the exact owner window for the file picker.
    /// </summary>
    public Func<IntPtr>? WindowHandleProvider { get; set; }

    public ProvidersStepPage()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    private OnboardingWizardModel? Model => _context?.Model;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (_context is null || Model is null)
        {
            return;
        }

        // Wire the injected HWND provider so ResolveOwnerHwnd returns a real handle
        // instead of IntPtr.Zero (the dead-picker bug — Code Quality SERIOUS-4).
        WindowHandleProvider ??= _context.WindowHandleProvider;

        LoadDbFields();
        BuildPills();
        Model.PropertyChanged += OnModelChanged;
        SyncCounts();
    }

    private void LoadDbFields()
    {
        AppConfigurationModel snap = AppConfiguration.Current.Snapshot();
        DbPathBox.Text = snap.SqlCipherDbPath ?? string.Empty;
        DbPassphraseBox.Password = string.Empty;

        DbStatusText.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "Database configured for this PC."
            : string.IsNullOrWhiteSpace(snap.SqlCipherPassphraseRef)
                ? "Optional — skip if you are starting fresh on Windows."
                : "Protected passphrase configured; choose a database file to enable SQLCipher.";
    }

    private async void OnBrowseDb(object sender, RoutedEventArgs e)
    {
        nint hwnd = ResolveOwnerHwnd();
        if (hwnd == nint.Zero)
        {
            return;
        }

        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add(".sqlite");
        picker.FileTypeFilter.Add(".db");

        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            DbPathBox.Text = file.Path;
        }
    }

    private void OnSaveDb(object sender, RoutedEventArgs e)
    {
        string? path = string.IsNullOrWhiteSpace(DbPathBox.Text) ? null : DbPathBox.Text.Trim();
        string? passphrase = string.IsNullOrWhiteSpace(DbPassphraseBox.Password) ? null : DbPassphraseBox.Password;

        AppConfiguration.Current.UpdateAndSave(model =>
        {
            model.SqlCipherDbPath = path;
            if (passphrase is not null)
            {
                model.SqlCipherPassphrase = passphrase;
            }
        });

        WindowsSettingsComposition.TryConfigureProductionCloudSync();
        DbStatusText.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "Saved — real SQLCipher stores will load on next surface open."
            : "Saved path; add passphrase and an existing file to enable SQLCipher.";
    }

    private nint ResolveOwnerHwnd()
    {
        // Resolve the real Win32 HWND backing this page's host window. The provider is
        // the injected Func<IntPtr> pattern from DataControlCenterView.xaml.cs:35,345,
        // wired from OnboardingContext in OnNavigatedTo. When no provider is wired
        // (unit tests, headless harness) returns IntPtr.Zero so the picker is skipped
        // rather than crashing — the same guard OnBrowseDb already checks.
        if (WindowHandleProvider is not null)
        {
            return WindowHandleProvider();
        }

        return IntPtr.Zero;
    }

    private void BuildPills()
    {
        if (_context is null || Model is null)
        {
            return;
        }

        ProviderCloud.Children.Clear();
        _pills.Clear();

        foreach (AgentProviderBrand provider in Model.SortedProviders(_context.DisplayName))
        {
            var pill = new OnboardingProviderPill();
            pill.Configure(
                provider,
                _context.DisplayName(provider),
                Model.IsProviderSelected(provider),
                Model.IsProviderDetected(provider));
            AgentProviderBrand captured = provider;
            pill.Toggled += (_, _) =>
            {
                Model.ToggleProvider(captured);
                pill.SetSelected(Model.IsProviderSelected(captured));
            };
            _pills[provider] = pill;
            ProviderCloud.Children.Add(pill);
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingWizardModel.SelectedProviders))
        {
            SyncCounts();
        }
    }

    private void SyncCounts()
    {
        if (Model is null)
        {
            return;
        }

        int detected = Model.DetectedProviders.Count;
        SelectAllDetectedButton.Visibility = detected > 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectAllDetectedButton.Content = $"Select all detected ({detected})";
        SelectedCount.Text = $"{Model.SelectedProviders.Count} selected";
    }

    private void OnSelectAllDetected(object sender, RoutedEventArgs e)
    {
        if (Model is null)
        {
            return;
        }

        Model.SelectAllDetected();
        foreach (KeyValuePair<AgentProviderBrand, OnboardingProviderPill> entry in _pills)
        {
            entry.Value.SetSelected(Model.IsProviderSelected(entry.Key));
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (Model is not null)
        {
            Model.PropertyChanged -= OnModelChanged;
        }
    }
}
