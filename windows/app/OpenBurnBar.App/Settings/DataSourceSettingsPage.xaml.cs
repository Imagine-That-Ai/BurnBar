using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Chat;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Interop;
using OpenBurnBar.App.Storage;
using OpenBurnBar.App.Settings;
using OpenBurnBar.Storage;
using Windows.Storage.Pickers;
using Windows.Storage;
using Windows.System;

namespace OpenBurnBar.App.Settings.Winui;

public sealed partial class DataSourceSettingsPage : Page
{
    private SettingsPageContext? _context;
    private readonly IChatExecutableInventory _chatExecutableInventory =
        ProtectedChatExecutableInventoryStore.CreateDefault();

    /// <summary>
    /// Injected HWND resolver (the <c>Func&lt;IntPtr&gt;</c> pattern from
    /// <c>DataControlCenterView.WindowHandleProvider</c>). When set, <see cref="ResolveOwnerHwnd"/>
    /// uses this instead of the App composition-root fallback so a host can supply the
    /// exact owner window for the file picker.
    /// </summary>
    public Func<IntPtr>? WindowHandleProvider { get; set; }

    public DataSourceSettingsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as SettingsPageContext;
        if (_context?.WindowHandleProvider is { } provider)
        {
            WindowHandleProvider = provider;
        }
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
        RenderStorageStatus(WindowsStorageDevHost.InitializeRuntime());
        RenderChatExecutableStatus();
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
        // Resolve the real Win32 HWND backing this page's host window. The provider is
        // the injected Func<IntPtr> pattern from DataControlCenterView.xaml.cs:35,345;
        // when no provider is wired (unit tests, headless harness) the fallback resolves
        // the main window handle from the App composition root so the file picker still
        // gets a real owner in the shipped app.
        if (WindowHandleProvider is not null)
        {
            return WindowHandleProvider();
        }

        return App.Current.MainWindowHandle;
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
        RenderStorageStatus(WindowsStorageDevHost.InitializeRuntime());

