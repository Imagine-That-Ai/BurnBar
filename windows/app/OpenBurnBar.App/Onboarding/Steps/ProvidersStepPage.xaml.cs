using Windows.Storage;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Theme;
using Windows.Storage.Pickers;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Provider-cloud step. Windows peer of <c>OnboardingProviderCloudView.swift</c>:
/// a wrapping cloud of toggleable provider pills, detected-first, with "Select all
/// detected" and a live selected count.</summary>
public sealed partial class ProvidersStepPage : Page
{
    private OnboardingContext? _context;
    private readonly Dictionary<AgentProviderBrand, OnboardingProviderPill> _pills = new();

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

        LoadDbFields();
        BuildPills();
        Model.PropertyChanged += OnModelChanged;
        SyncCounts();
    }

    private void LoadDbFields()
    {
        AppConfigurationModel snap = AppConfiguration.Current.Snapshot();
        DbPathBox.Text = snap.SqlCipherDbPath ?? string.Empty;
        if (!string.IsNullOrEmpty(snap.SqlCipherPassphrase))
        {
            DbPassphraseBox.Password = snap.SqlCipherPassphrase;
        }

        DbStatusText.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "Database configured for this PC."
            : "Optional — skip if you are starting fresh on Windows.";
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

        WinAppCloudSyncHost.ConfigureFromAppConfiguration();
        DbStatusText.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "Saved — real SQLCipher stores will load on next surface open."
            : "Saved path; add passphrase and an existing file to enable SQLCipher.";
    }

    private nint ResolveOwnerHwnd()
    {
        return System.IntPtr.Zero;
    }
}
