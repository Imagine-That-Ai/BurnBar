using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Settings;
using Windows.Storage.Pickers;
using Windows.Storage;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class DataSourceSettingsPage : Page
{
    private SettingsPageContext? _context;

    public DataSourceSettingsPage()
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
        AppConfigurationModel snap = AppConfiguration.Current.Snapshot();
        DbPathBox.Text = snap.SqlCipherDbPath ?? string.Empty;
        PassphraseBox.Password = string.Empty;

        FirebaseProjectBox.Text = snap.FirebaseProjectId ?? string.Empty;
        FirebaseUidBox.Text = snap.FirebaseUid ?? string.Empty;
        FirebaseIdTokenBox.Text = string.Empty;
        AppCheckTokenBox.Text = string.Empty;
        VaultKeyBox.Text = string.Empty;

        StatusLabel.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "SQLCipher: configured"
            : SecretSummary(snap);
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
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;

        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is not null)
        {
            DbPathBox.Text = file.Path;
        }
    }

    private nint ResolveOwnerHwnd()
    {
        return System.IntPtr.Zero;
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        string? path = string.IsNullOrWhiteSpace(DbPathBox.Text) ? null : DbPathBox.Text.Trim();
        string? passphrase = string.IsNullOrWhiteSpace(PassphraseBox.Password) ? null : PassphraseBox.Password;

        AppConfiguration.Current.UpdateAndSave(model =>
        {
            model.SqlCipherDbPath = path;
            if (passphrase is not null)
            {
                model.SqlCipherPassphrase = passphrase;
            }

            model.FirebaseProjectId = NullIfEmpty(FirebaseProjectBox.Text);
            model.FirebaseUid = NullIfEmpty(FirebaseUidBox.Text);
            model.FirebaseIdToken = NullIfEmpty(FirebaseIdTokenBox.Text);
            model.AppCheckToken = NullIfEmpty(AppCheckTokenBox.Text);
            model.VaultKeyB64 = NullIfEmpty(VaultKeyBox.Text);
        });

        WinAppCloudSyncHost.ConfigureFromAppConfiguration();

        StatusLabel.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "Saved. SQLCipher active — reopen surfaces to reload stores."
            : "Saved. Secrets were written to protected storage; cloud settings applied where UID + token are set.";
    }

    private static string? NullIfEmpty(string? text) =>
        string.IsNullOrWhiteSpace(text) ? null : text.Trim();

    private static string SecretSummary(AppConfigurationModel model)
    {
        var configured = new List<string>();
        if (!string.IsNullOrWhiteSpace(model.SqlCipherPassphraseRef)) configured.Add("database passphrase");
        if (!string.IsNullOrWhiteSpace(model.FirebaseIdTokenRef)) configured.Add("Firebase ID token");
        if (!string.IsNullOrWhiteSpace(model.AppCheckTokenRef)) configured.Add("App Check token");
        if (!string.IsNullOrWhiteSpace(model.VaultKeyB64Ref)) configured.Add("CloudVault key");
        return configured.Count == 0
            ? "No protected secrets configured."
            : "Protected secrets configured: " + string.Join(", ", configured) + ".";
    }
}