        StatusLabel.Text = AppConfiguration.Current.HasSqlCipherCredentials
            ? "Saved. SQLCipher active — reopen surfaces to reload stores."
            : "Saved. Secrets were written to protected storage; cloud settings applied where UID + token are set.";
    }

    private void OnApproveChatExecutable(object sender, RoutedEventArgs e)
    {
        try
        {
            ApprovedChatExecutable executable = _chatExecutableInventory.ApproveExecutable(ChatExecutablePathBox.Text);
            StatusLabel.Text = "Approved chat executable " + executable.Id + ".";
        }
        catch (ChatProcessException ex)
        {
            StatusLabel.Text = ex.Message;
        }
        catch (SecretStoreException ex)
        {
            StatusLabel.Text = ex.Message;
        }

        RenderChatExecutableStatus();
    }

    private void OnRotateChatExecutable(object sender, RoutedEventArgs e)
    {
        ChatExecutableInventorySnapshot snapshot = _chatExecutableInventory.LoadSnapshot();
        ApprovedChatExecutable? current = snapshot.PrimaryExecutable;
        if (current is null)
        {
            OnApproveChatExecutable(sender, e);
            return;
        }

        try
        {
            ApprovedChatExecutable executable = _chatExecutableInventory.RotateExecutable(current.Id, ChatExecutablePathBox.Text);
            StatusLabel.Text = "Rotated chat executable " + executable.Id + ".";
        }
        catch (ChatProcessException ex)
        {
            StatusLabel.Text = ex.Message;
        }
        catch (SecretStoreException ex)
        {
            StatusLabel.Text = ex.Message;
        }

        RenderChatExecutableStatus();
    }

    private void OnRemoveChatExecutable(object sender, RoutedEventArgs e)
    {
        ChatExecutableInventorySnapshot snapshot = _chatExecutableInventory.LoadSnapshot();
        ApprovedChatExecutable? current = snapshot.PrimaryExecutable;
        if (current is not null)
        {
            _chatExecutableInventory.RemoveExecutable(current.Id);
            StatusLabel.Text = "Removed chat executable " + current.Id + ".";
        }
        else
        {
            StatusLabel.Text = "No chat executable is approved.";
        }

        RenderChatExecutableStatus();
    }

    private void OnRetryStorage(object sender, RoutedEventArgs e)
    {
        RenderStorageStatus(WindowsStorageDevHost.RetryRecovery());
    }

    private async void OnArchiveResetStorage(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Archive and reset storage?",
            Content = "OpenBurnBar will move the current encrypted database and recovery files into an archive folder, then create a new encrypted database. This cannot read damaged or wrong-key data.",
            PrimaryButtonText = "Archive and reset",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };

        ContentDialogResult result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary)
        {
            return;
        }

        var archive = WindowsStorageDevHost.ArchiveAndReset(confirmDestructiveReset: true);
        RenderStorageStatus(WindowsStorageDevHost.Status);
        StatusLabel.Text = "Archived storage at " + archive.ArchiveDirectory + ".";
    }

    private async void OnRevealLog(object sender, RoutedEventArgs e)
    {
        string? logPath = WindowsStorageDevHost.RecoveryLogPath;
        if (string.IsNullOrWhiteSpace(logPath))
        {
            StatusLabel.Text = "No recovery log is available yet.";
            return;
        }

        string? folder = System.IO.Path.GetDirectoryName(logPath);
        if (!string.IsNullOrWhiteSpace(folder) && Directory.Exists(folder))
        {
            _ = await Launcher.LaunchFolderPathAsync(folder);
        }

        StatusLabel.Text = "Recovery log: " + logPath;
    }

    private void RenderStorageStatus(WindowsStorageRuntimeStatus status)
    {
        RetryStorageButton.Visibility = Visibility.Collapsed;
        ArchiveResetButton.Visibility = Visibility.Collapsed;
        RevealLogButton.Visibility = Visibility.Collapsed;

        if (status.IsReady && status.Report is { } report)
        {
            StorageStatusTitle.Text = "SQLCipher storage is ready.";
            StorageStatusMessage.Text = report.Created
                ? "A clean profile database was created with a generated protected key."
                : "The existing encrypted database opened successfully.";
            StorageEvidenceText.Text =
                $"Path: {report.DatabasePath}\n"
                + $"Key: {report.KeyProvenance}\n"
                + $"Owner: {report.PathOwner}\n"
                + $"Cipher: {report.CipherVersion}\n"
                + $"Migration: {report.SchemaEndpoint} ({report.MigrationCount})\n"
                + $"Schema hash: {report.SchemaHash}";
            RevealLogButton.Visibility = Visibility.Visible;
            return;
        }

        if (status.RecoveryState is { } recovery)
        {
            StorageStatusTitle.Text = recovery.Title;
            StorageStatusMessage.Text = recovery.Message;
            StorageEvidenceText.Text =
                $"Path: {recovery.DatabasePath}\n"
                + $"Failure: {recovery.Kind}\n"
                + $"Journal: {recovery.JournalPath ?? "none"}\n"
                + $"Log: {recovery.RedactedLogPath ?? "none"}";
            RetryStorageButton.Visibility = recovery.Actions.Contains(WindowsStorageRecoveryAction.Retry) ? Visibility.Visible : Visibility.Collapsed;
            ArchiveResetButton.Visibility = recovery.Actions.Contains(WindowsStorageRecoveryAction.Reset) ? Visibility.Visible : Visibility.Collapsed;
            RevealLogButton.Visibility = recovery.Actions.Contains(WindowsStorageRecoveryAction.RevealRedactedLog) ? Visibility.Visible : Visibility.Collapsed;
            return;
        }

        StorageStatusTitle.Text = "SQLCipher storage has not started.";
        StorageStatusMessage.Text = "OpenBurnBar will provision encrypted storage on launch.";
        StorageEvidenceText.Text = string.Empty;
    }

    private void RenderChatExecutableStatus()
    {
        ChatExecutableInventorySnapshot snapshot = _chatExecutableInventory.LoadSnapshot();
        ChatExecutableStatusTitle.Text = snapshot.Status.Title;
        ChatExecutableStatusMessage.Text = snapshot.Status.Message;

        ApprovedChatExecutable? executable = snapshot.PrimaryExecutable;
        ChatExecutableCurrentText.Text = executable is null
            ? string.Empty
            : "Current: " + executable.Id + "\nPath: " + executable.Path + "\nSHA-256: " + executable.Sha256;
        ChatExecutablePathBox.Text = executable?.Path ?? ChatExecutablePathBox.Text;
        RotateChatExecutableButton.Visibility = executable is null ? Visibility.Collapsed : Visibility.Visible;
        RemoveChatExecutableButton.Visibility = executable is null ? Visibility.Collapsed : Visibility.Visible;
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
